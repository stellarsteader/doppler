// Sizes up to 32 px use a cut with fewer, wider rings so the mark stays readable.
import AppKit

let logoDir = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

func squircle(_ rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = NSPoint(x: rect.midX + rect.width / 2 * copysign(pow(abs(c), 2 / n), c),
                            y: rect.midY + rect.height / 2 * copysign(pow(abs(s), 2 / n), s))
        i == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

func draw(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let k = CGFloat(size) / 1024

    // macOS icon grid: 824 pt tile centred on a 1024 canvas.
    let tileRect = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let tile = squircle(tileRect)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 22 * k
    shadow.shadowOffset = NSSize(width: 0, height: -9 * k)
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let file = "\(logoDir)/\(size <= 32 ? "doppler-icon-small.svg" : "doppler-logo.svg")"
    guard let logo = NSImage(contentsOfFile: file) else { fatalError("Cannot load \(file)") }
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    logo.draw(in: tileRect)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: base * scale).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
if CommandLine.arguments.count > 3 {
    try! draw(size: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
}
