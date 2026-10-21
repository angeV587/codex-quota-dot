import Foundation

enum QuotaError: LocalizedError {
    case clientMissing, timeout, disconnected, invalidResponse, notSignedIn, unsupportedAccount, quotaMissing, expired, requestFailed

    var errorDescription: String? {
        switch self {
        case .clientMissing: return "未找到官方 Codex 客户端"
        case .timeout: return "查询超时，稍后重试"
        case .disconnected: return "官方客户端连接已断开"
        case .invalidResponse: return "额度数据格式异常"
        case .notSignedIn: return "请先在 Codex 中登录"
        case .unsupportedAccount: return "当前登录方式不提供 Codex 订阅额度"
        case .quotaMissing: return "当前账户未返回 Codex 额度"
        case .expired: return "额度窗口已过期，等待重新查询"
        case .requestFailed: return "额度查询失败，稍后重试"
        }
    }
}

struct QuotaWindow: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var label: String {
        guard let minutes = windowDurationMins else { return "当前窗口" }
        if minutes == 10080 { return "周额度" }
        if minutes.isMultiple(of: 1440) { return "\(minutes / 1440) 天额度" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
    func isValid(at now: Date) -> Bool {
        usedPercent.isFinite && (0...100).contains(usedPercent)
            && (windowDurationMins == nil || windowDurationMins! > 0)
            && (resetsAt == nil || resetsAt! > now.timeIntervalSince1970)
    }
}

struct QuotaSnapshot: Codable {
    let windows: [QuotaWindow]
    let fetchedAt: Date
    let accountLabel: String
    let planType: String?
    let clientPath: String

    // The most depleted active window is the practical constraint on availability.
    var selected: QuotaWindow? { windows.min(by: { $0.remaining < $1.remaining }) }
    func isFresh(at now: Date) -> Bool {
        now >= fetchedAt && now.timeIntervalSince(fetchedAt) <= 15 * 60
            && !windows.isEmpty && windows.allSatisfy { $0.isValid(at: now) }
    }
}

enum QuotaParser {
    static func parse(accountData: Data, limitsData: Data, clientPath: String, now: Date = Date()) throws -> QuotaSnapshot {
        struct Account: Decodable { let type: String; let email: String?; let planType: String? }
        struct AccountResult: Decodable { let account: Account? }
        struct Bucket: Decodable {
            let limitId: String?
            let primary: QuotaWindow?
            let secondary: QuotaWindow?
            let planType: String?
        }
        struct Limits: Decodable { let rateLimits: Bucket?; let rateLimitsByLimitId: [String: Bucket]? }
        let decoder = JSONDecoder()
        let accountResult = try decoder.decode(AccountResult.self, from: accountData)
        guard let account = accountResult.account else { throw QuotaError.notSignedIn }
        guard account.type == "chatgpt" else { throw QuotaError.unsupportedAccount }
        let limits = try decoder.decode(Limits.self, from: limitsData)
        let bucket: Bucket
        if let buckets = limits.rateLimitsByLimitId, !buckets.isEmpty {
            guard let codex = buckets["codex"], codex.limitId == nil || codex.limitId == "codex" else { throw QuotaError.quotaMissing }
            bucket = codex
        } else if let legacy = limits.rateLimits, legacy.limitId == nil || legacy.limitId == "codex" {
            bucket = legacy
        } else { throw QuotaError.quotaMissing }
        let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
        guard !windows.isEmpty else { throw QuotaError.quotaMissing }
        guard windows.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && ($0.windowDurationMins == nil || $0.windowDurationMins! > 0) }) else { throw QuotaError.invalidResponse }
        guard windows.allSatisfy({ $0.isValid(at: now) }) else { throw QuotaError.expired }
        return QuotaSnapshot(windows: windows, fetchedAt: now, accountLabel: maskedEmail(account.email), planType: bucket.planType ?? account.planType, clientPath: clientPath)
    }

    private static func maskedEmail(_ email: String?) -> String {
        guard let email, let at = email.firstIndex(of: "@") else { return "本机 Codex 登录账户" }
        return String(email.prefix(1)) + "***" + String(email[at...])
    }
}
