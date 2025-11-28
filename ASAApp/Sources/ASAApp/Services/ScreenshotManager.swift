import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import CoreImage
import ScreenCaptureKit
import OSLog

/// Manager for capturing screenshots using ScreenCaptureKit (macOS 12.3+)
final class ScreenshotManager {
    static let shared = ScreenshotManager()
    private let cacheDir: URL
    private let logger = Logger(subsystem: "ASAApp", category: "ScreenshotManager")
    
    @MainActor
    private var windowDetector: AbletonWindowDetector {
        AbletonWindowDetector.shared
    }

    private init() {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = cacheURL.appendingPathComponent("ASAApp/Screenshots")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Captures full Ableton Live window using ScreenCaptureKit
    func captureFullAbletonWindow(completion: @escaping (Result<URL, Error>) -> Void) {
        Task { @MainActor in
            logger.info("Starting screenshot capture using ScreenCaptureKit...")
            
            // Get window information
            guard let windowInfo = windowDetector.findWindow() else {
                let errorMessage = "Ableton window not found. Make sure Ableton Live is running and visible on screen."
                logger.error("\(errorMessage)")
                completion(.failure(NSError(domain: "ScreenshotManager", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])))
                return
            }

            let bounds = windowInfo.bounds
            let windowID = windowInfo.windowID
            logger.info("Found Ableton window: ID=\(windowID), bounds=(\(bounds.origin.x), \(bounds.origin.y), \(bounds.width), \(bounds.height))")

            do {
                // Get available content for capture
                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                
                // Find Ableton window in list of available windows
                guard let abletonWindow = availableContent.windows.first(where: { window in
                    window.windowID == windowID
                }) else {
                    // If not found by ID, search by name
                    let abletonWindowByName = availableContent.windows.first { window in
                        let windowTitle = window.title ?? ""
                        let ownerName = window.owningApplication?.applicationName ?? ""
                        return windowTitle.contains("Ableton Live") ||
                               windowTitle.contains("Live") ||
                               ownerName.contains("Live") ||
                               ownerName.contains("Ableton")
                    }
                    
                    guard let targetWindow = abletonWindowByName else {
                        let errorMessage = "Ableton window not found in available windows for capture."
                        logger.error("\(errorMessage)")
                        completion(.failure(NSError(domain: "ScreenshotManager", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMessage])))
                        return
                    }
                    
                    return await captureWindowWithSCK(window: targetWindow, completion: completion)
                }
                
                await captureWindowWithSCK(window: abletonWindow, completion: completion)
                
            } catch {
                let errorMessage = "Error getting available content: \(error.localizedDescription). Check screen recording permissions in Settings → Privacy & Security → Screen Recording."
                logger.error("\(errorMessage)")
                completion(.failure(NSError(domain: "ScreenshotManager", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMessage])))
            }
        }
    }
    
    /// Captures window using ScreenCaptureKit
    @MainActor
    private func captureWindowWithSCK(window: SCWindow, completion: @escaping (Result<URL, Error>) -> Void) async {
        do {
            // Use frame to get window size
            let windowFrame = window.frame
            let windowWidth = Int(windowFrame.width)
            let windowHeight = Int(windowFrame.height)
            
            logger.info("Capturing window: frame=(\(windowFrame.width)x\(windowFrame.height))")
            
            // Create content filter for specific window
            // desktopIndependentWindow captures only window content, without background
            let filter = SCContentFilter(desktopIndependentWindow: window)
            
            // Capture settings
            let configuration = SCStreamConfiguration()
            // Use contentRect size for proper content capture
            configuration.width = windowWidth
            configuration.height = windowHeight
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS for screenshot
            configuration.queueDepth = 1
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            
            // Important: don't set sourceRect to capture all window content
            // sourceRect is only used for cropping, but we need the whole window
            
            // Create stream for capture
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            
            // Create output to receive frames
            let streamOutput = ScreenshotStreamOutput()
            try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screenshot.queue"))
            
            // Start stream
            try await stream.startCapture()
            
            // Wait for frame (give some time for first frame)
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            let image = await streamOutput.waitForFrame(timeout: 5.0)
            
            // Stop stream
            try await stream.stopCapture()
            
            guard let capturedImage = image else {
                let errorMessage = "Failed to get frame from capture stream."
                logger.error("\(errorMessage)")
                completion(.failure(NSError(domain: "ScreenshotManager", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMessage])))
                return
            }
            
            logger.info("Window successfully captured, image size: \(capturedImage.size.width)x\(capturedImage.size.height)")
            let url = saveImage(capturedImage, prefix: "ableton_full")
            logger.info("Screenshot saved: \(url.path)")
            completion(.success(url))
            
        } catch {
            let errorMessage = "Error capturing window: \(error.localizedDescription)"
            logger.error("\(errorMessage)")
            completion(.failure(NSError(domain: "ScreenshotManager", code: 5, userInfo: [NSLocalizedDescriptionKey: errorMessage])))
        }
    }

    /// Captures region around point
    func captureRegion(around point: CGPoint) async throws -> URL {
        let size: CGFloat = 300
        return try await captureAreaAround(point: point, size: CGSize(width: size, height: size))
    }
    
    /// Captures region around point with specified size
    func captureAreaAround(point: CGPoint, size: CGSize) async throws -> URL {
        return try await Task { @MainActor in
            logger.info("Capturing region around point (\(point.x), \(point.y))")
            
            // First try to find window at this point
            if let windowAtPoint = findWindowAt(point: point) {
                logger.info("Found window at click point: ID=\(windowAtPoint.windowID)")
                
                // Get available content
                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                
                // Find window by ID
                if let targetWindow = availableContent.windows.first(where: { $0.windowID == windowAtPoint.windowID }) {
                    // Capture window
                    let windowImage = try await captureWindowImage(window: targetWindow)
                    
                    // Crop to needed region
                    if let croppedImage = cropImage(windowImage, to: CGRect(
                        x: point.x - size.width / 2,
                        y: point.y - size.height / 2,
                        width: size.width,
                        height: size.height
                    ), windowBounds: windowAtPoint.bounds, clickPoint: point) {
                        logger.info("Successfully captured and cropped window")
                        return saveImage(croppedImage, prefix: "region_\(Int(point.x))_\(Int(point.y))")
                    } else {
                        // If cropping failed, return full window
                        logger.info("Cropping failed, returning full window")
                        return saveImage(windowImage, prefix: "window_\(Int(point.x))_\(Int(point.y))")
                    }
                }
            }
            
            // Fallback: capture screen region
            logger.info("Window not found, using screen region capture")
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            
            let image = try await captureScreenRegion(rect: rect)
            return saveImage(image, prefix: "region_\(Int(point.x))_\(Int(point.y))")
        }.value
    }
    
    /// Captures window image using ScreenCaptureKit
    @MainActor
    private func captureWindowImage(window: SCWindow) async throws -> NSImage {
        let windowFrame = window.frame
        let windowWidth = Int(windowFrame.width)
        let windowHeight = Int(windowFrame.height)
        
        let filter = SCContentFilter(desktopIndependentWindow: window)
        
        let configuration = SCStreamConfiguration()
        configuration.width = windowWidth
        configuration.height = windowHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let streamOutput = ScreenshotStreamOutput()
        
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screenshot.queue"))
        try await stream.startCapture()
        
        // Give time for first frame
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        let image = await streamOutput.waitForFrame(timeout: 5.0)
        
        try await stream.stopCapture()
        
        guard let capturedImage = image else {
            throw NSError(domain: "ScreenshotManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to get frame"])
        }
        
        return capturedImage
    }
    
    /// Captures screen region
    @MainActor
    private func captureScreenRegion(rect: CGRect) async throws -> NSImage {
        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let display = availableContent.displays.first else {
            throw NSError(domain: "ScreenshotManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Display not found"])
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
        
        let image = await streamOutput.waitForFrame(timeout: 5.0)
        
        try await stream.stopCapture()
        
        guard let capturedImage = image else {
            throw NSError(domain: "ScreenshotManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to capture screen region"])
        }
        
        return capturedImage
    }
    
    /// Finds window at specified point
    private func findWindowAt(point: CGPoint) -> (bounds: CGRect, windowID: CGWindowID)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        var bestWindow: (bounds: CGRect, windowID: CGWindowID, layer: Int)?
        
        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat,
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            
            if let screen = NSScreen.main {
                let screenHeight = screen.frame.height
                let quartzY = screenHeight - point.y
                
                if x <= point.x && point.x < x + width &&
                   y <= quartzY && quartzY < y + height {
                    
                    if bestWindow == nil ||
                       (layer > bestWindow!.layer) ||
                       (layer == bestWindow!.layer && width * height > bestWindow!.bounds.width * bestWindow!.bounds.height) {
                        bestWindow = (bounds: bounds, windowID: windowID, layer: layer)
                    }
                }
            }
        }
        
        return bestWindow.map { (bounds: $0.bounds, windowID: $0.windowID) }
    }
    
    /// Crops image to specified region
    private func cropImage(_ image: NSImage, to rect: CGRect, windowBounds: CGRect, clickPoint: CGPoint) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        
        let scaleX = imageWidth / windowBounds.width
        let scaleY = imageHeight / windowBounds.height
        
        guard let screen = NSScreen.main else { return nil }
        let screenHeight = screen.frame.height
        let quartzClickY = screenHeight - clickPoint.y
        
        let windowRelativeX = clickPoint.x - windowBounds.origin.x
        let windowRelativeY = quartzClickY - windowBounds.origin.y
        
        let cropWidth = min(imageWidth, rect.width * scaleX)
        let cropHeight = min(imageHeight, rect.height * scaleY)
        
        let cropX = max(0, min(imageWidth - cropWidth, (windowRelativeX - rect.width / 2) * scaleX))
        let cropY = max(0, min(imageHeight - cropHeight, (windowRelativeY - rect.height / 2) * scaleY))
        let flippedCropY = imageHeight - cropY - cropHeight
        
        guard cropWidth > 0 && cropHeight > 0,
              let croppedCGImage = cgImage.cropping(to: CGRect(x: cropX, y: flippedCropY, width: cropWidth, height: cropHeight)) else {
            return nil
        }
        
        return NSImage(cgImage: croppedCGImage, size: rect.size)
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

    /// Saves image to file
    private func saveImage(_ image: NSImage, prefix: String) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(prefix)_\(timestamp).png"
        let url = cacheDir.appendingPathComponent(filename)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return url
        }

        try? pngData.write(to: url)
        return url
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
