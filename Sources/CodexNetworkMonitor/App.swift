import AppKit
import SwiftUI
import Combine
import Network
import UserNotifications
import UniformTypeIdentifiers
import MonitorCore

enum TimeRange: String, CaseIterable, Identifiable {
    case quarter = "15 分钟", hour = "1 小时", day = "24 小时"
    var id: String { rawValue }
    var seconds: TimeInterval { switch self { case .quarter: return 900; case .hour: return 3600; case .day: return 86400 } }
}

@MainActor final class MonitorModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var events: [MonitorEvent] = []
    @Published var range: TimeRange = .hour
    @Published var errorsOnly = false
    @Published var isChecking = false
    @Published var isPaused = false
    @Published var isSleeping = false
    @Published var notificationsEnabled = false
    @Published var notice: String?
    @Published var storageError = false
    @Published var usage: UsageSnapshot?
    @Published var usageError: String?
    @Published var isUsageChecking = false
    var onStatusChanged: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    let demo: DemoScenario?
    private let store: HistoryStore?
    private let sampler: NetworkSampler?
    private let usageService: UsageService?
    private var usageTask: Task<Void, Never>?
    private var lastUsageAttempt = Date.distantPast
    private let path = NWPathMonitor()
    private var pathAvailable: Bool?
    private var pathSignature: String?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var refreshPending = false
    private var observations: [NSObjectProtocol] = []
    private var previousLight: Light?
    private var lastNotification = Date.distantPast
    private var didInitialSample = false

    init(dataDirectory: URL, demo: DemoScenario? = nil) {
        self.demo = demo
        if demo != nil {
            // Branch before touching persistence, logs, the CLI, or network services.
            store = nil; sampler = nil; usageService = nil
        } else {
            let history = HistoryStore(directory: dataDirectory)
            store = history; events = history.events; storageError = history.writeError
            notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
            sampler = NetworkSampler(logRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex"))
            usageService = UsageService(executable: CodexCLI.locate(application: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")),
                                        runtimeDirectory: dataDirectory.appendingPathComponent("codex-runtime"))
        }
    }
    var light: Light { isPaused || isSleeping ? .gray : snapshot?.light ?? .gray }
    var statusTitle: String {
        if isSleeping { return "系统休眠" }; if isPaused { return "监测已暂停" }
        switch light { case .green: return "当前连通"; case .red: return "检测到异常"; case .gray: return snapshot == nil ? "正在检测" : "等待确认" }
    }
    var summary: String {
        if isPaused { return "监测已暂停，恢复后将重新检测网络与客户端日志。" }
        if isSleeping { return "系统正在休眠，唤醒后会重新检测。" }
        return snapshot?.summary ?? "正在读取代理、TUN 和客户端连接记录…"
    }
    var selectedEvents: [MonitorEvent] { events.filter { $0.date >= Date().addingTimeInterval(-range.seconds) } }
    var visibleEvents: [MonitorEvent] { Array(selectedEvents.filter { !errorsOnly || $0.light == .red }.suffix(500).reversed()) }
    var historySummary: String { Diagnosis.historySummary(events: events, since: Date().addingTimeInterval(-range.seconds)) }
    var clientErrors: Int { selectedEvents.filter { $0.source.hasPrefix("Codex") && $0.light == .red }.count }
    var probeRate: String {
        let samples = selectedEvents.filter { $0.source == "定时探测" }
        guard !samples.isEmpty else { return "—" }
        let reachable = samples.filter { $0.message.contains("服务路径可达") }.count
        return String(format: "%.0f%%", Double(reachable) / Double(samples.count) * 100)
    }
    var usageIsStale: Bool { usageError != nil || (usage.map { Date().timeIntervalSince($0.updatedAt) > 90 } ?? true) || isPaused || isSleeping }
    var menuTitle: String {
        func percent(_ window: UsageWindow?) -> String { window?.remainingPercent.map { String(format: "%.0f", $0) } ?? "—" }
        return "\(demo == nil ? "Codex" : "DEMO") 5h余\(percent(usage?.fiveHour))% 周余\(percent(usage?.weekly))%\(usage != nil && usageIsStale ? "*" : "")"
    }
    func refreshUsage(force: Bool = false) {
        guard let usageService, !isPaused, !isSleeping, !isUsageChecking, force || Date().timeIntervalSince(lastUsageAttempt) >= 60 else { return }
        isUsageChecking = true; lastUsageAttempt = Date()
        usageTask = Task {
            let result = await usageService.read()
            defer { isUsageChecking = false; usageTask = nil }
            guard !Task.isCancelled, !isPaused, !isSleeping else { return }
            switch result { case .success(let value): usage = value; usageError = nil; case .failure(let failure): usageError = failure.message }
            onStatusChanged?()
        }
    }

    static func codexPID() -> Int32? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated }?.processIdentifier
    }
    func start() {
        if let demo { loadDemo(demo); return }
        path.pathUpdateHandler = { [weak self] update in
            let available = update.status == .satisfied
            let signature = "\(available)|" + update.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in
                guard let self else { return }
                self.pathAvailable = available
                if signature != self.pathSignature { self.pathSignature = signature; self.refresh() }
            }
        }
        path.start(queue: DispatchQueue(label: "codex-monitor.path", qos: .utility))
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isSleeping = true; self?.task?.cancel(); self?.usageTask?.cancel(); self?.onStatusChanged?() }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.isSleeping = false
                self.record([.init(light: .gray, cause: .info, source: "监测器", message: "Mac 已唤醒，重新检测；休眠期间不计作网络断线。")])
                self.refresh(force: true); self.onStatusChanged?()
            }
        })
        refresh(force: true)
    }
    func refresh(force: Bool = false) {
        guard !isPaused, !isSleeping else { return }
        if let demo { loadDemo(demo); return }
        guard let sampler else { return }
        refreshUsage(force: force)
        guard !isChecking else { if force { refreshPending = true }; return }
        isChecking = true
        let input = SampleInput(pid: Self.codexPID(), pathAvailable: pathAvailable)
        task = Task {
            let output = await sampler.sample(input, forceDiagnostics: force)
            defer {
                isChecking = false; task = nil
                if refreshPending { refreshPending = false; refresh(force: true) }
            }
            guard !Task.isCancelled, !isPaused, !isSleeping else { return }
            snapshot = output.snapshot
            let snapshot = output.snapshot
            let sample = MonitorEvent(date: snapshot.date, light: snapshot.light, cause: snapshot.primary.cause ?? snapshot.clientIssue?.cause ?? .info,
                                      source: "定时探测", message: (snapshot.primary.reachable ? "服务路径可达" : "服务路径未确认可达") + "；" + snapshot.summary)
            var batch = output.events + [sample]
            if previousLight == .red && snapshot.light == .green {
                batch.append(.init(light: .green, cause: .recovery, source: "监测器", message: "网络探测与近期客户端日志已满足恢复条件。"))
            }
            record(batch)
            if didInitialSample && previousLight != snapshot.light && (snapshot.light == .red || previousLight == .red && snapshot.light == .green) {
                sendNotification(title: snapshot.light == .red ? "Codex 网络出现异常" : "Codex 网络已恢复", body: snapshot.summary)
            }
            previousLight = snapshot.light; didInitialSample = true; onStatusChanged?()
        }
    }
    func togglePause() {
        isPaused.toggle()
        record([.init(light: .gray, cause: .info, source: "监测器", message: isPaused ? "用户暂停监测。" : "用户恢复监测。")])
        if isPaused { task?.cancel(); usageTask?.cancel() } else { refresh(force: true) }
        onStatusChanged?()
    }
    private func record(_ additions: [MonitorEvent]) {
        if let store { store.append(additions); events = store.events; storageError = store.writeError }
        else { events.append(contentsOf: additions) }
    }
    private func loadDemo(_ demo: DemoScenario) {
        let now = Date(); snapshot = demo.snapshot(now: now); usage = demo.usage(now: now)
        events = demo.events(now: now); onStatusChanged?()
    }
    func setNotifications(_ enabled: Bool) {
        guard demo == nil else { notice = "演示模式不申请通知权限。"; return }
        if !enabled { notificationsEnabled = false; UserDefaults.standard.set(false, forKey: "notificationsEnabled"); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsEnabled = granted
                UserDefaults.standard.set(granted, forKey: "notificationsEnabled")
                if !granted { self?.notice = "通知权限未开启，可在系统设置 → 通知中开启。" }
            }
        }
    }
    private func sendNotification(title: String, body: String) {
        guard notificationsEnabled, Date().timeIntervalSince(lastNotification) > 60 else { return }
        lastNotification = Date()
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func copySummary() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary, forType: .string); notice = "已复制当前原因总结。" }
    func openHistory() { if let store { NSWorkspace.shared.open(store.directory) } }
    func exportHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Codex网络记录.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let lines = selectedEvents.map { "\(formatter.string(from: $0.date)) [\($0.source)] \($0.cause.title)：\($0.message)" }
        let text = "Codex 网络监测\n\(summary)\n范围：\(range.rawValue)\n\(historySummary)\n\n" + lines.joined(separator: "\n") + "\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8); notice = "已导出所选时间范围的网络记录。" }
        catch { notice = "导出未成功，请检查目标位置是否可写。" }
    }
    func stop() { timer?.invalidate(); task?.cancel(); usageTask?.cancel(); path.cancel(); for observer in observations { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}

extension Light {
    var color: Color { switch self { case .green: return Color(red: 0.10, green: 0.65, blue: 0.40); case .red: return Color(red: 0.87, green: 0.23, blue: 0.29); case .gray: return .secondary } }
    var nativeColor: NSColor { switch self { case .green: return .systemGreen; case .red: return .systemRed; case .gray: return .systemGray } }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat = 830
    private var surface: Color { colorScheme == .dark ? Color(red: 0.15, green: 0.16, blue: 0.18) : Color(red: 0.95, green: 0.96, blue: 0.97) }
    private var canvas: Color { colorScheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.12) : Color(red: 0.99, green: 0.99, blue: 0.99) }
    private var statusSurface: Color {
        switch model.light {
        case .green: return colorScheme == .dark ? Color(red: 0.09, green: 0.21, blue: 0.16) : Color(red: 0.90, green: 0.97, blue: 0.93)
        case .red: return colorScheme == .dark ? Color(red: 0.25, green: 0.12, blue: 0.15) : Color(red: 0.99, green: 0.92, blue: 0.93)
        case .gray: return surface
        }
    }
    private func time(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MM-dd HH:mm:ss"; return f.string(from: date)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "network").font(.system(size: 20, weight: .semibold)).foregroundStyle(model.light.color)
                Text("Codex 网络监测").font(.system(size: 19, weight: .bold))
                Spacer()
                if model.isChecking { ProgressView().controlSize(.small).help("正在采样，检测不会重叠") }
                Text(model.demo == nil ? "LOCAL" : "DEMO").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            }
            if model.demo != nil {
                Text("演示数据 · 不访问真实账号、网络配置或日志").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(model.light.color).frame(width: 10, height: 10)
                    Text(model.statusTitle).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(model.snapshot?.codexRunning == true ? "客户端运行中" : "客户端未运行 / 检查中").font(.caption).foregroundStyle(.secondary)
                }
                Text(model.summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(statusSurface, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("账号用量").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if model.isUsageChecking { ProgressView().controlSize(.mini) }
                    Text(model.demo != nil ? "合成额度 · 仅供展示" : model.usage == nil ? "正在获取 / 暂不可用" : model.usageIsStale ? "未更新 · 上次数据" : "每分钟刷新 · 账号共享额度")
                        .font(.system(size: 10)).foregroundStyle(model.usageIsStale && model.usage != nil ? Color.orange : Color.secondary)
                }
                HStack(spacing: 22) {
                    usageWindow(model.usage?.fiveHour, title: "5 小时")
                    usageWindow(model.usage?.weekly, title: "每周")
                }
                if let error = model.usageError { Text(error).font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(11).background(surface, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                detailRow("代理", value: model.snapshot?.environment.proxyDescription ?? "正在读取…", symbol: "point.3.connected.trianglepath.dotted")
                detailRow("TUN", value: model.snapshot?.environment.tunnelDescription ?? "正在读取…", symbol: "arrow.triangle.branch")
                Divider()
                if let snapshot = model.snapshot {
                    probeRow(snapshot.primary, short: "服务 · 系统路径")
                    if let bypass = snapshot.bypass { probeRow(bypass, short: "服务 · 不经系统代理") }
                    if let control = snapshot.control { probeRow(control, short: "普通网站 · 系统路径") }
                    Text("不经系统代理的探测仍遵循 TUN 路由；HTTPS 可达不代表长连接已恢复。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else { Text("正在检测服务、代理端口与路由…").font(.caption).foregroundStyle(.secondary) }
            }.padding(12).background(surface, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                metric(value: "\(model.clientErrors)", title: "客户端异常记录", tint: model.clientErrors > 0 ? .red : .primary)
                Divider().frame(height: 26)
                metric(value: model.probeRate, title: "服务探测可达率", tint: .primary)
                Spacer()
                Picker("日志范围", selection: $model.range) { ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200).help("筛选日志时间范围")
            }
            HStack {
                Text("近期日志").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("只看异常", isOn: $model.errorsOnly).toggleStyle(.checkbox).font(.caption)
            }
            Text(model.historySummary).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.visibleEvents.isEmpty {
                        VStack(spacing: 8) { Image(systemName: "checklist").font(.title2); Text("这个时间范围还没有记录").font(.caption) }
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    ForEach(model.visibleEvents) { event in
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(event.light.color).frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(event.source).fontWeight(.medium); Spacer(); Text(time(event.date)).monospacedDigit().foregroundStyle(.secondary) }.font(.system(size: 10))
                                Text(event.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }.padding(.vertical, 8).padding(.horizontal, 10)
                        Divider().padding(.leading, 25)
                    }
                }
            }.frame(minHeight: 110, maxHeight: .infinity).background(surface, in: RoundedRectangle(cornerRadius: 8))
            if model.storageError { Text("日志保存失败；当前检测仍在进行，请检查磁盘和目录权限。").font(.caption).foregroundStyle(.red) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).onTapGesture { model.notice = nil } }
            HStack {
                Button("立即检测") { model.refresh(force: true) }.disabled(model.isPaused || model.isChecking).keyboardShortcut("r", modifiers: .command)
                Button(model.isPaused ? "恢复监测" : "暂停监测") { model.togglePause() }
                Spacer()
                Menu("更多") {
                    Button("打开独立监测窗口") { model.onOpenWindow?() }
                    Button("复制原因总结") { model.copySummary() }
                    Button("导出当前范围日志…") { model.exportHistory() }
                    if model.demo == nil { Button("打开本地记录目录") { model.openHistory() } }
                    Divider()
                    Toggle("断线 / 恢复通知", isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) }))
                    Divider()
                    Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                }.menuStyle(.borderlessButton).frame(width: 55)
            }.controlSize(.small)
            HStack {
                Text(model.demo == nil ? "每 15 秒检测 · 日志保留最多 7 天" : "离线演示 · 不保存历史记录").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(model.snapshot.map { "上次 " + time($0.date) } ?? "初始化中").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 570, height: height).background(canvas)
    }
    private func usageWindow(_ window: UsageWindow?, title: String) -> some View {
        let remaining = window?.remainingPercent
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        let reset = window?.resetsAt.map { $0 <= Date() ? "等待服务器刷新" : "重置 " + f.string(from: $0) } ?? "重置时间未知"
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(remaining.map { String(format: "剩余 %.0f%%", $0) } ?? "未知").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            if let remaining {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(remaining <= 10 ? Light.red.color : Light.green.color)
                            .frame(width: geometry.size.width * remaining / 100)
                    }
                }.frame(height: 5).accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title)剩余额度").accessibilityValue(String(format: "%.0f%%", remaining))
            }
            else { RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(height: 4) }
            HStack {
                Text(window?.usedPercent.map { String(format: "已用 %.0f%%", $0) } ?? "已用未知")
                Spacer()
                Text(reset)
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    private func detailRow(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).frame(width: 14).foregroundStyle(.secondary)
            Text(title).fontWeight(.medium).frame(width: 30, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
    private func probeRow(_ probe: ProbeResult, short: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: probe.reachable ? "checkmark.circle.fill" : probe.cause == .authentication ? "questionmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(probe.reachable ? Light.green.color : probe.cause == .authentication ? Color.secondary : Light.red.color)
            Text(short).frame(width: 137, alignment: .leading)
            Text(probe.detail).foregroundStyle(.secondary).lineLimit(1).help(probe.detail)
            Spacer(minLength: 0)
            if let ms = probe.milliseconds { Text("\(ms) ms").monospacedDigit().foregroundStyle(.secondary) }
            if Date().timeIntervalSince(probe.date) > 20 { Text("\(Int(Date().timeIntervalSince(probe.date))) 秒前").foregroundStyle(.secondary) }
        }.font(.system(size: 10))
    }
    private func metric(value: String, title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(tint); Text(title).font(.system(size: 10)).foregroundStyle(.secondary) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: MonitorModel
    var status: NSStatusItem!
    let popover = NSPopover()
    var previewWindow: NSWindow?
    var previewPath: String?
    var previewPoll: Timer?
    var showWindowOnLaunch: Bool
    var panelHeight: CGFloat { min(830, (NSScreen.main?.visibleFrame.height ?? 900) - 55) }
    init(dataDirectory: URL, previewPath: String?, showWindow: Bool, demo: DemoScenario?) { self.model = MonitorModel(dataDirectory: dataDirectory, demo: demo); self.previewPath = previewPath; self.showWindowOnLaunch = showWindow }
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.autosaveName = "CodexNetworkMonitor"
        if let button = status.button {
            button.title = model.menuTitle; button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); button.imagePosition = .imageLeft; button.target = self; button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient; popover.animates = false; popover.contentSize = NSSize(width: 570, height: panelHeight)
        popover.contentViewController = NSHostingController(rootView: MonitorView(model: model, height: panelHeight))
        model.onStatusChanged = { [weak self] in self?.updateStatus() }
        model.onOpenWindow = { [weak self] in self?.presentWindow() }
        updateStatus(); model.start()
        if previewPath != nil || showWindowOnLaunch { presentWindow() }
        if previewPath != nil {
            var attempts = 0
            previewPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self else { timer.invalidate(); return }; attempts += 1
                    if self.model.snapshot != nil && !self.model.isUsageChecking || attempts >= 30 {
                        timer.invalidate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.savePreview() }
                    }
                }
            }
        }
    }
    func presentWindow() {
        if previewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: panelHeight), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Codex 网络监测"
            window.contentView = NSHostingView(rootView: MonitorView(model: model, height: panelHeight)); window.center(); previewWindow = window
        }
        previewWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    func updateStatus() {
        guard let button = status?.button else { return }
        let color = model.light.nativeColor
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            color.withAlphaComponent(0.2).setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            color.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill(); return true
        }
        image.isTemplate = false; button.image = image; button.title = model.menuTitle
        button.toolTip = model.summary + "\n" + model.menuTitle + (model.usageIsStale ? "\n* 表示上次数据，用量暂未更新。" : "")
        button.setAccessibilityLabel("Codex 网络监测，\(model.statusTitle)，\(model.menuTitle)")
    }
    @objc func togglePopover() {
        guard let button = status.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for (title, action) in [("显示网络日志", #selector(showPopover)), ("立即检测", #selector(refreshNow)), (model.isPaused ? "恢复监测" : "暂停监测", #selector(pause)), ("退出", #selector(quit))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            status.menu = menu; button.performClick(nil); status.menu = nil; return
        }
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    @objc func showPopover() {
        guard let button = status.button else { return }; NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    @objc func refreshNow() { model.refresh(force: true) }
    @objc func pause() { model.togglePause() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func savePreview() {
        guard let view = previewWindow?.contentView, let path = previewPath,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("Screenshot rendering failed."); model.stop(); exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), let clean = PNGPrivacy.sanitized(png) else {
            print("Screenshot PNG could not be sanitized."); model.stop(); exit(1)
        }
        do { try clean.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { print("Screenshot could not be saved."); model.stop(); exit(1) }
        NSApp.terminate(nil)
    }
}

@main struct Entry {
    @MainActor static func main() {
        let args = CommandLine.arguments
        func argument(_ flag: String) -> String? { guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
        let demo = argument("--demo").flatMap(DemoScenario.init(rawValue:))
        if args.contains("--demo") && demo == nil { print("Usage: --demo healthy|proxy"); exit(2) }
        if demo != nil && (args.contains("--diagnose") || args.contains("--usage-diagnose")) {
            print("Demo mode cannot be combined with live diagnostics."); exit(2)
        }
        let data = argument("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Network Monitor", isDirectory: true)
        if args.contains("--diagnose") {
            let pid = MonitorModel.codexPID()
            Task {
                let sampler = NetworkSampler(logRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex"))
                let result = await sampler.sample(.init(pid: pid, pathAvailable: nil), forceDiagnostics: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                if let json = try? encoder.encode(result.snapshot) { FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data([10])) }
                exit(0)
            }
            RunLoop.current.run(); return
        }
        if args.contains("--usage-diagnose") {
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            Task {
                let service = UsageService(executable: CodexCLI.locate(application: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")), runtimeDirectory: data.appendingPathComponent("codex-runtime"))
                let result = await service.read()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                switch result {
                case .success(let value): if let json = try? encoder.encode(value) { FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data([10])) }; exit(0)
                case .failure(let failure): print(failure.message); exit(1)
                }
            }
            RunLoop.current.run(); return
        }
        let application = NSApplication.shared; application.setActivationPolicy(.accessory)
        if demo == nil, argument("--render-preview") == nil, let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: []); return
        }
        let delegate = AppDelegate(dataDirectory: data, previewPath: argument("--render-preview"), showWindow: args.contains("--show-window"), demo: demo); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
