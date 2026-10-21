import AppKit

/// Dot-style status ring, remaining percentage, and time until the selected reset.
@MainActor
enum StatusGraphic {
    nonisolated static func band(for remaining: Double) -> String {
        if remaining > 50 { return "blue" }
        if remaining >= 20 { return "yellow" }
        return "pink"
    }

    nonisolated static func resetCountdownLabel(_ resetAt: TimeInterval?, now: Date = Date()) -> String {
        guard let resetAt, resetAt.isFinite else { return "--" }
        let remaining = resetAt - now.timeIntervalSince1970
        guard remaining.isFinite, remaining > 0, remaining < Double(Int.max) else { return "--" }
        let seconds = Int(remaining)
        if seconds >= 86_400 {
            return "\(seconds / 86_400)d\(seconds % 86_400 > 0 ? "+" : "")"
        }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        return "<1h"
    }

    static func image(remaining: Double?, resetAt: TimeInterval? = nil, stale: Bool, height: CGFloat, showResetCountdown: Bool = true) -> NSImage {
        let canvasHeight = max(18, height.isFinite ? height : 22)
        let diameter = min(16, canvasHeight - 4)
        let value = remaining.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let foreground = NSColor(calibratedWhite: dark ? 0.95 : 0.13, alpha: 1)
        let ringColor: NSColor
        if value == nil {
            ringColor = foreground.withAlphaComponent(0.4)
        } else {
            // Sampled from the user's sRGB reference, not approximated system colors.
            switch band(for: value!) {
            case "blue": ringColor = NSColor(srgbRed: 0, green: 178 / 255.0, blue: 1, alpha: 1)
            case "yellow": ringColor = NSColor(srgbRed: 255 / 255.0, green: 204 / 255.0, blue: 57 / 255.0, alpha: 1)
            default: ringColor = NSColor(srgbRed: 250 / 255.0, green: 112 / 255.0, blue: 172 / 255.0, alpha: 1)
            }
        }
        let percentLabel = value.map { "\(Int($0.rounded(.down)))%" } ?? "--%"
        // Color always expresses the quota band. A separate mark identifies cached data.
        let displayedPercent = percentLabel + (stale && value != nil ? "*" : "")
        let resetLabel = resetCountdownLabel(resetAt)
        let percent = NSAttributedString(string: displayedPercent, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: foreground,
        ])
        let date = NSAttributedString(string: resetLabel, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: foreground.withAlphaComponent(0.85),
        ])
        let ringRect = NSRect(x: 1, y: (canvasHeight - diameter) / 2,
                              width: diameter, height: diameter)
        let percentX = ringRect.maxX + 5
        let dateX = percentX + percent.size().width + 7
        let contentEnd = showResetCountdown ? dateX + date.size().width : percentX + percent.size().width
        let size = NSSize(width: ceil(contentEnd + 1), height: canvasHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            let ring = NSBezierPath(ovalIn: ringRect)
            // Exact reference proportion: 128px outside / 52px inside, solid full ring.
            let inset = diameter * (1 - 52.0 / 128.0) / 2
            ring.appendOval(in: ringRect.insetBy(dx: inset, dy: inset))
            ring.windingRule = .evenOdd
            ringColor.setFill()
            ring.fill()
            percent.draw(at: NSPoint(x: percentX, y: (canvasHeight - percent.size().height) / 2 + 0.15))
            if showResetCountdown {
                date.draw(at: NSPoint(x: dateX, y: (canvasHeight - date.size().height) / 2 + 0.15))
            }
            return true
        }
        image.isTemplate = false
        let resetDescription = showResetCountdown ? "，距重置 \(resetLabel)" : ""
        image.accessibilityDescription = "Codex 剩余额度 \(percentLabel)\(resetDescription)\(stale ? "，上次记录，数据待更新" : "")"
        return image
    }
}
