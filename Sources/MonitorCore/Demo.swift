import Foundation

/// Synthetic fixtures for screenshots and UI review. Never samples the host or account.
public enum DemoScenario: String, CaseIterable, Sendable {
    case healthy, proxy

    public func snapshot(now: Date = Date()) -> Snapshot {
        let failed = self == .proxy
        let environment = NetworkEnvironment(pathAvailable: true, interfaces: ["en0", "utun0"],
            proxies: [.init(kind: "HTTPS", host: "127.0.0.1", port: 7890, reachable: !failed)],
            tunnelInterfaces: ["utun0"], tunnelRoutes: ["utun0"])
        let primary: ProbeResult = failed
            ? .init(label: "系统网络路径", milliseconds: 2000, cause: .proxy, detail: "代理连接失败 · 网络错误 -1004", date: now)
            : .http(label: "系统网络路径", status: 405, milliseconds: 186, date: now)
        return Snapshot(date: now, environment: environment, primary: primary,
            bypass: .http(label: "不经系统代理", status: 405, milliseconds: 212, date: now),
            control: failed ? .init(label: "普通网站", milliseconds: 2000, cause: .proxy, detail: "代理端口不可达", date: now)
                : .http(label: "普通网站", status: 200, milliseconds: 95, date: now),
            codexRunning: true, logReadable: true,
            clientIssue: failed ? .init(date: now, light: .red, cause: .proxy, source: "Codex · 服务连接", message: "演示：代理连接失败，客户端正在重连。") : nil)
    }

    public func usage(now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(fiveHour: .init(usedPercent: 28, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)),
            weekly: .init(usedPercent: 54, durationMinutes: 10080, resetsAt: now.addingTimeInterval(172800)), updatedAt: now)
    }

    public func events(now: Date = Date()) -> [MonitorEvent] {
        var events: [MonitorEvent] = [
            .init(date: now.addingTimeInterval(-300), light: .gray, cause: .info, source: "演示模式", message: "以下全部为合成数据，不读取真实账号、网络配置或客户端日志。"),
            .init(date: now.addingTimeInterval(-240), light: .gray, cause: .configuration, source: "网络配置", message: "演示代理 127.0.0.1:7890；演示 TUN 路由 utun0。"),
            .init(date: now.addingTimeInterval(-180), light: .green, cause: .info, source: "定时探测", message: "服务路径可达；演示探测 HTTP 405。"),
            .init(date: now.addingTimeInterval(-120), light: .green, cause: .recovery, source: "Codex · 通知长连接", message: "演示：客户端连接已建立。")
        ]
        if self == .proxy {
            events.append(.init(date: now.addingTimeInterval(-30), light: .red, cause: .proxy, source: "Codex · 服务连接", message: "演示：代理连接失败，客户端正在重连。"))
            events.append(.init(date: now, light: .red, cause: .proxy, source: "定时探测", message: "服务路径未确认可达；演示代理已开启但监听端口不可达。"))
        } else {
            events.append(.init(date: now, light: .green, cause: .info, source: "定时探测", message: "服务路径可达；演示服务与客户端连接均正常。"))
        }
        return events
    }
}
