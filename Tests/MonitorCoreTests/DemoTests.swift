import Foundation
import Testing
@testable import MonitorCore

@Suite struct DemoTests {
    let now = Date(timeIntervalSince1970: 1_790_876_800)

    @Test func healthyAndFailureScenesExerciseRealDiagnosis() {
        #expect(DemoScenario.healthy.snapshot(now: now).light == .green)
        let failure = DemoScenario.proxy.snapshot(now: now)
        #expect(failure.light == .red)
        #expect(failure.summary.contains("端口不可达"))
        #expect(failure.environment.proxies.first?.host == "127.0.0.1")
    }

    @Test func syntheticUsageIsIndependentOfMachineAndAccount() throws {
        let usage = DemoScenario.healthy.usage(now: now)
        #expect(usage.fiveHour?.remainingPercent == 72)
        #expect(usage.weekly?.remainingPercent == 46)
        #expect(usage.fiveHour?.resetsAt == now.addingTimeInterval(7200))
        let encoded = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        #expect(!encoded.contains("account"))
        #expect(!encoded.contains("token"))
    }

    @Test func scenesAreExplicitlyMarkedAsSynthetic() {
        for scene in DemoScenario.allCases {
            let events = scene.events(now: now)
            #expect(events.contains { $0.source == "演示模式" && $0.message.contains("合成数据") })
            #expect(events.allSatisfy { $0.date <= now })
            #expect(scene.snapshot(now: now).environment.tunnelRoutes == ["utun0"])
        }
    }
}
