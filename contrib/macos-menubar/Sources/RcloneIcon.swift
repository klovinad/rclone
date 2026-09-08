import AppKit

@MainActor
enum RcloneIcon {
    static let image: NSImage = {
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
            let letter = NSAttributedString(string: "R", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .bold), .foregroundColor: NSColor.black,
            ])
            letter.draw(at: NSPoint(x: (22 - letter.size().width) / 2, y: 3.2))
            return true
        }
        image.isTemplate = true
        return image
    }()
}
