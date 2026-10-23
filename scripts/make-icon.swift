import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func render(_ size: Int) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Icon context failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    NSAffineTransform().apply { $0.scale(by: scale) }.concat()
    NSColor(calibratedRed: 0.34, green: 0.27, blue: 0.78, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210).fill()
    NSColor.white.setStroke()
    let tv = NSBezierPath(roundedRect: NSRect(x: 190, y: 320, width: 644, height: 440), xRadius: 55, yRadius: 55)
    tv.lineWidth = 36; tv.stroke()
    let stand = NSBezierPath(); stand.lineWidth = 36; stand.lineCapStyle = .round
    stand.move(to: NSPoint(x: 512, y: 320)); stand.line(to: NSPoint(x: 512, y: 245))
    stand.move(to: NSPoint(x: 380, y: 245)); stand.line(to: NSPoint(x: 644, y: 245)); stand.stroke()
    let speaker = NSBezierPath()
    speaker.move(to: NSPoint(x: 347, y: 495)); speaker.line(to: NSPoint(x: 405, y: 495))
    speaker.line(to: NSPoint(x: 490, y: 425)); speaker.line(to: NSPoint(x: 490, y: 655))
    speaker.line(to: NSPoint(x: 405, y: 585)); speaker.line(to: NSPoint(x: 347, y: 585)); speaker.close()
    NSColor.white.setFill(); speaker.fill()
    for x in [CGFloat(540), 610] {
        let wave = NSBezierPath(); wave.lineWidth = 30; wave.lineCapStyle = .round
        wave.move(to: NSPoint(x: x, y: 480))
        wave.curve(to: NSPoint(x: x, y: 600), controlPoint1: NSPoint(x: x + 65, y: 510), controlPoint2: NSPoint(x: x + 65, y: 570))
        wave.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("Icon render failed") }
    try png.write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
}
extension NSAffineTransform {
    func apply(_ action: (NSAffineTransform) -> Void) -> NSAffineTransform { action(self); return self }
}
for size in [16, 32, 128, 256, 512, 1024] { try render(size) }
