import Foundation
import Testing
@testable import MonitorCore

@Suite(.serialized) final class CoreTests {
    private var temporaryDirectories: [URL] = []
    deinit { for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) } }
    let now = Date(timeIntervalSince1970: 1_790_876_800)
    func good() -> ProbeResult { .http(label: "系统路径", status: 405, milliseconds: 100, date: now) }
    func snapshot(primary: ProbeResult? = nil, env: NetworkEnvironment = .init(), bypass: ProbeResult? = nil,
                  running: Bool = true, readable: Bool = true, issue: MonitorEvent? = nil) -> Snapshot {
        Snapshot(date: now, environment: env, primary: primary ?? good(), bypass: bypass, codexRunning: running, logReadable: readable, clientIssue: issue)
    }
    func line(_ event: String, extra: String = "", at date: Date? = nil) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(f.string(from: date ?? now)) [info] [electron-message-handler] \(event) \(extra)"
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodexMonitorTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
    func logFile(root: URL, pid: Int32) throws -> URL {
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy/MM/dd"
        let directory = root.appendingPathComponent(f.string(from: now))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("codex-desktop-test-\(pid)-t0-i1-0.log")
    }

    @Test func test405ProvesReachabilityWithoutAuthentication() {
        expectTrue(good().reachable); expectEqual(snapshot().light, .green)
        expectTrue(good().detail.contains("未登录"))
    }
    @Test func test401IsAuthenticationRequirementNotBrokenNetwork() {
        expectTrue(ProbeResult.http(label: "", status: 401, milliseconds: 1).reachable)
    }
    @Test func test403RemainsInconclusive() {
        let s = snapshot(primary: .http(label: "", status: 403, milliseconds: 1))
        expectEqual(s.light, .gray); expectTrue(s.summary.contains("无法确认"))
    }
    @Test func test407MeansProxyAuthenticationFailure() {
        let s = snapshot(primary: .http(label: "", status: 407, milliseconds: 1))
        expectEqual(s.light, .red); expectTrue(s.summary.contains("代理"))
    }
    @Test func testRateLimitAndAllServerErrorCodesAreNotHealthy() {
        for status in [429] + Array(500...599) {
            let probe = ProbeResult.http(label: "", status: status, milliseconds: 1)
            expectEqual(probe.cause, .service)
            expectFalse(probe.reachable)
            expectEqual(snapshot(primary: probe).light, .red)
        }
    }
    @Test func testSuccessfulRequestOverridesAnUnavailablePathHint() {
        expectEqual(snapshot(env: .init(pathAvailable: false)).light, .green)
    }
    @Test func testOfflineRequestAndUnavailablePathAreRed() {
        expectEqual(snapshot(primary: .init(label: "", cause: .offline, detail: ""), env: .init(pathAvailable: false)).light, .red)
    }
    @Test func testDeadProxyPortWithFailedRequestIdentifiesProxy() {
        let s = snapshot(primary: .init(label: "", cause: .reset, detail: ""), env: .init(proxies: [.init(kind: "HTTPS", host: "127.0.0.1", port: 1082, reachable: false)]))
        expectTrue(s.summary.contains("端口不可达"))
    }
    @Test func testDeadUnusedProxyDoesNotOverrideSuccessfulRequest() {
        expectEqual(snapshot(env: .init(proxies: [.init(kind: "HTTP", host: "127.0.0.1", port: 1082, reachable: false)])).light, .green)
    }
    @Test func testFreshBypassComparisonCanSuggestProxyPath() {
        let s = snapshot(primary: .init(label: "", cause: .timeout, detail: ""), env: .init(proxies: [.init(kind: "HTTPS", host: "127.0.0.1", port: 1082)]), bypass: good())
        expectTrue(s.summary.contains("同一服务可达"))
    }
    @Test func testStaleBypassCannotLocateCurrentProxyFault() {
        var old = good(); old.date = now.addingTimeInterval(-120)
        let s = snapshot(primary: .init(label: "", cause: .timeout, detail: ""), env: .init(proxies: [.init(kind: "HTTPS", host: "127.0.0.1", port: 1082)]), bypass: old)
        expectFalse(s.summary.contains("同一服务可达"))
    }
    @Test func testClientNotRunningUsesGray() { expectEqual(snapshot(running: false).light, .gray) }
    @Test func testMissingClientLogsUsesGray() { expectEqual(snapshot(readable: false).light, .gray) }
    @Test func testHTTPSDoesNotClearClientDisconnection() {
        let s = snapshot(issue: .init(date: now, light: .red, cause: .disconnect, source: "Codex", message: ""))
        expectEqual(s.light, .red); expectTrue(s.summary.contains("尚未确认恢复"))
    }
    @Test func testOldAndFutureDisconnectionEvidenceRemainInconclusive() {
        for age in [86401.0, -6.0] {
            let issue = MonitorEvent(date: now.addingTimeInterval(-age), light: .red, cause: .disconnect, source: "Codex", message: "")
            let s = snapshot(issue: issue)
            expectEqual(s.light, .gray); expectTrue(s.summary.contains("证据不足"))
            expectTrue(s.summary.contains("尚不能确认恢复")); expectNotNil(s.clientIssue)
        }
    }
    @Test func testUnreadableLogsCannotConfirmStoredDisconnectionIsCurrent() {
        let s = snapshot(readable: false, issue: .init(date: now, light: .red, cause: .dns, source: "Codex", message: ""))
        expectEqual(s.light, .gray); expectTrue(s.summary.contains("日志当前不可读"))
        expectTrue(s.summary.contains("尚不能确认恢复"))
    }
    @Test func testFreshDisconnectionEvidenceAtAllowedTimeBoundariesRemainsRed() {
        for age in [86400.0, 0.0, -5.0] {
            let issue = MonitorEvent(date: now.addingTimeInterval(-age), light: .red, cause: .disconnect, source: "Codex", message: "")
            expectEqual(snapshot(issue: issue).light, .red)
        }
    }
    @Test func test403DoesNotTurnUncertainStoredDisconnectionRed() {
        let probe = ProbeResult.http(label: "", status: 403, milliseconds: 1, date: now)
        for (age, readable) in [(86401.0, true), (-6.0, true), (0.0, false)] {
            let issue = MonitorEvent(date: now.addingTimeInterval(-age), light: .red, cause: .disconnect, source: "Codex", message: "")
            let s = snapshot(primary: probe, readable: readable, issue: issue)
            expectEqual(s.light, .gray); expectTrue(s.summary.contains("证据不足"))
            expectTrue(s.summary.contains("尚不能确认恢复"))
        }
    }
    @Test func test403WithFreshReadableDisconnectionStillShowsRed() {
        let probe = ProbeResult.http(label: "", status: 403, milliseconds: 1, date: now)
        let issue = MonitorEvent(date: now, light: .red, cause: .disconnect, source: "Codex", message: "")
        expectEqual(snapshot(primary: probe, issue: issue).light, .red)
    }
    @Test func testDNSAndCertificateSummariesStayDistinct() {
        for cause in [Cause.dns, .tls] {
            let s = snapshot(primary: .init(label: "", cause: cause, detail: ""))
            expectEqual(s.light, .red)
        }
        expectEqual(LogParser.networkCause("ENOTFOUND"), .dns)
        expectEqual(LogParser.networkCause("ERR_CERT_AUTHORITY_INVALID"), .tls)
    }
    @Test func testQuotedStateField() {
        expectEqual(LogParser.field("nextState", in: "nextState=\"connected\" previousState=\"error\""), "connected")
        expectEqual(LogParser.field("state", in: "state=connected"), "connected")
    }
    @Test func testConnectedStateOverridesStalePreviousError() {
        let p = LogParser.parse(line("remote_connections.manager_state_set", extra: "hostId=cloud nextState=\"connected\" previousError=ENOTFOUND"))
        expectEqual(p?.event.light, .green); expectTrue(p?.recovery == true)
    }
    @Test func testPubsubFailureAndRecoveryRecognized() {
        let failure = LogParser.parse(line("chatgpt_pubsub_reconnect_exhausted"))
        expectTrue(failure?.failure == true); expectEqual(failure?.event.light, .red)
        let recovery = LogParser.parse(line("chatgpt_pubsub_transport_opened"))
        expectTrue(recovery?.recovery == true); expectEqual(failure?.channel, recovery?.channel)
    }
    @Test func testUnrelatedToolErrorIsNotAClientOutage() {
        expectNil(LogParser.parse(line("[tool] ssh failed", extra: "error=ETIMEDOUT")))
    }
    @Test func testStaticAssetErrorDoesNotSetCurrentClientIssue() {
        let p = LogParser.parse(line("[Fetch] http_request_failed", extra: "url=https://persistent.oaistatic.com/file error=ERR_CERT_AUTHORITY_INVALID"))
        expectEqual(p?.event.light, .gray); expectNil(p?.channel)
    }
    @Test func testCustomRemoteExecutorErrorIsRecordedSeparately() {
        let p = LogParser.parse(line("app_server_connection.reconnect_failed", extra: "transport=websocket hostId=remote-test error=ENOTFOUND"))
        expectEqual(p?.event.light, .gray); expectNil(p?.channel)
    }
    @Test func testCustomRemoteNamesContainingCoreHostWordsRemainSeparate() {
        for host in ["my-cloud-vm", "chatgpt-custom", "cloud-backup", "unknown"] {
            let failure = LogParser.parse(line("app_server_connection.reconnect_failed", extra: "transport=websocket hostId=\(host) error=ENOTFOUND"))
            expectEqual(failure?.event.light, .gray); expectNil(failure?.channel); expectTrue(failure?.failure == false)
            let recovery = LogParser.parse(line("remote_connections.manager_state_set", extra: "hostId=\(host) nextState=connected"))
            expectEqual(recovery?.event.light, .gray); expectNil(recovery?.channel); expectTrue(recovery?.recovery == false)
        }
    }
    @Test func testOnlyExactCoreHostIDsControlDisconnectionState() {
        for host in ["local", "cloud", "chatgpt"] {
            let failure = LogParser.parse(line("app_server_connection.reconnect_failed", extra: "transport=websocket hostId=\(host) error=ENOTFOUND"))
            expectEqual(failure?.event.light, .red); expectNotNil(failure?.channel); expectTrue(failure?.failure == true)
            let recovery = LogParser.parse(line("remote_connections.manager_state_set", extra: "hostId=\(host) nextState=connected"))
            expectEqual(recovery?.event.light, .green); expectTrue(recovery?.recovery == true)
            expectEqual(failure?.channel, recovery?.channel)
        }
    }
    @Test func testRawSecretsAndURLsAreNotCopiedIntoEvents() throws {
        let secret = "private-prompt-example-token"
        let p = try requireValue(LogParser.parse(line("chatgpt_pubsub_reconnect_failed", extra: "error=ENOTFOUND url=https://example.invalid/?token=\(secret) prompt=\(secret)")))
        let json = String(decoding: try JSONEncoder().encode(p.event), as: UTF8.self)
        expectFalse(json.contains(secret)); expectFalse(json.contains("example.invalid")); expectFalse(json.contains("token="))
    }
    @Test func testReaderClearsFailureOnlyAfterExplicitRecovery() throws {
        let root = try temporary(); let file = try logFile(root: root, pid: 123)
        try (line("chatgpt_pubsub_reconnect_exhausted") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = LogReader(root: root)
        expectNotNil(reader.scan(now: now, pid: 123).issue)
        expectNotNil(reader.scan(now: now.addingTimeInterval(180), pid: 123).issue)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("chatgpt_pubsub_transport_opened", at: now.addingTimeInterval(181)) + "\n").utf8)); try handle.close()
        expectNil(reader.scan(now: now.addingTimeInterval(182), pid: 123).issue)
    }
    @Test func testReaderRetainsOldFailureButDiagnosisDoesNotClaimItIsCurrent() throws {
        let root = try temporary(); let file = try logFile(root: root, pid: 123)
        try (line("chatgpt_pubsub_reconnect_exhausted") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = LogReader(root: root); expectNotNil(reader.scan(now: now, pid: 123).issue)
        let later = now.addingTimeInterval(86401)
        let scan = reader.scan(now: later, pid: 123)
        expectNotNil(scan.issue)
        let s = Snapshot(date: later, environment: .init(), primary: good(), codexRunning: true, logReadable: scan.readable, clientIssue: scan.issue)
        expectEqual(s.light, .gray); expectTrue(s.summary.contains("尚不能确认恢复"))
    }
    @Test func testRemovedLogFileRetainsFailureButUsesInconclusiveLight() throws {
        let root = try temporary(); let file = try logFile(root: root, pid: 123)
        try (line("chatgpt_pubsub_reconnect_exhausted") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = LogReader(root: root); expectNotNil(reader.scan(now: now, pid: 123).issue)
        try FileManager.default.removeItem(at: file)
        let scan = reader.scan(now: now.addingTimeInterval(1), pid: 123)
        expectNotNil(scan.issue); expectFalse(scan.readable)
        let s = snapshot(readable: scan.readable, issue: scan.issue)
        expectEqual(s.light, .gray); expectTrue(s.summary.contains("日志当前不可读"))
    }
    @Test func testReaderDoesNotTreatOtherProcessHistoryAsCurrent() throws {
        let root = try temporary(); let file = try logFile(root: root, pid: 999)
        try (line("chatgpt_pubsub_reconnect_exhausted") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let scan = LogReader(root: root).scan(now: now, pid: 123)
        expectNil(scan.issue); expectEqual(scan.events.count, 1); expectFalse(scan.readable)
    }
    @Test func testReaderWaitsForCompleteLineAndDoesNotDuplicate() throws {
        let root = try temporary(); let file = try logFile(root: root, pid: 123)
        try line("chatgpt_pubsub_reconnect_exhausted").write(to: file, atomically: true, encoding: .utf8)
        let reader = LogReader(root: root); expectEqual(reader.scan(now: now, pid: 123).events.count, 0)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
        expectEqual(reader.scan(now: now, pid: 123).events.count, 1)
        expectEqual(reader.scan(now: now, pid: 123).events.count, 0)
    }
    @Test func testReaderBoundsInitialFileTail() throws {
        let root = try temporary(); let file = try logFile(root: root, pid: 123)
        var data = Data(repeating: 65, count: 3 * 1024 * 1024); data.append(10)
        data.append(Data((line("chatgpt_pubsub_reconnect_exhausted") + "\n").utf8)); try data.write(to: file)
        let scan = LogReader(root: root).scan(now: now, pid: 123)
        expectTrue(scan.truncated); expectEqual(scan.events.count, 1); expectNotNil(scan.issue)
    }
    @Test func testTunnelInterfaceAloneDoesNotProveGlobalRouting() {
        expectTrue(RouteParser.tunnels(in: "198.18.0/15 link#24 UCS utun4").isEmpty)
        expectTrue(NetworkEnvironment(tunnelInterfaces: ["utun4"]).tunnelDescription.contains("未发现全局路由"))
    }
    @Test func testTunnelGlobalAndSplitRoutesAreDetected() {
        expectEqual(RouteParser.tunnels(in: "default link#24 UCSg utun4\ndefault 192.168.0.1 UGScIg en0"), ["utun4"])
        expectEqual(RouteParser.tunnels(in: "0/1 link#24 UCS utun2\n128.0/1 link#24 UCS utun2"), ["utun2"])
    }
    @Test func testScopedTunnelDefaultIsNotGlobal() { expectTrue(RouteParser.tunnels(in: "default link#24 UGScI utun0").isEmpty) }
    @Test func testHistoryDeduplicatesAndSurvivesRestart() throws {
        let root = try temporary(); let store = HistoryStore(directory: root, now: now)
        let event = MonitorEvent(date: now, light: .red, cause: .dns, source: "Codex", message: "DNS 解析失败")
        store.append([event, event], now: now); expectEqual(store.events.count, 1); expectFalse(store.writeError)
        let reload = HistoryStore(directory: root, now: now); expectEqual(reload.events.count, 1)
        reload.append([event], now: now); expectEqual(reload.events.count, 1)
    }
    @Test func testHistorySkipsDamagedRecordsAndOldEvents() throws {
        let root = try temporary(); let valid = MonitorEvent(date: now, light: .green, cause: .info, source: "监测器", message: "正常")
        var data = Data("damaged\n".utf8); data.append(try JSONEncoder().encode(valid)); data.append(10)
        try data.write(to: root.appendingPathComponent("history.jsonl"))
        let store = HistoryStore(directory: root, now: now); expectEqual(store.events.count, 1)
        store.append([.init(date: now.addingTimeInterval(-8 * 86400), light: .red, cause: .dns, source: "Codex", message: "旧记录")], now: now)
        expectEqual(store.events.count, 1)
    }
    @Test func testHistorySummaryDoesNotClaimIndependentOutages() {
        let event = MonitorEvent(date: now, light: .red, cause: .dns, source: "Codex", message: "")
        let summary = Diagnosis.historySummary(events: [event, event], since: now.addingTimeInterval(-1))
        expectTrue(summary.contains("2 条异常")); expectTrue(summary.contains("不等于独立断线次数"))
    }
}

private func expectTrue(_ value: Bool) { #expect(value) }
private func expectFalse(_ value: Bool) { #expect(!value) }
private func expectEqual<T: Equatable>(_ left: T, _ right: T) { #expect(left == right) }
private func expectNil<T>(_ value: T?) { #expect(value == nil) }
private func expectNotNil<T>(_ value: T?) { #expect(value != nil) }
private func requireValue<T>(_ value: T?) throws -> T { try #require(value) }
