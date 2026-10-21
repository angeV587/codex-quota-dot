import Foundation
import Darwin

final class CodexQuotaClient: @unchecked Sendable {
    private let lock = NSLock()
    private var session: RPCSession?
    private let executableOverride: URL?
    private let timeout: TimeInterval

    // This is the total budget for process startup, account access, and quota lookup.
    init(executable: URL? = nil, timeout: TimeInterval = 40) {
        executableOverride = executable
        self.timeout = timeout
    }

    func fetch() throws -> QuotaSnapshot {
        let executable = try executableOverride ?? Self.resolveExecutable()
        let rpc = RPCSession(executable: executable, timeout: timeout)
        lock.lock(); session = rpc; lock.unlock()
        defer {
            rpc.close()
            lock.lock(); session = nil; lock.unlock()
        }
        try rpc.start()
        _ = try rpc.request(id: 1, method: "initialize", params: ["clientInfo": ["name": "codex_quota_bar", "title": "Codex Quota Bar", "version": "1.0.0"]])
        try rpc.notify(method: "initialized")
        let account = try rpc.request(id: 2, method: "account/read", params: ["refreshToken": false])
        let limits = try rpc.request(id: 3, method: "account/rateLimits/read")
        do { return try QuotaParser.parse(accountData: account, limitsData: limits, clientPath: executable.path) }
        catch let error as QuotaError { throw error }
        catch { throw QuotaError.invalidResponse }
    }

    func cancel() {
        lock.lock(); let active = session; lock.unlock()
        active?.close()
    }

    static func resolveExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Prefer the CLI bundled with the desktop app to track its protocol version.
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/.local/bin/codex", "\(home)/.codex/packages/standalone/current/bin/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw QuotaError.clientMissing }
        return URL(fileURLWithPath: path)
    }
}

// A short-lived, read-only JSON-RPC session. No threads, turns, tools, or inference.
private final class RPCSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var closed = false
    private var failure: QuotaError?
    private let deadline: Date

    init(executable: URL, timeout: TimeInterval) {
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        // Never persist raw server output or authentication diagnostics.
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
    }

    func start() throws {
        condition.lock()
        guard !closed else { condition.unlock(); throw QuotaError.disconnected }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData) }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.condition.lock(); self.failure = .disconnected; self.condition.broadcast(); self.condition.unlock()
        }
        do { try process.run(); condition.unlock() }
        catch { condition.unlock(); throw QuotaError.clientMissing }
    }

    func request(id: Int, method: String, params: [String: Any]? = nil) throws -> Data {
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try write(message)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil && failure == nil && !closed {
            if !condition.wait(until: deadline) { throw QuotaError.timeout }
        }
        if let reply = responses.removeValue(forKey: id) {
            guard reply["error"] == nil else { throw QuotaError.requestFailed }
            guard let result = reply["result"] as? [String: Any] else { throw QuotaError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: result)
        }
        throw failure ?? QuotaError.disconnected
    }

    func notify(method: String) throws { try write(["method": method]) }

    private func write(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0a)
        condition.lock()
        defer { condition.unlock() }
        guard !closed, process.isRunning else { throw QuotaError.disconnected }
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw QuotaError.disconnected }
    }

    private func received(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        guard !data.isEmpty else { failure = .disconnected; condition.broadcast(); return }
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { failure = .invalidResponse; condition.broadcast(); return }
        while let end = buffer.firstIndex(of: 0x0a) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, (1...3).contains(id) { responses[id] = object }
        }
        condition.broadcast()
    }

    func close() {
        condition.lock()
        if closed { condition.unlock(); return }
        closed = true
        condition.broadcast()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        let running = process.isRunning
        if running { process.terminate() }
        condition.unlock()
        if running {
            let end = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }
}
