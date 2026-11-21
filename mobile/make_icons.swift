import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icons = [
    "idle": "brain.head.profile",
    "working": "brain.head.profile.fill",
    "resting": "moon.fill",
    "paused": "moon.zzz.fill",
    "offline": "exclamationmark.triangle.fill",
    "check": "checkmark.circle.fill",
    "clock": "clock",
    "running": "play.circle.fill",
    "wave": "waveform",
    "warning": "exclamationmark.triangle.fill",
    "wait": "ellipsis.circle",
    "speed": "speedometer",
    "timer": "timer",
    "stack": "square.stack.3d.up",
]

func draw(_ name: String, in rect: NSRect, tint: NSColor? = nil) {
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        .applying(.preferringMonochrome())
    guard let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                       ?? NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil))?
        .withSymbolConfiguration(configuration), image.size.height > 0, image.size.width > 0 else { return }
    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let symbol = tint.map { color in
        NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            color.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
    } ?? image
    symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                          width: size.width, height: size.height))
}

func writeIcon(_ name: String, pixels: Int, drawing: (NSRect) -> Void) throws {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill(using: .copy)
    drawing(rect)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: destination.appendingPathComponent(name + ".png"))
}

try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for (name, symbol) in icons {
    try writeIcon(name, pixels: 72) { draw(symbol, in: $0.insetBy(dx: 3, dy: 3)) }
}
try writeIcon("app", pixels: 180) { rect in
    let blue = NSColor(srgbRed: 0.04, green: 0.56, blue: 0.98, alpha: 1)
    let deepBlue = NSColor(srgbRed: 0.10, green: 0.35, blue: 0.62, alpha: 1)
    NSGradient(starting: blue, ending: deepBlue)?.draw(in: rect, angle: -45)
    draw(icons["working"]!, in: rect.insetBy(dx: 40, dy: 40), tint: .white)
}
