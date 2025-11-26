import Foundation
import AppKit
import CoreGraphics

final class ScreenshotManager {
    static let shared = ScreenshotManager()
    private let cacheDir: URL

    private init() {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = cacheURL.appendingPathComponent("ASAApp/Screenshots")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func captureFullAbletonWindow(completion: @escaping (Result<URL, Error>) -> Void) {
        Task {
            do {
                guard let window = findAbletonWindow() else {
                    completion(.failure(NSError(domain: "ScreenshotManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ableton window not found"])))
                    return
                }

                let bounds = window.bounds
                guard let image = captureScreenRegion(rect: bounds) else {
                    completion(.failure(NSError(domain: "ScreenshotManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to capture screen"])))
                    return
                }

                let url = saveImage(image, prefix: "ableton_full")
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func captureRegion(around point: CGPoint) async throws -> URL {
        let size: CGFloat = 300
        let rect = CGRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size
        )

        guard let image = captureScreenRegion(rect: rect) else {
            throw NSError(domain: "ScreenshotManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to capture region"])
        }

        return saveImage(image, prefix: "click_\(Int(point.x))_\(Int(point.y))")
    }

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

    private func findAbletonWindow() -> (bounds: CGRect, windowID: CGWindowID)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            if let name = windowInfo[kCGWindowName as String] as? String,
               name.contains("Ableton Live") {
                if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                   let x = boundsDict["X"] as? CGFloat,
                   let y = boundsDict["Y"] as? CGFloat,
                   let width = boundsDict["Width"] as? CGFloat,
                   let height = boundsDict["Height"] as? CGFloat {
                    let bounds = CGRect(x: x, y: y, width: width, height: height)
                    if let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID {
                        return (bounds, windowID)
                    }
                }
            }
        }
        return nil
    }

    private func captureScreenRegion(rect: CGRect) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, kCGNullWindowID, .bestResolution) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: rect.size)
    }

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

