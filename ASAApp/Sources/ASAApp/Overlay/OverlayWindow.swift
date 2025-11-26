import AppKit
import SwiftUI

final class OverlayWindowController: NSWindowController {
    private let overlayView = OverlayHostingView()

    init() {
        let window = NSWindow(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = overlayView

        super.init(window: window)
        window.orderFrontRegardless()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(commands: [OverlayCommand]) {
        overlayView.commands = commands
    }
}

struct OverlayCommand: Identifiable {
    enum CommandType {
        case arrow(start: CGPoint, end: CGPoint)
        case highlight(rect: CGRect)
        case pulse(center: CGPoint, radius: CGFloat)
    }

    let id = UUID()
    let type: CommandType
    let caption: String?
}

final class OverlayHostingView: NSView {
    var commands: [OverlayCommand] = [] {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        for command in commands {
            switch command.type {
            case let .arrow(start, end):
                drawArrow(context: context, start: start, end: end, caption: command.caption)
            case let .highlight(rect):
                drawHighlight(context: context, rect: rect, caption: command.caption)
            case let .pulse(center, radius):
                drawPulse(context: context, center: center, radius: radius, caption: command.caption)
            }
        }
    }

    private func drawArrow(context: CGContext, start: CGPoint, end: CGPoint, caption: String?) {
        context.setLineWidth(4)
        NSColor.systemOrange.setStroke()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        if let caption {
            drawCaption(caption, at: end)
        }
    }

    private func drawHighlight(context: CGContext, rect: CGRect, caption: String?) {
        NSColor.systemYellow.withAlphaComponent(0.25).setFill()
        NSColor.systemYellow.setStroke()
        context.setLineWidth(3)
        context.addRect(rect)
        context.drawPath(using: .fillStroke)
        if let caption {
            drawCaption(caption, at: rect.origin)
        }
    }

    private func drawPulse(context: CGContext, center: CGPoint, radius: CGFloat, caption: String?) {
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        NSColor.systemRed.withAlphaComponent(0.15).setFill()
        NSColor.systemRed.setStroke()
        context.setLineWidth(2)
        context.addEllipse(in: circle)
        context.drawPath(using: .fillStroke)
        if let caption {
            drawCaption(caption, at: CGPoint(x: circle.midX, y: circle.minY - 8))
        }
    }

    private func drawCaption(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        var rect = attributedString.boundingRect(with: CGSize(width: 200, height: 80), options: .usesLineFragmentOrigin)
        rect.origin = point
        attributedString.draw(in: rect)
    }
}

