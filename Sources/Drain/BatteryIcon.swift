import AppKit

/// Draws the menu bar battery the way macOS does with the percentage shown inside
/// the battery: a solid pill whose level is the fill, with the number (and a bolt
/// on power) cut out of it. Yellow in Low Power Mode, red when low on battery.
enum BatteryIcon {
    static func image(percent: Int, pluggedIn: Bool, lowPower: Bool) -> NSImage {
        let tint: NSColor? =
            lowPower ? .systemYellow
            : (!pluggedIn && percent <= 20) ? .systemRed
            : nil

        let label = makeLabel(percent: percent, bolt: pluggedIn)
        let size = NSSize(width: 28, height: 13)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            let body = NSRect(x: 0.5, y: 0.5, width: 24.5, height: 12)
            let shape = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)
            let ink = tint == nil ? NSColor.black : NSColor.labelColor

            // Terminal nub.
            ink.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: 25.8, y: 4.5, width: 1.7, height: 4), xRadius: 0.85, yRadius: 0.85).fill()

            // Empty part of the battery, then the charge level.
            ctx.saveGraphicsState()
            shape.addClip()
            ink.withAlphaComponent(0.35).setFill()
            body.fill()
            (tint ?? ink).setFill()
            let level = max(0, min(1, CGFloat(percent) / 100))
            NSRect(x: body.minX, y: body.minY, width: body.width * level, height: body.height).fill()
            ctx.restoreGraphicsState()

            // Cut the number and the bolt out of the fill, centered on the ink itself.
            ctx.saveGraphicsState()
            label.image.draw(
                at: NSPoint(x: body.midX - label.ink.midX, y: body.midY - label.ink.midY),
                from: .zero, operation: .destinationOut, fraction: 1)
            ctx.restoreGraphicsState()
            return true
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = "Battery \(percent)%"
        return image
    }

    /// The number (and bolt) drawn on a small canvas, plus the box its visible
    /// pixels occupy. Font and symbol metrics include side bearings and padding,
    /// so centering by those boxes pushes "100⚡" off to one side.
    private static func makeLabel(percent: Int, bolt: Bool) -> (image: NSImage, ink: NSRect) {
        let crowded = percent >= 100 && bolt
        let font = NSFont.systemFont(ofSize: crowded ? 8.75 : 10.5, weight: .bold,
                                     width: crowded ? .condensed : .standard)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let text = "\(percent)" as NSString
        let textSize = text.size(withAttributes: attrs)
        let boltImage = bolt
            ? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: crowded ? 7 : 8.5, weight: .black))
            : nil

        let canvas = NSSize(width: 44, height: 18)
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (NSImage(size: canvas), NSRect(origin: .zero, size: canvas)) }
        rep.size = canvas

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        text.draw(at: NSPoint(x: 2, y: (canvas.height - textSize.height) / 2), withAttributes: attrs)
        if let boltImage {
            let b = boltImage.size
            boltImage.draw(in: NSRect(x: 2 + textSize.width + 0.5, y: (canvas.height - b.height) / 2,
                                      width: b.width, height: b.height))
        }
        NSGraphicsContext.restoreGraphicsState()

        // Find the visible pixels' bounding box.
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        let w = rep.pixelsWide, h = rep.pixelsHigh
        if let data = rep.bitmapData {
            for y in 0..<h {
                for x in 0..<w where data[y * rep.bytesPerRow + x * 4 + 3] > 40 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        let image = NSImage(size: canvas)
        image.addRepresentation(rep)
        guard maxX >= 0 else { return (image, NSRect(origin: .zero, size: canvas)) }
        // Bitmap rows run top-down; drawing coordinates run bottom-up.
        let ink = NSRect(x: CGFloat(minX) / scale, y: canvas.height - CGFloat(maxY + 1) / scale,
                         width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return (image, ink)
    }
}
