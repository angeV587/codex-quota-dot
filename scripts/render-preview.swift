import AppKit

@main struct RenderPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = CommandLine.arguments.dropFirst().first ?? "docs/preview.png"
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 480,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 720, height: 240)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 720, height: 240).fill()
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            ("Codex Quota Dot" as NSString).draw(at: NSPoint(x: 32, y: 190), withAttributes: [
                .font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let cases: [(String, Double, Bool)] = [
                ("Countdown on", 72, true), ("Countdown off", 72, false),
                ("Low allowance", 35, true), ("Warning", 12, true),
            ]
            let reset = Date().addingTimeInterval(6 * 86400 + 13 * 3600).timeIntervalSince1970
            for (index, sample) in cases.enumerated() {
                let x: CGFloat = index.isMultiple(of: 2) ? 32 : 380
                let y: CGFloat = index < 2 ? 115 : 35
                let image = StatusGraphic.image(remaining: sample.1, resetAt: reset, stale: false,
                                               height: 22, showResetCountdown: sample.2)
                image.draw(at: NSPoint(x: x, y: y + 22), from: .zero, operation: .sourceOver, fraction: 1)
                (sample.0 as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1),
                ])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        print(output)
    }
}
