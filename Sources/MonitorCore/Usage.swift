import Foundation
import Darwin

public struct UsageWindow: Sendable, Codable, Equatable {
    public var usedPercent: Double?
    public var durationMinutes: Int
    public var resetsAt: Date?
    public var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
}
public struct UsageSnapshot: Sendable, Codable, Equatable {
    public var fiveHour: UsageWindow?
    public var weekly: UsageWindow?
    public var updatedAt: Date
}
public enum UsageFailure: Error, Sendable {
    case missingCLI, unavailable, timeout, invalidData, notAuthenticated
    public var message: String {
        switch self {
        case .missingCLI: return "未找到已安装的 Codex CLI"
        case .timeout: return "用量查询超时，保留上次数据"
        case .notAuthenticated: return "用量未更新，请检查 Codex 登录状态"
        case .invalidData: return "当前账号未返回可识别的 5 小时 / 每周额度"
        case .unavailable: return "用量接口暂不可用，请检查 Codex 登录与网络"
        }
    }
}

public enum UsageParser {
    private struct RawWindow: Decodable {
        var usedPercent: Double?
        var windowDurationMins: Int?
        var resetsAt: Double?
    }
    private struct Bucket: Decodable {
        var limitId: String?
        var primary: RawWindow?
        var secondary: RawWindow?
    }
    private struct Reply: Decodable {
        var rateLimits: Bucket?
        var rateLimitsByLimitId: [String: Bucket]?
    }
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let bucket = reply.rateLimitsByLimitId?["codex"] ?? reply.rateLimits.flatMap { $0.limitId == nil || $0.limitId == "codex" ? $0 : nil }
        guard let bucket else { throw UsageFailure.invalidData }
        let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
        func window(_ minutes: Int) -> UsageWindow? {
            guard let value = windows.first(where: { $0.windowDurationMins == minutes }) else { return nil }
            let used = value.usedPercent.flatMap { $0.isFinite ? max(0, min(100, $0)) : nil }
            let reset = value.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return UsageWindow(usedPercent: used, durationMinutes: minutes, resetsAt: reset)
        }
        let snapshot = UsageSnapshot(fiveHour: window(300), weekly: window(10080), updatedAt: now)
        guard snapshot.fiveHour != nil || snapshot.weekly != nil else { throw UsageFailure.invalidData }
        return snapshot
    }
}

public enum CodexCLI {
    public static func locate(application: URL? = nil) -> URL? {
        let apps = [application, URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app")].compactMap { $0 }
        var candidates: [URL] = []
        for app in apps {
            for path in ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex", "Contents/Resources/codex-cli/bin/codex"] {
                candidates.append(app.appendingPathComponent(path))
            }
        }
        candidates += [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex"),
                       URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

public actor UsageService {
    let executable: URL?
    let runtimeDirectory: URL
    public init(executable: URL?, runtimeDirectory: URL) { self.executable = executable; self.runtimeDirectory = runtimeDirectory }
    public func read() async -> Result<UsageSnapshot, UsageFailure> {
        guard let executable else { return .failure(.missingCLI) }
        let holder = UsageCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let query = UsageQuery(executable: executable, runtimeDirectory: runtimeDirectory, continuation: continuation)
                holder.install(query); query.start()
            }
        }, onCancel: { holder.cancel() })
    }
}

private final class UsageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var query: UsageQuery?
    private var cancelled = false
    func install(_ query: UsageQuery) {
        lock.lock(); self.query = query; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { query.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let pending = query; lock.unlock()
        pending?.cancel()
    }
}

private final class UsageQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-monitor.usage")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var finished = false
    private var requestedUsage = false
    private var continuation: CheckedContinuation<Result<UsageSnapshot, UsageFailure>, Never>?

    init(executable: URL, runtimeDirectory: URL, continuation: CheckedContinuation<Result<UsageSnapshot, UsageFailure>, Never>) {
        self.continuation = continuation
        process.executableURL = executable
        let quotedPath = String(data: try! JSONEncoder().encode(runtimeDirectory.path), encoding: .utf8)!
        process.arguments = ["-c", "log_dir=" + quotedPath, "-c", "analytics.enabled=false", "app-server", "--stdio"]
        process.currentDirectoryURL = runtimeDirectory.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment; environment["RUST_LOG"] = "off"; process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    }
    func start() {
        queue.async {
            guard !self.finished else { return }
            self.output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                self.queue.async { self.receive(data) }
            }
            self.process.terminationHandler = { _ in self.queue.async { self.finish(.failure(.unavailable)) } }
            do {
                try self.process.run()
                self.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_network_monitor", "title": "Codex Network Monitor", "version": "1.1.0"]]])
            } catch { self.finish(.failure(.unavailable)) }
            self.queue.asyncAfter(deadline: .now() + 18) { self.finish(.failure(.timeout)) }
        }
    }
    func cancel() { queue.async { self.finish(.failure(.unavailable)) } }
    private func send(_ value: [String: Any]) {
        guard !finished, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])) }
        catch { finish(.failure(.unavailable)) }
    }
    private func receive(_ data: Data) {
        guard !finished else { return }
        if data.isEmpty { finish(.failure(.unavailable)); return }
        buffer.append(data)
        guard buffer.count <= 2 * 1024 * 1024 else { finish(.failure(.invalidData)); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: end)); buffer.removeSubrange(...end)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if message["method"] as? String == "account/chatgptAuthTokens/refresh" { finish(.failure(.notAuthenticated)); return }
            guard let id = message["id"] as? Int else { continue }
            if message["error"] != nil { finish(.failure(.unavailable)); return }
            if id == 1 && !requestedUsage {
                requestedUsage = true
                send(["method": "initialized", "params": [:]])
                send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
            } else if id == 2 {
                guard let result = message["result"], let data = try? JSONSerialization.data(withJSONObject: result) else { finish(.failure(.invalidData)); return }
                do { finish(.success(try UsageParser.parse(data))) }
                catch { finish(.failure(.invalidData)) }
                return
            }
        }
    }
    private func finish(_ result: Result<UsageSnapshot, UsageFailure>) {
        guard !finished else { return }; finished = true
        output.fileHandleForReading.readabilityHandler = nil; process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // If an updated CLI delays its normal exit, bound the helper's lifetime.
        queue.asyncAfter(deadline: .now() + 2) { if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) } }
        buffer.removeAll(keepingCapacity: false)
        let callback = continuation; continuation = nil; callback?.resume(returning: result)
    }
}
