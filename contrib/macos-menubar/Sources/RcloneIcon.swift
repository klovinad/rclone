import AppKit

@MainActor
enum RcloneIcon {
    static var image: NSImage { image(for: .idle) }
    private static var images: [TransferIndicator: NSImage] = [:]

    static func image(for indicator: TransferIndicator) -> NSImage {
        if let cached = images[indicator] { return cached }
        let result = makeImage(indicator)
        images[indicator] = result
        return result
    }

    private static func makeImage(_ indicator: TransferIndicator) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let cloud = NSBezierPath()
            cloud.move(to: NSPoint(x: 5.2, y: 3))
            cloud.curve(to: NSPoint(x: 1.4, y: 6.8), controlPoint1: NSPoint(x: 3.1, y: 3), controlPoint2: NSPoint(x: 1.4, y: 4.6))
            cloud.curve(to: NSPoint(x: 4.7, y: 10.4), controlPoint1: NSPoint(x: 1.4, y: 8.7), controlPoint2: NSPoint(x: 2.9, y: 10.2))
            cloud.curve(to: NSPoint(x: 11, y: 15), controlPoint1: NSPoint(x: 5.5, y: 13.3), controlPoint2: NSPoint(x: 7.8, y: 15))
            cloud.curve(to: NSPoint(x: 17.4, y: 10.6), controlPoint1: NSPoint(x: 14, y: 15), controlPoint2: NSPoint(x: 16.5, y: 13.1))
            cloud.curve(to: NSPoint(x: 20.8, y: 6.9), controlPoint1: NSPoint(x: 19.3, y: 10.5), controlPoint2: NSPoint(x: 20.8, y: 8.9))
            cloud.curve(to: NSPoint(x: 17.1, y: 3), controlPoint1: NSPoint(x: 20.8, y: 4.6), controlPoint2: NSPoint(x: 19.2, y: 3))
            cloud.close()
            cloud.lineWidth = 1.3
            cloud.lineJoinStyle = .round
            cloud.stroke()
            let marks = NSBezierPath()
            marks.lineWidth = 1.4
            marks.lineCapStyle = .round
            marks.lineJoinStyle = .round
            func line(_ points: [(CGFloat, CGFloat)]) {
                guard let first = points.first else { return }
                marks.move(to: NSPoint(x: first.0, y: first.1))
                for point in points.dropFirst() { marks.line(to: NSPoint(x: point.0, y: point.1)) }
            }
            func arrow(_ x: CGFloat, up: Bool) {
                let tip: CGFloat = up ? 11 : 5
                let tail: CGFloat = up ? 5 : 11
                let wing: CGFloat = up ? 8.8 : 7.2
                line([(x, tail), (x, tip)])
                line([(x - 2, wing), (x, tip), (x + 2, wing)])
            }
            switch indicator {
            case .upload: arrow(11, up: true)
            case .download: arrow(11, up: false)
            case .both: arrow(8, up: true); arrow(14, up: false)
            case .copy:
                line([(7, 8), (15, 8)])
                line([(9, 10), (7, 8), (9, 6)])
                line([(13, 10), (15, 8), (13, 6)])
            case .checking:
                marks.appendOval(in: NSRect(x: 8, y: 7, width: 5, height: 5))
                line([(12.3, 7.7), (14.5, 5.5)])
            case .working:
                for x in [7.5, 11.0, 14.5] {
                    marks.appendOval(in: NSRect(x: x - 0.5, y: 7, width: 1, height: 1))
                }
            case .warning:
                line([(11, 11), (11, 8)])
                marks.appendOval(in: NSRect(x: 10.5, y: 5, width: 1, height: 1))
            case .idle:
                let letter = NSAttributedString(string: "R", attributes: [
                    .font: NSFont.systemFont(ofSize: 8.5, weight: .bold), .foregroundColor: NSColor.black,
                ])
                letter.draw(at: NSPoint(x: (22 - letter.size().width) / 2, y: 3.2))
            }
            marks.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
