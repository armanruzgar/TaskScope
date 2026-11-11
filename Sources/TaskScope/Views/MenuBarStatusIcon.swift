import AppKit

/// The menu-bar item's images: the waveform glyph with a corner mark per
/// state, each a template image drawn on one fixed 18 × 18 pt canvas.
/// MenuBarExtra sizes its status item from the image it renders, so a
/// constant canvas keeps the item's width the same in every state (an
/// optional badge overlay once made it change).
@MainActor
enum MenuBarStatusIcon {
    static let canvasSize = NSSize(width: 18, height: 18)
    /// One image per state, so an unchanged state hands SwiftUI the same image.
    private static var cache: [MenuBarStatus: NSImage] = [:]

    static func image(for status: MenuBarStatus) -> NSImage {
        if let image = cache[status] { return image }
        let badge = status.badge
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            draw(badge, in: rect)
        }
        image.isTemplate = true
        image.accessibilityDescription = status.accessibilityLabel
        cache[status] = image
        return image
    }

    private nonisolated static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    /// Draws in black; as a template image only the alpha channel counts.
    private nonisolated static func draw(_ badge: MenuBarStatus.Badge, in rect: NSRect) -> Bool {
        guard let glyph = symbol("waveform.path.ecg", pointSize: 13, weight: .regular) else { return false }
        let size = glyph.size
        glyph.draw(in: NSRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
            width: size.width, height: size.height
        ))
        guard badge != .none else { return true }
        // The top-right corner is clear of the waveform's spikes. A cleared
        // ring separates the mark from the glyph.
        let mark = NSRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 8, height: 8)
        guard let context = NSGraphicsContext.current else { return false }
        context.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: mark.insetBy(dx: -1.25, dy: -1.25)).fill()
        context.compositingOperation = .sourceOver
        NSColor.black.setFill()
        let name: String
        switch badge {
        case .none:
            return true
        case .dot:
            NSBezierPath(ovalIn: mark.insetBy(dx: 1, dy: 1)).fill()
            return true
        case .warning: name = "exclamationmark.triangle.fill"
        case .question: name = "questionmark.circle.fill"
        case .bell: name = "bell.fill"
        }
        guard let symbol = symbol(name, pointSize: 8, weight: .bold) else { return false }
        let natural = symbol.size
        let scale = min(mark.width / natural.width, mark.height / natural.height, 1)
        let drawn = NSSize(width: natural.width * scale, height: natural.height * scale)
        symbol.draw(in: NSRect(
            x: mark.midX - drawn.width / 2, y: mark.midY - drawn.height / 2,
            width: drawn.width, height: drawn.height
        ))
        return true
    }
}
