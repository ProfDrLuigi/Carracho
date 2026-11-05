import Cocoa

@main
struct CardAppearanceRegression {
    static func rgb(_ color: CGColor) -> NSColor {
        NSColor(cgColor: color)!.usingColorSpace(.deviceRGB)!
    }

    // Exercise Catalina's fallback directly, even on newer macOS test hosts.
    @available(macOS, introduced: 10.14, deprecated: 11.0)
    static func checkLegacyResolution() {
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        let original = NSAppearance.current
        defer { NSAppearance.current = original }
        NSAppearance.current = light
        let lightBackground = rgb(CarrachoTheme.elevatedCard.cgColor)
        precondition(lightBackground.redComponent > 0.9)
        CarrachoTheme.withLegacyDrawingAppearance(dark) {
            let darkBackground = rgb(CarrachoTheme.elevatedCard.cgColor)
            precondition(darkBackground.redComponent < 0.25,
                         "Dark cards must not resolve to white in a Light application")
            let darkText = rgb(NSColor.labelColor.cgColor)
            precondition(darkText.redComponent > 0.7, "Dark card labels must remain readable")
            CarrachoTheme.withLegacyDrawingAppearance(light) {
                let nestedBackground = rgb(CarrachoTheme.elevatedCard.cgColor)
                precondition(nestedBackground.redComponent > 0.9)
            }
            precondition(rgb(CarrachoTheme.elevatedCard.cgColor).redComponent < 0.25,
                         "Nested color resolution must restore the enclosing appearance")
        }
        precondition(NSAppearance.current === light, "Color resolution must restore the caller's appearance")
        NSAppearance.current = dark
        CarrachoTheme.withLegacyDrawingAppearance(light) {
            precondition(rgb(CarrachoTheme.elevatedCard.cgColor).redComponent > 0.9,
                         "Light cards must work inside a Dark application too")
        }
        precondition(NSAppearance.current === dark)
    }

    static func main() {
        let app = NSApplication.shared
        checkLegacyResolution()
        app.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let card = CarrachoCardView(frame: NSRect(x: 10, y: 10, width: 300, height: 160))
        card.fillColor = CarrachoTheme.elevatedCard
        window.contentView!.addSubview(card)
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(rgb(card.layer!.backgroundColor!).redComponent < 0.25,
                     "Cards must adopt the window appearance when attached")
        card.appearance = NSAppearance(named: .aqua)
        precondition(rgb(card.layer!.backgroundColor!).redComponent > 0.9,
                     "Cards must update after an appearance change")
        card.appearance = nil
        precondition(rgb(card.layer!.backgroundColor!).redComponent < 0.25,
                     "Clearing a local appearance must restore inherited colors")
        print("PASS: Catalina color resolution, readable contrast, nested scope restoration and card appearance changes")
    }
}
