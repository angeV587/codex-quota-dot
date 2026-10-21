import Foundation
import Darwin

// This binary also supplies the isolated fake server. It never resolves a real client.
private func runFakeServer() throws -> Never {
    let environment = ProcessInfo.processInfo.environment
    guard let mode = environment["CODEX_QUOTA_TEST_MODE"],
          let pidPath = environment["CODEX_QUOTA_TEST_PID"] else { exit(64) }
    try String(getpid()).write(toFile: pidPath, atomically: true, encoding: .utf8)
    if mode == "exit" { exit(0) }
    if mode == "hang" {
        // Exercise the client's forced cleanup, rather than voluntarily exiting on TERM.
        signal(SIGTERM, SIG_IGN)
        while true { usleep(100_000) }
    }
    guard mode == "null" else { exit(64) }
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? Int else { continue }
        let result: Any
        switch id {
        case 1: result = [String: Any]()
        case 2: result = ["account": ["type": "chatgpt", "planType": "plus"]]
        default: result = NSNull()
        }
        var response = try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
        response.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: response)
    }
    exit(0)
}

if CommandLine.arguments.contains("app-server") {
    do { try runFakeServer() }
    catch { exit(74) }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(description: message) }
}

private func expectThrows<T>(
    _ operation: () throws -> T,
    matching predicate: (Error) -> Bool = { _ in true },
    _ message: String
) throws {
    var caught: Error?
    do { _ = try operation() } catch { caught = error }
    guard let caught else { throw CheckFailure(description: message + ": unexpectedly succeeded") }
    try expect(predicate(caught), message + ": unexpected error \(caught)")
}

private final class QuotaChecks {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(used: Double, duration: Int = 10_080, reset: TimeInterval? = nil) -> [String: Any] {
        [
            "usedPercent": used,
            "windowDurationMins": duration,
            "resetsAt": reset ?? now.timeIntervalSince1970 + 3_600
        ]
    }

    private func parse(_ limits: [String: Any], accountType: String = "chatgpt") throws -> QuotaSnapshot {
        let account: [String: Any] = [
            "account": ["type": accountType, "email": "a@example.com", "planType": "plus"]
        ]
        return try QuotaParser.parse(
            accountData: JSONSerialization.data(withJSONObject: account),
            limitsData: JSONSerialization.data(withJSONObject: limits),
            clientPath: "/test/Codex.app/Contents/MacOS/codex",
            now: now
        )
    }

    func remainingPercent() throws {
        let snapshot = try parse(["rateLimits": ["primary": window(used: 9)]])
        try expect(snapshot.selected?.remaining == 91, "9% used must mean 91% remaining")
        try expect(snapshot.fetchedAt == now, "fetchedAt must use the query timestamp")
    }

    func colorThresholds() throws {
        let cases: [(Double, String)] = [
            (100, "blue"), (87, "blue"), (50.1, "blue"),
            (50, "yellow"), (49.9, "yellow"), (20, "yellow"),
            (19.9, "pink"), (0, "pink")
        ]
        for (remaining, expected) in cases {
            try expect(StatusGraphic.band(for: remaining) == expected, "remaining \(remaining) must be \(expected)")
        }
    }

    func resetCountdownUsesConfirmedBoundaries() throws {
        let cases: [(TimeInterval, String)] = [
            (5 * 86_400, "5d"),
            (5 * 86_400 + 13 * 3_600, "5d+"),
            (3 * 86_400 + 23 * 3_600, "3d+"),
            (8 * 3_600, "8h"),
            (23 * 3_600, "23h"),
            (8 * 3_600 + 40 * 60, "8h"),
            (59 * 60, "<1h"),
            (24 * 3_600, "1d"),
            (3_600, "1h"),
            (86_400 + 1, "1d+"),
            (1, "<1h")
        ]
        for (remaining, expected) in cases {
            try expect(
                StatusGraphic.resetCountdownLabel(now.timeIntervalSince1970 + remaining, now: now) == expected,
                "reset in \(remaining) seconds must display \(expected)"
            )
        }
        for reset in [nil, now.timeIntervalSince1970, now.timeIntervalSince1970 - 1, Double.nan, Double.infinity, -Double.infinity] as [TimeInterval?] {
            try expect(StatusGraphic.resetCountdownLabel(reset, now: now) == "--", "missing, non-finite, or expired reset must remain unknown")
        }
    }

    func modernCodexBucket() throws {
        let snapshot = try parse([
            "rateLimits": ["primary": window(used: 99)],
            "rateLimitsByLimitId": [
                "codex": ["limitId": "codex", "primary": window(used: 9)],
                "other": ["limitId": "other", "primary": window(used: 98)]
            ]
        ])
        try expect(snapshot.windows.count == 1, "other buckets and legacy windows must not be mixed into Codex")
        try expect(snapshot.selected?.remaining == 91, "modern Codex bucket must override legacy")
    }

    func secondaryWindow() throws {
        let snapshot = try parse(["rateLimitsByLimitId": ["codex": [
            "primary": window(used: 5, duration: 300),
            "secondary": window(used: 65)
        ]]])
        try expect(snapshot.windows.count == 2, "both Codex windows must be preserved")
        try expect(snapshot.selected?.remaining == 35, "more depleted secondary must constrain availability")
        try expect(snapshot.selected?.windowDurationMins == 10_080, "selected window must be secondary")
    }

    func missingNullAndUnknownBuckets() throws {
        let validBucket: [String: Any] = ["primary": window(used: 9)]
        let inputs: [[String: Any]] = [
            [:],
            ["rateLimits": NSNull()],
            ["rateLimits": ["primary": NSNull(), "secondary": NSNull()]],
            ["rateLimits": ["primary": ["usedPercent": NSNull()]]],
            ["rateLimits": ["limitId": "other", "primary": window(used: 9)]],
            ["rateLimitsByLimitId": ["other": validBucket]],
            ["rateLimitsByLimitId": ["other": validBucket], "rateLimits": validBucket],
            ["rateLimitsByLimitId": ["codex": ["limitId": "other", "primary": window(used: 9)]]]
        ]
        for (index, input) in inputs.enumerated() {
            try expectThrows({ try parse(input) }, "invalid fixture \(index) must fail instead of returning 100%")
        }
    }

    func invalidPercentAndDuration() throws {
        for invalid in [window(used: -1), window(used: 101), window(used: 9, duration: 0)] {
            try expectThrows({ try parse(["rateLimits": ["primary": invalid]]) }, matching: {
                if case .invalidResponse? = $0 as? QuotaError { return true }
                return false
            }, "invalid percent or window duration must be rejected")
        }
    }

    func expiredReset() throws {
        for reset in [now.timeIntervalSince1970 - 1, now.timeIntervalSince1970] {
            try expectThrows({ try parse(["rateLimits": ["primary": window(used: 9, reset: reset)]]) }, matching: {
                if case .expired? = $0 as? QuotaError { return true }
                return false
            }, "already reset window must be expired")
        }
    }

    func freshnessLimitAndClockReversal() throws {
        let snapshot = try parse(["rateLimits": ["primary": window(used: 9)]])
        try expect(snapshot.isFresh(at: now), "new snapshot must be fresh")
        try expect(snapshot.isFresh(at: now.addingTimeInterval(900)), "15-minute boundary must be fresh")
        try expect(!snapshot.isFresh(at: now.addingTimeInterval(900.001)), "snapshot older than 15 minutes must be stale")
        try expect(!snapshot.isFresh(at: now.addingTimeInterval(-1)), "clock reversal must not make a future snapshot fresh")
    }

    func resetEndsFreshness() throws {
        let reset = now.timeIntervalSince1970 + 600
        let snapshot = try parse(["rateLimits": ["primary": window(used: 9, reset: reset)]])
        try expect(snapshot.isFresh(at: now.addingTimeInterval(599)), "snapshot before reset must be fresh")
        try expect(!snapshot.isFresh(at: now.addingTimeInterval(600)), "reset must end freshness before the 15-minute limit")
    }

    func nonChatGPTAccount() throws {
        try expectThrows({ try parse(["rateLimits": ["primary": window(used: 9)]], accountType: "apiKey") }, matching: {
            if case .unsupportedAccount? = $0 as? QuotaError { return true }
            return false
        }, "API key account must not supply ChatGPT subscription allowance")
    }

    private func rpcFailure(mode: String, matching predicate: (QuotaError) -> Bool) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let pidFile = root.appendingPathComponent(".build/quota-test-\(UUID().uuidString).pid")
        let oldMode = ProcessInfo.processInfo.environment["CODEX_QUOTA_TEST_MODE"]
        let oldPIDPath = ProcessInfo.processInfo.environment["CODEX_QUOTA_TEST_PID"]
        setenv("CODEX_QUOTA_TEST_MODE", mode, 1)
        setenv("CODEX_QUOTA_TEST_PID", pidFile.path, 1)
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text), kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: pidFile)
            if let oldMode { setenv("CODEX_QUOTA_TEST_MODE", oldMode, 1) }
            else { unsetenv("CODEX_QUOTA_TEST_MODE") }
            if let oldPIDPath { setenv("CODEX_QUOTA_TEST_PID", oldPIDPath, 1) }
            else { unsetenv("CODEX_QUOTA_TEST_PID") }
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let client = CodexQuotaClient(executable: executable, timeout: 0.2)
        let started = ProcessInfo.processInfo.systemUptime
        try expectThrows({ try client.fetch() }, matching: {
            guard let error = $0 as? QuotaError else { return false }
            return predicate(error)
        }, "RPC \(mode) must throw the expected error")
        try expect(ProcessInfo.processInfo.systemUptime - started < 2, "RPC \(mode) must finish promptly")
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        guard let pid = Int32(pidText) else { throw CheckFailure(description: "fake server did not record a PID") }
        let alive = kill(pid, 0)
        let processError = errno
        try expect(alive == -1 && processError == ESRCH, "RPC \(mode) left fake server PID \(pid) running")
    }

    func hangingRPCIsTimedOutAndReaped() throws {
        try rpcFailure(mode: "hang") {
            if case .timeout = $0 { return true }
            return false
        }
    }

    func nullRPCResultIsRejectedWithoutCrashing() throws {
        try rpcFailure(mode: "null") {
            if case .invalidResponse = $0 { return true }
            return false
        }
    }

    func immediatelyExitingRPCDoesNotHang() throws {
        try rpcFailure(mode: "exit") {
            if case .disconnected = $0 { return true }
            return false
        }
    }
}

private let checks = QuotaChecks()
let cases: [(String, () throws -> Void)] = [
    ("used-to-remaining conversion", checks.remainingPercent),
    ("remaining color boundaries", checks.colorThresholds),
    ("reset countdown confirmed boundaries", checks.resetCountdownUsesConfirmedBoundaries),
    ("Codex bucket priority and isolation", checks.modernCodexBucket),
    ("secondary window constraint", checks.secondaryWindow),
    ("missing/null/unknown rejection", checks.missingNullAndUnknownBuckets),
    ("invalid percent/duration rejection", checks.invalidPercentAndDuration),
    ("expired reset rejection", checks.expiredReset),
    ("15-minute freshness and clock reversal", checks.freshnessLimitAndClockReversal),
    ("reset ends freshness", checks.resetEndsFreshness),
    ("non-ChatGPT account rejection", checks.nonChatGPTAccount),
    ("hung RPC times out and reaps its child", checks.hangingRPCIsTimedOutAndReaped),
    ("null RPC result throws without crashing", checks.nullRPCResultIsRejectedWithoutCrashing),
    ("immediate RPC exit does not hang", checks.immediatelyExitingRPCDoesNotHang)
]

var failures = 0
for (name, check) in cases {
    do {
        try check()
        print("PASS: \(name)")
    } catch {
        failures += 1
        fputs("FAIL: \(name): \(error)\n", stderr)
    }
}
print("\(cases.count - failures)/\(cases.count) checks passed")
exit(failures == 0 ? 0 : 1)
