import Foundation

public enum Light: String, Codable, Sendable { case green, red, gray }
public enum Cause: String, Codable, CaseIterable, Sendable {
    case offline, proxy, dns, tls, timeout, reset, service, authentication, disconnect, recovery, configuration, info
    public var title: String {
        switch self {
        case .offline: return "网络离线"
        case .proxy: return "代理异常"
        case .dns: return "DNS 解析失败"
        case .tls: return "证书 / TLS 异常"
        case .timeout: return "连接超时"
        case .reset: return "连接中断"
        case .service: return "服务响应异常"
        case .authentication: return "访问受限"
        case .disconnect: return "客户端断线"
        case .recovery: return "连接恢复"
        case .configuration: return "网络配置变化"
        case .info: return "状态记录"
        }
    }
}

public struct MonitorEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var light: Light
    public var cause: Cause
    public var source: String
    public var message: String
    public init(date: Date = Date(), light: Light, cause: Cause, source: String, message: String) {
        self.id = UUID(); self.date = date; self.light = light; self.cause = cause; self.source = source; self.message = message
    }
}

public struct ProbeResult: Codable, Sendable, Equatable {
    public var label: String
    public var status: Int?
    public var milliseconds: Int?
    public var cause: Cause?
    public var detail: String
    public var date: Date
    public var reachable: Bool { status != nil && cause == nil }
    public init(label: String, status: Int? = nil, milliseconds: Int? = nil, cause: Cause? = nil, detail: String, date: Date = Date()) {
        self.label = label; self.status = status; self.milliseconds = milliseconds; self.cause = cause; self.detail = detail; self.date = date
    }
    public static func http(label: String, status: Int, milliseconds: Int, date: Date = Date()) -> ProbeResult {
        let cause: Cause? = status == 407 ? .proxy : (status == 429 || (500...599).contains(status) ? .service : (status == 403 ? .authentication : nil))
        let detail: String
        switch status {
        case 401, 404, 405: detail = "已到达服务 · HTTP \(status)（未登录探测）"
        case 403: detail = "已收到 HTTP 403 · 探测受限，需结合客户端日志"
        case 407: detail = "HTTP 407 · 代理要求认证"
        case 429: detail = "HTTP 429 · 请求频率受限"
        case 500...599: detail = "HTTP \(status) · 服务或代理上游异常"
        case 200...399: detail = "已到达服务 · HTTP \(status)"
        default: detail = "已收到 HTTP \(status)"
        }
        return ProbeResult(label: label, status: status, milliseconds: milliseconds, cause: cause, detail: detail, date: date)
    }
}

public struct ProxyEndpoint: Codable, Sendable, Equatable {
    public var kind: String
    public var host: String
    public var port: Int
    public var reachable: Bool?
    public init(kind: String, host: String, port: Int, reachable: Bool? = nil) {
        self.kind = kind; self.host = host; self.port = port; self.reachable = reachable
    }
    public var description: String { "\(kind) \(host):\(port)" }
}

public struct NetworkEnvironment: Codable, Sendable, Equatable {
    public var pathAvailable: Bool?
    public var interfaces: [String]
    public var proxies: [ProxyEndpoint]
    public var pacEnabled: Bool
    public var tunnelInterfaces: [String]
    public var tunnelRoutes: [String]
    public var routeReadable: Bool
    public init(pathAvailable: Bool? = nil, interfaces: [String] = [], proxies: [ProxyEndpoint] = [], pacEnabled: Bool = false,
                tunnelInterfaces: [String] = [], tunnelRoutes: [String] = [], routeReadable: Bool = true) {
        self.pathAvailable = pathAvailable; self.interfaces = interfaces; self.proxies = proxies; self.pacEnabled = pacEnabled
        self.tunnelInterfaces = tunnelInterfaces; self.tunnelRoutes = tunnelRoutes; self.routeReadable = routeReadable
    }
    public var proxyDescription: String {
        let endpoints = proxies.map { "\($0.description)\($0.reachable == false ? " · 端口不可达" : "")" }
        return (endpoints + (pacEnabled ? ["PAC 自动代理已开启"] : [])).joined(separator: "；").nilIfEmpty ?? "未开启系统代理"
    }
    public var tunnelDescription: String {
        if !tunnelRoutes.isEmpty { return "默认 / 全局路由经过 " + tunnelRoutes.joined(separator: ", ") }
        if !tunnelInterfaces.isEmpty { return "发现 " + tunnelInterfaces.joined(separator: ", ") + (routeReadable ? " · 未发现全局路由" : " · 路由未能读取") }
        return routeReadable ? "未发现启用的 TUN 接口" : "TUN 状态未能完整读取"
    }
    public var signature: String {
        [proxies.map { $0.description }.joined(separator: ","), String(pacEnabled), tunnelRoutes.joined(separator: ","), interfaces.joined(separator: ",")].joined(separator: "|")
    }
}

public struct Snapshot: Codable, Sendable {
    public var date: Date
    public var environment: NetworkEnvironment
    public var primary: ProbeResult
    public var bypass: ProbeResult?
    public var control: ProbeResult?
    public var codexRunning: Bool
    public var logReadable: Bool
    public var clientIssue: MonitorEvent?
    public var light: Light
    public var summary: String
    public init(date: Date = Date(), environment: NetworkEnvironment, primary: ProbeResult, bypass: ProbeResult? = nil,
                control: ProbeResult? = nil, codexRunning: Bool, logReadable: Bool, clientIssue: MonitorEvent? = nil) {
        self.date = date; self.environment = environment; self.primary = primary; self.bypass = bypass; self.control = control
        self.codexRunning = codexRunning; self.logReadable = logReadable; self.clientIssue = clientIssue
        self.light = .gray; self.summary = "正在检测…"
        (self.light, self.summary) = Diagnosis.evaluate(self)
    }
}

public enum Diagnosis {
    public static func evaluate(_ s: Snapshot) -> (Light, String) {
        if s.environment.pathAvailable == false && s.primary.status == nil {
            return (.red, "Mac 当前没有可用网络，Codex 断线首先与本地网络离线有关。")
        }
        if !s.primary.reachable {
            if s.environment.proxies.contains(where: { $0.reachable == false }) && s.primary.status == nil {
                return (.red, "系统代理已开启但代理端口不可达，疑似代理程序停止或监听端口变化。")
            }
            if s.primary.cause == .authentication {
                if let issue = s.clientIssue {
                    if let uncertain = uncertainIssueSummary(s, issue: issue) { return (.gray, "HTTPS 探测受访问限制；" + uncertain) }
                    return (.red, "Codex 日志仍有\(issue.cause.title)，同时 HTTPS 探测受访问限制，尚不能确认恢复。")
                }
                return (.gray, "已到达服务但 HTTPS 探测收到 403，当前结果无法确认 Codex 是否正常连接。")
            }
            if s.primary.cause == .proxy { return (.red, "代理要求认证或代理连接失败，Codex 的网络路径可能受阻。") }
            if let bypass = s.bypass, bypass.reachable, s.date.timeIntervalSince(bypass.date) < 90, !s.environment.proxies.isEmpty {
                return (.red, "经系统代理访问失败，而不经系统代理的同一服务可达，问题疑似在系统代理路径。")
            }
            switch s.primary.cause {
            case .dns: return (.red, "Codex 服务的域名解析失败，疑似 DNS 或代理的域名解析路径异常。")
            case .tls: return (.red, "Codex 服务的 TLS / 证书校验失败，疑似证书信任或代理拦截问题。")
            case .service: return (.red, "服务探测收到 HTTP \(s.primary.status ?? 0)，疑似服务限流、故障或代理上游异常。")
            case .timeout:
                if let control = s.control, control.reachable, s.date.timeIntervalSince(control.date) < 90 {
                    return (.red, "普通网站可达但 Codex 服务连接超时，疑似该服务的代理规则或上游路径异常。")
                }
                return (.red, "Codex 服务连接超时，目前证据不足以区分本地网络、代理上游与服务端。")
            default: return (.red, "Codex 服务的网络探测失败，需结合下方错误和代理 / TUN 状态定位原因。")
            }
        }
        if let issue = s.clientIssue, s.codexRunning {
            if let uncertain = uncertainIssueSummary(s, issue: issue) { return (.gray, "HTTPS 探测可达；" + uncertain) }
            switch issue.cause {
            case .dns: return (.red, "HTTPS 探测可达，但 Codex 日志仍有 DNS 解析错误，客户端的连接路径尚未确认恢复。")
            case .tls: return (.red, "HTTPS 探测可达，但 Codex 日志仍有证书 / TLS 错误，客户端的连接路径尚未确认恢复。")
            case .timeout: return (.red, "HTTPS 探测可达，但 Codex 日志仍有连接超时，疑似长连接或客户端路径异常。")
            default: return (.red, "HTTPS 探测可达，但 Codex 日志仍有断线 / 重连记录，长连接尚未确认恢复。")
            }
        }
        if !s.codexRunning { return (.gray, "Codex 客户端未运行；服务网络探测可达，启动客户端后可继续监测实际断线。") }
        if !s.logReadable { return (.gray, "服务网络探测可达，但客户端日志不可读，暂时无法判断实际断线状态。") }
        return (.green, "当前服务探测可达，近期客户端日志未见未恢复的网络断线。")
    }

    private static func uncertainIssueSummary(_ s: Snapshot, issue: MonitorEvent) -> String? {
        if !s.logReadable { return "客户端日志当前不可读，已有断线证据不足以确认当前连接，尚不能确认恢复。" }
        let age = s.date.timeIntervalSince(issue.date)
        if age > 86400 || age < -5 { return "已有断线记录超过 24 小时或时间异常，证据不足以确认当前连接，尚不能确认恢复。" }
        return nil
    }

    public static func historySummary(events: [MonitorEvent], since: Date) -> String {
        let failures = events.filter { $0.date >= since && $0.light == .red }
        guard !failures.isEmpty else { return "所选时间内未记录到网络故障。" }
        let grouped = Dictionary(grouping: failures, by: \.cause)
        let top = grouped.max { $0.value.count < $1.value.count }!
        return "所选时间内记录到 \(failures.count) 条异常，最常见的是\(top.key.title)（\(top.value.count) 条）；重复报错不等于独立断线次数。"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
