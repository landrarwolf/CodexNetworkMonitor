import Foundation
import Testing
@testable import MonitorCore

struct UsageTests {
    @Test func remainingUsesUsedPercent() throws {
        let value = try UsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1791000000},"secondary":{"usedPercent":60,"windowDurationMins":10080}}}"#.utf8))
        #expect(value.fiveHour?.remainingPercent == 75)
        #expect(value.weekly?.remainingPercent == 40)
        #expect(value.fiveHour?.resetsAt != nil)
    }
    @Test func preferredCoreBucketOverridesLegacy() throws {
        let value = try UsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300}},"other":{"primary":{"usedPercent":50,"windowDurationMins":300}}}}"#.utf8))
        #expect(value.fiveHour?.remainingPercent == 80)
    }
    @Test func nullAndMissingUsageStayUnknown() throws {
        let value = try UsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":300},"secondary":null}}"#.utf8))
        #expect(value.fiveHour?.usedPercent == nil)
        #expect(value.fiveHour?.remainingPercent == nil)
        #expect(value.weekly == nil)
    }
    @Test func windowDurationDefinesWindowNotPrimarySlot() throws {
        let value = try UsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":60,"windowDurationMins":10080},"secondary":{"usedPercent":25,"windowDurationMins":300}}}"#.utf8))
        #expect(value.fiveHour?.remainingPercent == 75)
        #expect(value.weekly?.remainingPercent == 40)
    }
    @Test func percentagesAreBounded() throws {
        let value = try UsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":120,"windowDurationMins":300},"secondary":{"usedPercent":-2,"windowDurationMins":10080}}}"#.utf8))
        #expect(value.fiveHour?.remainingPercent == 0)
        #expect(value.weekly?.remainingPercent == 100)
    }
    @Test func differentModelBucketDoesNotBecomeCodexCoreQuota() {
        #expect(throws: UsageFailure.self) {
            try UsageParser.parse(Data(#"{"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":20,"windowDurationMins":300}}}}"#.utf8))
        }
    }
    @Test func zeroResetDoesNotBecome1970() throws {
        let value = try UsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":0}}}"#.utf8))
        #expect(value.fiveHour?.resetsAt == nil)
    }
    @Test func unsupportedWindowsAreUnknown() {
        #expect(throws: UsageFailure.self) {
            try UsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":15}}}"#.utf8))
        }
    }
    @Test func accountIdentifiersAndCreditsAreNotInNormalizedResult() throws {
        let value = try UsageParser.parse(Data(#"{"accountId":"private-account-marker","credits":{"balance":"secret-balance"},"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}"#.utf8))
        let output = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(!output.contains("private-account-marker")); #expect(!output.contains("secret-balance"))
    }
}
