import Foundation
import AppKit
import CoreGraphics
import OSLog

/// Handler for overlay-related functions (arrows, highlights)
@MainActor
final class OverlayFunctionHandler {
    private let logger = Logger(subsystem: "ASAApp", category: "OverlayFunctionHandler")
    private let overlayController = OverlayWindowController()
    private var arrowCommands: [OverlayCommand] = []
    
    func drawArrow(from: CGPoint, to: CGPoint) async -> [String: Any] {
        logger.info("Drawing arrow from (\(from.x), \(from.y)) to (\(to.x), \(to.y))")
        
        let command = OverlayCommand(
            type: .arrow(start: from, end: to),
            caption: nil
        )
        
        arrowCommands.append(command)
        overlayController.render(commands: arrowCommands)
        
        return [
            "success": true,
            "message": "Arrow drawn successfully"
        ]
    }
    
    func clearArrows() async -> [String: Any] {
        logger.info("Clearing all arrows")
        
        arrowCommands.removeAll()
        overlayController.render(commands: [])
        
        return [
            "success": true,
            "message": "All arrows cleared"
        ]
    }
}

