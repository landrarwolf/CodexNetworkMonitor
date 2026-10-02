import Foundation

public final class HistoryStore {
    public let directory: URL
    public let file: URL
    public private(set) var events: [MonitorEvent] = []
    public private(set) var writeError: Bool = false
    private var fingerprint: Set<String> = []
    private var pendingCount = 0
    private let retention: TimeInterval = 7 * 86400
    private let maxEvents = 20000

    public init(directory: URL, now: Date = Date()) {
        self.directory = directory; self.file = directory.appendingPathComponent("history.jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let size = try handle.seekToEnd()
                let truncated = size > 12 * 1024 * 1024
                try handle.seek(toOffset: truncated ? size - 12 * 1024 * 1024 : 0)
                let data = try handle.readToEnd() ?? Data()
                var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                if truncated && !lines.isEmpty { lines.removeFirst() }
                let decoder = JSONDecoder()
                events = lines.compactMap { try? decoder.decode(MonitorEvent.self, from: Data($0.utf8)) }
                    .filter { $0.date >= now.addingTimeInterval(-retention) && $0.date <= now.addingTimeInterval(5) }
                events = Array(events.sorted { $0.date < $1.date }.suffix(maxEvents))
                fingerprint = Set(events.map(key))
            }
        } catch { writeError = true }
    }

    public func append(_ additions: [MonitorEvent], now: Date = Date()) {
        let fresh = additions.filter { event in
            guard event.date >= now.addingTimeInterval(-retention), event.date <= now.addingTimeInterval(5) else { return false }
            return fingerprint.insert(key(event)).inserted
        }
        guard !fresh.isEmpty else { return }
        events.append(contentsOf: fresh); events.sort { $0.date < $1.date }; pendingCount += fresh.count
        let trimmed = events.count > maxEvents || events.first.map { $0.date < now.addingTimeInterval(-retention) } == true
        if trimmed { events = Array(events.filter { $0.date >= now.addingTimeInterval(-retention) }.suffix(maxEvents)); fingerprint = Set(events.map(key)) }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            if trimmed || pendingCount >= 100 {
                var data = Data()
                for event in events { data.append(try encoder.encode(event)); data.append(10) }
                try data.write(to: file, options: .atomic); pendingCount = 0
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } else {
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.seekToEnd()
                for event in fresh { try handle.write(contentsOf: encoder.encode(event)); try handle.write(contentsOf: Data([10])) }
            }
            writeError = false
        } catch { writeError = true }
    }

    private func key(_ event: MonitorEvent) -> String {
        "\(Int64(event.date.timeIntervalSince1970 * 1000))|\(event.source)|\(event.cause.rawValue)|\(event.message)"
    }
}
