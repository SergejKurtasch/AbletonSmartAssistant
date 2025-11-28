import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import CoreImage
import ScreenCaptureKit
import OSLog

/// Service for capturing screenshots of Ableton Live window using ScreenCaptureKit
@MainActor
final class AbletonScreenshotService {
    static let shared = AbletonScreenshotService()
    private let logger = Logger(subsystem: "ASAApp", category: "AbletonScreenshotService")
    private let cacheDir: URL
    
    private init() {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = cacheURL.appendingPathComponent("ASAApp/Screenshots")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
    
    /// Captures screenshot of Ableton Live window using ScreenCaptureKit
    /// Returns URL of saved file or error
    func captureAbletonWindow() async throws -> URL {
        logger.info("Starting Ableton window screenshot capture using ScreenCaptureKit...")
        
        // Check ScreenCaptureKit availability
        #if os(macOS)
        if #available(macOS 12.3, *) {
            logger.info("ScreenCaptureKit available (macOS 12.3+)")
        } else {
            let error = NSError(
                domain: "AbletonScreenshotService",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "ScreenCaptureKit requires macOS 12.3 or newer"]
            )
            throw error
        }
        #endif
        
        // Step 1: Find Ableton window using old API to get windowID
        guard let windowInfo = findAbletonWindow() else {
            let error = NSError(
                domain: "AbletonScreenshotService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ableton Live window not found. Make sure the application is running and visible on screen."]
            )
            logger.error("Ableton window not found")
            throw error
        }
        
        let windowID = windowInfo.windowID
        logger.info("Found Ableton window: ID=\(windowID)")
        
        // Step 2: Get available content through ScreenCaptureKit
        // Try several methods to get content
        let availableContent: SCShareableContent
        do {
            // First try to get content with desktop windows included
            availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            logger.info("Successfully accessed ScreenCaptureKit, found windows: \(availableContent.windows.count)")
        } catch {
            // If first method didn't work, try alternative
            logger.warning("First content retrieval method failed, trying alternative...")
            do {
                availableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                logger.info("Alternative method worked, found windows: \(availableContent.windows.count)")
            } catch {
                // Handle TCC (Transparency, Consent, and Control) errors
                let errorDescription: String
                if let nsError = error as NSError? {
                    logger.error("ScreenCaptureKit error: domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription)")
                    logger.error("Full error information: \(nsError)")
                    
                    // Check for specific TCC errors
                    let errorString = nsError.localizedDescription.lowercased()
                    if nsError.domain.contains("TCC") || 
                       errorString.contains("declined") || 
                       errorString.contains("permission") ||
                       errorString.contains("denied") {
                        errorDescription = """
                        Insufficient permissions for screen capture.
                        
                        Please follow these steps:
                        1. Open Settings → Privacy & Security → Screen Recording
                        2. Make sure ASAApp is enabled in the list of allowed applications
                        3. If ASAApp is not in the list, add it using the "+" button
                        4. IMPORTANT: Fully close and restart the ASAApp application after granting permissions
                        5. If the problem persists, try:
                           - Remove ASAApp from the permissions list
                           - Add it again
                           - Restart the application
                        
                        Technical error: \(nsError.localizedDescription)
                        Domain: \(nsError.domain), Code: \(nsError.code)
                        """
                    } else {
                        errorDescription = "Error accessing ScreenCaptureKit: \(nsError.localizedDescription). Check screen recording permissions in Settings → Privacy & Security → Screen Recording."
                    }
                } else {
                    errorDescription = "Error accessing ScreenCaptureKit: \(error.localizedDescription). Check screen recording permissions in Settings → Privacy & Security → Screen Recording."
                }
                
                let userError = NSError(
                    domain: "AbletonScreenshotService",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: errorDescription,
                        NSUnderlyingErrorKey: error
                    ]
                )
                logger.error("Failed to access ScreenCaptureKit: \(errorDescription)")
                throw userError
            }
        }
        
        // Step 3: Find Ableton window in list of available windows
        guard let abletonWindow = availableContent.windows.first(where: { window in
            window.windowID == windowID
        }) ?? availableContent.windows.first(where: { window in
            let windowTitle = window.title ?? ""
            let ownerName = window.owningApplication?.applicationName ?? ""
            return windowTitle.contains("Ableton Live") ||
                   windowTitle.contains("Live") ||
                   ownerName.contains("Live") ||
                   ownerName.contains("Ableton")
        }) else {
            let error = NSError(
                domain: "AbletonScreenshotService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Ableton window not found in available windows for capture. Check screen recording permissions in Settings → Privacy & Security → Screen Recording."]
            )
            logger.error("Ableton window not found in SCShareableContent")
            throw error
        }
        
        logger.info("Found window in ScreenCaptureKit: ID=\(abletonWindow.windowID), frame=(\(abletonWindow.frame.width)x\(abletonWindow.frame.height))")
        
        // Step 4: Capture window using ScreenCaptureKit
        let capturedImage = try await captureWindowWithSCK(window: abletonWindow)
        
        // Step 5: Save image
        let url = saveImage(capturedImage, prefix: "ableton_\(Int(Date().timeIntervalSince1970))")
        logger.info("Screenshot saved: \(url.path)")
        
        return url
    }
    
    /// Captures window using ScreenCaptureKit
    private func captureWindowWithSCK(window: SCWindow) async throws -> NSImage {
        // Use frame to get window size
        let windowFrame = window.frame
        let windowWidth = Int(windowFrame.width)
        let windowHeight = Int(windowFrame.height)
        
        logger.info("Capturing window: frame=(\(windowFrame.width)x\(windowFrame.height))")
        
        // Create content filter for specific window
        // desktopIndependentWindow captures only window content, without desktop background
        let filter = SCContentFilter(desktopIndependentWindow: window)
        
        // Capture settings
        let configuration = SCStreamConfiguration()
        configuration.width = windowWidth
        configuration.height = windowHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        
        // Create stream for capture
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        
        // Create output to receive frames
        let streamOutput = ScreenshotStreamOutput()
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screenshot.queue"))
        
        // Start stream
        try await stream.startCapture()
        
        // Give some time for first frame
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        // Wait for frame
        guard let image = await streamOutput.waitForFrame(timeout: 5.0) else {
            try await stream.stopCapture()
            throw NSError(
                domain: "AbletonScreenshotService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to get frame from capture stream"]
            )
        }
        
        // Stop stream
        try await stream.stopCapture()
        
        logger.info("Window successfully captured, image size: \(image.size.width)x\(image.size.height)")
        return image
    }
    
    /// Finds Ableton Live window in system (using old API to get windowID)
    private func findAbletonWindow() -> (windowID: CGWindowID, bounds: CGRect)? {
        // Get list of all windows on screen
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            logger.error("Failed to get window list")
            return nil
        }
        
        // Search for Ableton window
        for windowInfo in windowList {
            let windowName = windowInfo[kCGWindowName as String] as? String ?? ""
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
            
            // Check if this is an Ableton window
            let isAbleton = ownerName.contains("Live") || 
                           ownerName.contains("Ableton") ||
                           windowName.contains("Ableton Live") ||
                           windowName.contains("Live")
            
            guard isAbleton else { continue }
            
            // Check that window is not minimized
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            guard layer >= 0 else { continue }
            
            // Get window size and position
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat,
                  width > 200 && height > 200 else { // Filter small windows
                continue
            }
            
            // Get window ID
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            
            // Create bounds in Quartz coordinates
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            
            logger.info("Found Ableton window: ID=\(windowID), size=\(width)x\(height), process=\(ownerName), bounds=(\(x), \(y))")
            return (windowID: windowID, bounds: bounds)
        }
        
        logger.warning("Ableton window not found in window list")
        return nil
    }
    
    /// Saves image to file
    private func saveImage(_ image: NSImage, prefix: String) -> URL {
        let filename = "\(prefix).png"
        let url = cacheDir.appendingPathComponent(filename)
        
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            logger.error("Failed to convert image to PNG")
            return url
        }
        
        do {
            try pngData.write(to: url)
            logger.info("Image successfully saved: \(url.path)")
        } catch {
            logger.error("Error saving image: \(error.localizedDescription)")
        }
        
        return url
    }
    
    /// Captures region around click point
    /// If click was on Ableton window, captures region around point in that window
    /// Otherwise captures screen region
    func captureRegionAround(point: CGPoint, size: CGFloat = 300) async throws -> URL {
        logger.info("Capturing region around point (\(point.x), \(point.y)), size: \(size)x\(size)")
        
        // First check if there's an Ableton window at this point
        if let windowInfo = findAbletonWindowAt(point: point) {
            logger.info("Found Ableton window at click point: ID=\(windowInfo.windowID)")
            
            // Get available content through ScreenCaptureKit
            let availableContent: SCShareableContent
            do {
                availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                // If failed to get through ScreenCaptureKit, try alternative method
                logger.warning("Failed to get content through ScreenCaptureKit, trying alternative method")
                do {
                    availableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                } catch {
                    throw error
                }
            }
            
            // Find Ableton window in list of available windows
            guard let abletonWindow = availableContent.windows.first(where: { $0.windowID == windowInfo.windowID }) else {
                logger.warning("Ableton window not found in SCShareableContent, using full window capture")
                return try await captureAbletonWindow()
            }
            
            // Capture region around click point in Ableton window
            return try await captureRegionInWindow(window: abletonWindow, point: point, size: size, windowBounds: windowInfo.bounds)
        }
        
        // If no Ableton window, capture screen region using ScreenCaptureKit
        let rect = CGRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size
        )
        
        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let display = availableContent.displays.first else {
            throw NSError(
                domain: "AbletonScreenshotService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Display not found"]
            )
        }
        
        // Create filter for display with cropping to needed region
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        let configuration = SCStreamConfiguration()
        configuration.width = Int(rect.width)
        configuration.height = Int(rect.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.sourceRect = rect // Crop to needed region
        
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let streamOutput = ScreenshotStreamOutput()
        
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screenshot.queue"))
        try await stream.startCapture()
        
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        guard let image = await streamOutput.waitForFrame(timeout: 5.0) else {
            try await stream.stopCapture()
            throw NSError(
                domain: "AbletonScreenshotService",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to capture screen region"]
            )
        }
        
        try await stream.stopCapture()
        
        let url = saveImage(image, prefix: "region_\(Int(point.x))_\(Int(point.y))_\(Int(Date().timeIntervalSince1970))")
        
        return url
    }
    
    /// Captures region around point in Ableton window
    private func captureRegionInWindow(window: SCWindow, point: CGPoint, size: CGFloat, windowBounds: CGRect) async throws -> URL {
        logger.info("Capturing region in Ableton window around point (\(point.x), \(point.y))")
        
        // Calculate capture region relative to window
        // Click point is in screen coordinates, need to convert to window coordinates
        guard let screen = NSScreen.main else {
            throw NSError(domain: "AbletonScreenshotService", code: 6, userInfo: [NSLocalizedDescriptionKey: "Screen not found"])
        }
        
        let screenHeight = screen.frame.height
        // Convert point from screen coordinates (top-left) to Quartz coordinates (bottom-left)
        let quartzY = screenHeight - point.y
        
        // Calculate relative coordinates of point in window
        let windowRelativeX = point.x - windowBounds.origin.x
        let windowRelativeY = quartzY - windowBounds.origin.y
        
        // Calculate capture region in window coordinates
        let regionX = max(0, windowRelativeX - size / 2)
        let regionY = max(0, windowRelativeY - size / 2)
        let regionWidth = min(size, windowBounds.width - regionX)
        let regionHeight = min(size, windowBounds.height - regionY)
        
        logger.info("Capture region in window: x=\(regionX), y=\(regionY), width=\(regionWidth), height=\(regionHeight)")
        
        // Create filter for window
        let filter = SCContentFilter(desktopIndependentWindow: window)
        
        let configuration = SCStreamConfiguration()
        configuration.width = Int(regionWidth)
        configuration.height = Int(regionHeight)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        
        // Set sourceRect to crop to needed region
        // sourceRect in window coordinates
        configuration.sourceRect = CGRect(x: regionX, y: regionY, width: regionWidth, height: regionHeight)
        
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let streamOutput = ScreenshotStreamOutput()
        
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screenshot.queue"))
        try await stream.startCapture()
        
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        guard let image = await streamOutput.waitForFrame(timeout: 5.0) else {
            try await stream.stopCapture()
            throw NSError(
                domain: "AbletonScreenshotService",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Failed to capture region in window"]
            )
        }
        
        try await stream.stopCapture()
        
        let url = saveImage(image, prefix: "click_\(Int(point.x))_\(Int(point.y))_\(Int(Date().timeIntervalSince1970))")
        logger.info("Region successfully captured: \(url.path)")
        
        return url
    }
    
    /// Finds Ableton window at specified point
    private func findAbletonWindowAt(point: CGPoint) -> (windowID: CGWindowID, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        guard let screen = NSScreen.main else { return nil }
        let screenHeight = screen.frame.height
        
        // Convert point from screen coordinates (top-left) to Quartz coordinates (bottom-left)
        let quartzY = screenHeight - point.y
        
        for windowInfo in windowList {
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = windowInfo[kCGWindowName as String] as? String ?? ""
            
            // Check if this is an Ableton window
            let isAbleton = ownerName.contains("Live") || 
                           ownerName.contains("Ableton") ||
                           windowName.contains("Ableton Live") ||
                           windowName.contains("Live")
            
            guard isAbleton else { continue }
            
            // Get window bounds
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat,
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            
            // Check if point is within window bounds (in Quartz coordinates)
            if x <= point.x && point.x < x + width &&
               y <= quartzY && quartzY < y + height {
                let bounds = CGRect(x: x, y: y, width: width, height: height)
                logger.info("Click point is in Ableton window: ID=\(windowID), bounds=(\(x), \(y), \(width), \(height))")
                return (windowID: windowID, bounds: bounds)
            }
        }
        
        return nil
    }
    
    /// Imports screenshot from file
    func importScreenshot(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            completion(url)
        }
    }
}

/// Helper class for receiving frames from SCStream
private final class ScreenshotStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ScreenshotStreamOutput.queue")
    private var capturedImage: NSImage?
    private var continuation: CheckedContinuation<NSImage?, Never>?
    
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        
        // Get image from sample buffer
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }
        
        let image = NSImage(cgImage: cgImage, size: ciImage.extent.size)
        
        // Save image and resume continuation
        queue.sync {
            self.capturedImage = image
            self.continuation?.resume(returning: image)
            self.continuation = nil
        }
    }
    
    /// Waits for frame with timeout
    func waitForFrame(timeout: TimeInterval) async -> NSImage? {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                queue.sync {
                    // If image already received, return it immediately
                    if let image = self.capturedImage {
                        continuation.resume(returning: image)
                        return
                    }
                    
                    // Otherwise save continuation for later call
                    self.continuation = continuation
                    
                    // Set timeout
                    queue.asyncAfter(deadline: .now() + timeout) {
                        self.queue.sync {
                            if let cont = self.continuation {
                                cont.resume(returning: nil)
                                self.continuation = nil
                            }
                        }
                    }
                }
            }
        } onCancel: {
            queue.sync {
                if let continuation = self.continuation {
                    continuation.resume(returning: nil)
                    self.continuation = nil
                }
            }
        }
    }
}
