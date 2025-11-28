import Foundation
import AppKit
import CoreGraphics
import OSLog

/// Handler for screenshot-related functions
@MainActor
final class ScreenshotFunctionHandler {
    private let logger = Logger(subsystem: "ASAApp", category: "ScreenshotFunctionHandler")
    private let screenshotService = AbletonScreenshotService.shared
    
    func makeScreenshot() async -> [String: Any] {
        logger.info("Making screenshot of Ableton window")
        
        do {
            let url = try await screenshotService.captureAbletonWindow()
            return [
                "success": true,
                "screenshot_url": url.path,
                "message": "Screenshot captured successfully"
            ]
        } catch {
            return [
                "success": false,
                "error": error.localizedDescription
            ]
        }
    }
    
    func makeScreenshotOfWindow(windowName: String) async -> [String: Any] {
        logger.info("Making screenshot of window: \(windowName)")
        
        // For now, we only support Ableton window
        // Could be extended to support other windows
        if windowName.lowercased().contains("ableton") {
            return await makeScreenshot()
        } else {
            return [
                "success": false,
                "error": "Window '\(windowName)' not found or not supported"
            ]
        }
    }
    
    func makeScreenshotAroundPoint(x: Double, y: Double, width: Double, height: Double) async -> [String: Any] {
        logger.info("Making screenshot around point: (\(x), \(y)), size: \(width)x\(height)")
        
        let point = CGPoint(x: x, y: y)
        let size = CGFloat(width)
        
        do {
            let url = try await screenshotService.captureRegionAround(point: point, size: size)
            return [
                "success": true,
                "screenshot_url": url.path,
                "message": "Screenshot captured successfully"
            ]
        } catch {
            return [
                "success": false,
                "error": error.localizedDescription
            ]
        }
    }
}

