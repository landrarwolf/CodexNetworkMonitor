import Foundation
import CryptoKit

public struct ParsedLog: Sendable {
    public var event: MonitorEvent
    public var channel: String?
    public var failure: Bool
    public var recovery: Bool
}

public enum LogParser {
    // Only controlled phrases and error enums are emitted. Original lines never leave this parser.
    public static func parse(_ line: String) -> ParsedLog? {
        guard let stamp = line.split(separator: " ").first,
              let date = timestamp(String(stamp)) else { return nil }
        let lower = line.lowercased()
        let pubsub = lower.contains("chatgpt_pubsub_")
        let transport = lower.contains("app_server_connection.") && lower.contains("websocket")
        let manager = lower.contains("remote_connections.manager_state_set") || lower.contains("remote_connections.connection_state_changed")
        let stream = lower.contains("stream disconnected before completion") || lower.contains("error sending request for url") && lower.contains("codex")
        let ownNetwork = pubsub || transport || manager || stream
        let host = field("hostId", in: line)
        // Custom remote executors are recorded but don't assert that the ChatGPT client itself is offline.
        let customRemote = (transport || manager) && !["local", "cloud", "chatgpt"].contains(host ?? "")
        let channel: String? = pubsub ? "pubsub" : stream ? "responses" : (transport || manager) ? "transport:" + hash(host ?? "unknown") : nil
        let source = pubsub ? "Codex · 通知长连接" : customRemote ? "Codex · 远端连接" : "Codex · 服务连接"
        let currentState = field("nextState", in: line) ?? field("state", in: line) ?? ""
        let recovered = ownNetwork && (lower.contains("chatgpt_pubsub_transport_opened") || lower.contains("chatgpt_pubsub_topic_subscribed") || currentState.lowercased() == "connected")
        if recovered {
            return ParsedLog(event: .init(date: date, light: customRemote ? .gray : .green, cause: .recovery, source: source,
                                         message: customRemote ? "远端连接日志确认连接已建立。" : "客户端日志确认连接已建立。"),
                             channel: customRemote ? nil : channel, failure: false, recovery: !customRemote)
        }
        let abnormalClose = field("code", in: line) == "1006"
        let connectionFailure = ownNetwork && (
            lower.contains("reconnect_failed") || lower.contains("reconnect_exhausted") || lower.contains("reconnect_scheduled") ||
            lower.contains("stream disconnected before completion") || abnormalClose || ["error", "disconnected", "reconnecting"].contains(currentState.lowercased())
        )
        let cause = networkCause(line)
        if connectionFailure || (ownNetwork && cause != nil && !lower.contains("previouserror=") && !recovered) {
            let c = cause ?? .disconnect
            return ParsedLog(event: .init(date: date, light: customRemote ? .gray : .red, cause: c, source: source,
                                         message: c == .disconnect ? "客户端连接中断，正在重连或重试已耗尽。" : "客户端日志记录：\(c.title)。"),
                             channel: customRemote ? nil : channel, failure: !customRemote, recovery: false)
        }
        // Asset/plugin/tool failures are visible without turning an unrelated error into a core-client outage.
        if let cause, lower.contains("persistent.oaistatic.com") || lower.contains("[fetch]") || lower.contains("http_request_failed") {
            return ParsedLog(event: .init(date: date, light: .gray, cause: cause, source: "Codex · 资源请求", message: "客户端资源请求记录：\(cause.title)；不据此判断服务长连接断线。"), channel: nil, failure: false, recovery: false)
        }
        return nil
    }

    public static func networkCause(_ line: String) -> Cause? {
        let s = line.lowercased()
        if ["err_internet_disconnected", "network is unreachable", "enetunreach"].contains(where: s.contains) { return .offline }
        if ["enotfound", "eai_again", "err_name_not_resolved", "cannot find host", "could not resolve"].contains(where: s.contains) { return .dns }
        if ["err_cert_", "certificate verify failed", "unable_to_verify", "self_signed_cert", "tls handshake", "certificate has expired"].contains(where: s.contains) { return .tls }
        if ["err_proxy_connection_failed", "proxy authentication", "err_tunnel_connection_failed"].contains(where: s.contains) { return .proxy }
        if ["etimedout", "err_connection_timed_out", "timed out", "timeout"].contains(where: s.contains) { return .timeout }
        if ["econnreset", "econnrefused", "err_connection_closed", "err_network_changed", "connection reset"].contains(where: s.contains) { return .reset }
        return nil
    }

    public static func field(_ name: String, in line: String) -> String? {
        // Handles tracing's quoted scalars, including escaped quotes; never return arbitrary text to UI.
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + "=(?:\\\\?\")?([A-Za-z0-9_./:-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
    public static func timestamp(_ value: String) -> Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime]; return format.date(from: value)
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LogScan: Sendable {
    public var events: [MonitorEvent]
    public var issue: MonitorEvent?
    public var readable: Bool
    public var truncated: Bool
}

public final class LogReader {
    private struct Cursor { var offset: UInt64; var remainder: Data }
    private var cursors: [URL: Cursor] = [:]
    private var failures: [String: MonitorEvent] = [:]
    private var currentPID: Int32?
    private let root: URL
    public init(root: URL) { self.root = root }

    public func scan(now: Date, pid: Int32?) -> LogScan {
        if pid != currentPID { cursors.removeAll(); failures.removeAll(); currentPID = pid }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var files: [URL] = []
        for shift in [0, -1] {
            let date = calendar.date(byAdding: .day, value: shift, to: now)!
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            files += urls.filter { $0.pathExtension == "log" }
        }
        files = files.sorted { (($0.resourceValueDate) ?? .distantPast) > (($1.resourceValueDate) ?? .distantPast) }
        // Historical files can appear in the timeline, but only the running PID controls the current light.
        let activeFiles = pid.map { process in files.filter { $0.lastPathComponent.contains("-\(process)-t") } } ?? []
        let selected = Array(Set(Array(files.prefix(12)) + activeFiles)).sorted { $0.path < $1.path }
        var parsed: [(ParsedLog, Bool)] = []
        var readable = false, truncated = false
        for url in selected {
            guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { continue }
            defer { try? handle.close() }
            let active = activeFiles.contains(url)
            if active { readable = true }
            var cursor = cursors[url] ?? Cursor(offset: 0, remainder: Data())
            if size < cursor.offset { cursor = Cursor(offset: 0, remainder: Data()) }
            let limit: UInt64 = 2 * 1024 * 1024
            let skipped = size - cursor.offset > limit
            if skipped { cursor = Cursor(offset: size - limit, remainder: Data()); truncated = true }
            guard (try? handle.seek(toOffset: cursor.offset)) != nil, let data = try? handle.readToEnd() else { continue }
            var combined = cursor.remainder + data
            if skipped, let newline = combined.firstIndex(of: 10) { combined = Data(combined.suffix(from: newline + 1)) }
            if let last = combined.lastIndex(of: 10) {
                let complete = combined.prefix(through: last)
                for line in String(decoding: complete, as: UTF8.self).split(separator: "\n") {
                    if let event = LogParser.parse(String(line)), event.event.date >= now.addingTimeInterval(-86400), event.event.date <= now.addingTimeInterval(5) {
                        parsed.append((event, active))
                    }
                }
                cursor.remainder = Data(combined.suffix(from: last + 1))
            } else { cursor.remainder = combined.count < 65536 ? combined : Data() }
            cursor.offset += UInt64(data.count); cursors[url] = cursor
        }
        var events: [MonitorEvent] = []
        for (entry, active) in parsed.sorted(by: { $0.0.event.date < $1.0.event.date }) {
            events.append(entry.event)
            guard active, let channel = entry.channel else { continue }
            if entry.recovery { failures.removeValue(forKey: channel) }
            if entry.failure { failures[channel] = entry.event }
        }
        cursors = cursors.filter { selected.contains($0.key) }
        let issue = failures.values.max { $0.date < $1.date }
        return LogScan(events: events, issue: issue, readable: readable, truncated: truncated)
    }
}

private extension URL {
    var resourceValueDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
