import Foundation
import Network
import CFNetwork
import Darwin

public struct SampleInput: Sendable {
    public var pid: Int32?
    public var pathAvailable: Bool?
    public init(pid: Int32?, pathAvailable: Bool?) { self.pid = pid; self.pathAvailable = pathAvailable }
}
public struct SampleOutput: Sendable {
    public var snapshot: Snapshot
    public var events: [MonitorEvent]
}

public enum RouteParser {
    public static func tunnels(in table: String) -> [String] {
        var found = Set<String>()
        for line in table.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 4,
                  ["default", "0/1", "0.0.0.0/1", "128.0/1", "128.0.0.0/1", "::/1", "8000::/1"].contains(parts[0]),
                  !parts[2].contains("I"), parts[3].hasPrefix("utun") || parts[3].hasPrefix("tun") else { continue }
            found.insert(parts[3])
        }
        return found.sorted()
    }
}

private enum NetworkProbe {
    static let target = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let control = URL(string: "https://www.apple.com/library/test/success.html")!

    static func request(url: URL, label: String, bypassSystemProxy: Bool = false) async -> ProbeResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7; configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        if bypassSystemProxy {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesSOCKSEnable as String: 0, kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
            ]
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 7)
        request.httpMethod = "HEAD"; request.setValue("CodexNetworkMonitor/1.1", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(label: label, cause: .reset, detail: "未收到有效 HTTP 响应")
            }
            return .http(label: label, status: http.statusCode, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            let code = (error as NSError).code
            let cause: Cause
            if (error as NSError).domain != NSURLErrorDomain { cause = .reset }
            else {
                switch URLError.Code(rawValue: code) {
                case .notConnectedToInternet: cause = .offline
                case .cannotFindHost, .dnsLookupFailed: cause = .dns
                case .timedOut: cause = .timeout
                case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected: cause = .tls
                case .userAuthenticationRequired: cause = .authentication
                default: cause = .reset
                }
            }
            return ProbeResult(label: label, milliseconds: Int(Date().timeIntervalSince(start) * 1000), cause: cause,
                               detail: "\(cause.title) · 网络错误 \(code)")
        }
    }

    static func port(_ endpoint: ProxyEndpoint) async -> Bool {
        guard endpoint.port > 0, endpoint.port <= 65535 else { return false }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "codex-monitor.proxy-port")
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: UInt16(endpoint.port))!, using: .tcp)
            let gate = PortGate(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state { case .ready: gate.finish(true); case .failed: gate.finish(false); default: break }
            }
            queue.asyncAfter(deadline: .now() + 2) { gate.finish(false) }
            connection.start(queue: queue)
        }
    }

    static func proxies() -> ([ProxyEndpoint], Bool) {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return ([], false) }
        var endpoints: [ProxyEndpoint] = []
        for (kind, enabled, host, port) in [
            ("HTTPS", "HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
            ("HTTP", "HTTPEnable", "HTTPProxy", "HTTPPort"),
            ("SOCKS", "SOCKSEnable", "SOCKSProxy", "SOCKSPort")
        ] {
            if (settings[enabled] as? NSNumber)?.boolValue == true, let h = settings[host] as? String, let p = settings[port] as? NSNumber,
               h.range(of: "^[A-Za-z0-9.:_-]{1,253}$", options: .regularExpression) != nil {
                endpoints.append(ProxyEndpoint(kind: kind, host: h, port: p.intValue))
            }
        }
        let pac = (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true || (settings["ProxyAutoDiscoveryEnable"] as? NSNumber)?.boolValue == true
        return (endpoints, pac)
    }

    static func interfaces() -> ([String], [String]) {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return ([], []) }
        defer { freeifaddrs(first) }
        var all = Set<String>(), tunnels = Set<String>(); var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            let info = node.pointee; cursor = info.ifa_next
            guard info.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = info.ifa_addr, [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { continue }
            let name = String(cString: info.ifa_name)
            guard name.range(of: "^[a-z][a-z0-9]{0,15}$", options: .regularExpression) != nil else { continue }
            if name.hasPrefix("utun") || name.hasPrefix("tun") { tunnels.insert(name) }
            if name != "lo0" { all.insert(name) }
        }
        return (all.sorted(), tunnels.sorted())
    }

    static func routeTable(family: String) async -> String? {
        // Uses a fixed read-only command, never a shell, proxy configuration, or privileged operation.
        await withCheckedContinuation { continuation in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            process.arguments = ["-rn", "-f", family]
            let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
            let gate = ProcessGate(continuation: continuation)
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                gate.finish(process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
            do { try process.run() } catch { gate.finish(nil); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                gate.finish(nil)
                if process.isRunning { process.terminate() }
            }
        }
    }
}

private final class PortGate: @unchecked Sendable {
    let lock = NSLock()
    let connection: NWConnection
    var continuation: CheckedContinuation<Bool, Never>?
    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) { self.connection = connection; self.continuation = continuation }
    func finish(_ value: Bool) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return }
        connection.stateUpdateHandler = nil; connection.cancel(); pending.resume(returning: value)
    }
}

private final class ProcessGate: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<String?, Never>?
    init(continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func finish(_ value: String?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: value)
    }
}

public actor NetworkSampler {
    private let logs: LogReader
    private var lastExtraCheck = Date.distantPast
    private var bypass: ProbeResult?
    private var control: ProbeResult?
    private var lastSignature: String?
    public init(logRoot: URL) { self.logs = LogReader(root: logRoot) }

    public func sample(_ input: SampleInput, forceDiagnostics: Bool = false) async -> SampleOutput {
        let start = Date()
        let (endpoints, pac) = NetworkProbe.proxies()
        let (interfaces, tunnels) = NetworkProbe.interfaces()
        async let v4 = NetworkProbe.routeTable(family: "inet")
        async let v6 = NetworkProbe.routeTable(family: "inet6")
        async let main = NetworkProbe.request(url: NetworkProbe.target, label: "系统网络路径")
        var proxies: [ProxyEndpoint] = []
        for var endpoint in endpoints {
            if let checked = proxies.first(where: { $0.host == endpoint.host && $0.port == endpoint.port }) { endpoint.reachable = checked.reachable }
            else { endpoint.reachable = await NetworkProbe.port(endpoint) }
            proxies.append(endpoint)
        }
        let (table4, table6, primary) = await (v4, v6, main)
        let env = NetworkEnvironment(pathAvailable: input.pathAvailable, interfaces: interfaces, proxies: proxies, pacEnabled: pac,
                                     tunnelInterfaces: tunnels, tunnelRoutes: Array(Set(RouteParser.tunnels(in: table4 ?? "") + RouteParser.tunnels(in: table6 ?? ""))).sorted(),
                                     routeReadable: table4 != nil || table6 != nil)
        if forceDiagnostics || !primary.reachable || lastSignature != env.signature || start.timeIntervalSince(lastExtraCheck) > 60 {
            async let extra = NetworkProbe.request(url: NetworkProbe.target, label: "不经系统代理（仍遵循 TUN 路由）", bypassSystemProxy: true)
            async let ordinary = NetworkProbe.request(url: NetworkProbe.control, label: "普通网站 · 系统路径")
            (bypass, control) = await (extra, ordinary); lastExtraCheck = Date()
        }
        let scan = logs.scan(now: Date(), pid: input.pid)
        var events = scan.events
        if lastSignature != env.signature {
            events.append(.init(light: .gray, cause: .configuration, source: "网络配置", message: env.proxyDescription + "；" + env.tunnelDescription))
            lastSignature = env.signature
        }
        if scan.truncated {
            events.append(.init(light: .gray, cause: .info, source: "日志读取", message: "日志较大，本次只读取各文件尾部 2 MB；历史统计可能不完整。"))
        }
        return SampleOutput(snapshot: Snapshot(environment: env, primary: primary, bypass: bypass, control: control,
                                               codexRunning: input.pid != nil, logReadable: scan.readable, clientIssue: scan.issue), events: events)
    }
}
