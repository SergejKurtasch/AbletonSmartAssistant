import Foundation
import OSLog

/// Router for handling assistant functions in both HTTP API and Realtime API modes
@MainActor
final class AssistantFunctionRouter {
    private let logger = Logger(subsystem: "ASAApp", category: "AssistantFunctionRouter")
    
    private let screenshotHandler = ScreenshotFunctionHandler()
    private let overlayHandler = OverlayFunctionHandler()
    private let clickHandler = ClickFunctionHandler()
    
    /// Execute a function call and return result
    func executeFunction(name: String, arguments: [String: Any]) async -> [String: Any] {
        logger.info("Executing function: \(name) with arguments: \(arguments)")
        
        switch name {
        case "make_screenshot":
            return await screenshotHandler.makeScreenshot()
            
        case "make_screenshot_of_window":
            if let windowName = arguments["windowName"] as? String {
                return await screenshotHandler.makeScreenshotOfWindow(windowName: windowName)
            } else {
                return errorResult("Missing required parameter: windowName")
            }
            
        case "make_screenshot_around_point":
            if let x = arguments["x"] as? Double,
               let y = arguments["y"] as? Double,
               let width = arguments["width"] as? Double,
               let height = arguments["height"] as? Double {
                return await screenshotHandler.makeScreenshotAroundPoint(
                    x: x, y: y, width: width, height: height
                )
            } else {
                return errorResult("Missing required parameters: x, y, width, height")
            }
            
        case "detect_button_click":
            if let x = arguments["x"] as? Double,
               let y = arguments["y"] as? Double {
                return await clickHandler.detectButtonClick(x: x, y: y)
            } else {
                return errorResult("Missing required parameters: x, y")
            }
            
        case "draw_arrow":
            if let x1 = arguments["x1"] as? Double,
               let y1 = arguments["y1"] as? Double,
               let x2 = arguments["x2"] as? Double,
               let y2 = arguments["y2"] as? Double {
                return await overlayHandler.drawArrow(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2))
            } else {
                return errorResult("Missing required parameters: x1, y1, x2, y2")
            }
            
        case "clear_arrows":
            return await overlayHandler.clearArrows()
            
        default:
            logger.warning("Unknown function: \(name)")
            return errorResult("Unknown function: \(name)")
        }
    }
    
    /// Parse JSON string arguments (from Realtime API)
    func parseArguments(_ jsonString: String) -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Failed to parse function arguments: \(jsonString)")
            return [:]
        }
        return json
    }
    
    private func errorResult(_ message: String) -> [String: Any] {
        logger.error("\(message)")
        return [
            "success": false,
            "error": message
        ]
    }
}

