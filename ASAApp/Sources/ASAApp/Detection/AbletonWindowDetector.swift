import Foundation
import AppKit
import CoreGraphics

/// Detects and monitors Ableton Live window position and size
/// Uses hybrid approach: lazy initialization + caching + periodic updates
@MainActor
final class AbletonWindowDetector {
    static let shared = AbletonWindowDetector()
    
    private struct WindowInfo {
        let bounds: CGRect
        let windowID: CGWindowID
        let lastUpdated: Date
    }
    
    private var cachedWindow: WindowInfo?
    private var monitoringTimer: Timer?
    private let updateInterval: TimeInterval = 2.5 // Update every 2.5 seconds
    private let queue = DispatchQueue(label: "AbletonWindowDetector.queue", qos: .utility)
    
    private init() {}
    
    /// Find Ableton window (lazy initialization on first call)
    func findWindow() -> (bounds: CGRect, windowID: CGWindowID)? {
        // Return cached if available and recent (within 1 second)
        if let cached = cachedWindow,
           Date().timeIntervalSince(cached.lastUpdated) < 1.0 {
            return (cached.bounds, cached.windowID)
        }
        
        // Search for window - use optionOnScreenBelowWindow to include windows even when not focused
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        for windowInfo in windowList {
            // Check window name
            let windowName = windowInfo[kCGWindowName as String] as? String ?? ""
            
            // Check owner name (process name) - this is more reliable
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
            
            // Check if it's an Ableton window by name or owner
            let isAbletonWindow = windowName.contains("Ableton Live") || 
                                 windowName.contains("Live") ||
                                 ownerName.contains("Live") ||
                                 ownerName.contains("Ableton")
            
            // Check window layer - normal windows have layer >= 0
            // Desktop elements and minimized windows typically have negative layers
            // Since we use .optionOnScreenOnly, windows should already be on screen
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            
            // Skip if window is a desktop element or minimized (layer < 0)
            guard layer >= 0 else { continue }
            
            if isAbletonWindow {
                if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                   let x = boundsDict["X"] as? CGFloat,
                   let y = boundsDict["Y"] as? CGFloat,
                   let width = boundsDict["Width"] as? CGFloat,
                   let height = boundsDict["Height"] as? CGFloat,
                   width > 100 && height > 100 { // Filter out tiny windows
                    let bounds = CGRect(x: x, y: y, width: width, height: height)
                    if let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID {
                        let info = WindowInfo(bounds: bounds, windowID: windowID, lastUpdated: Date())
                        cachedWindow = info
                        return (bounds, windowID)
                    }
                }
            }
        }
        
        // Clear cache if window not found
        cachedWindow = nil
        return nil
    }
    
    /// Get current window bounds (uses cache if available)
    func getWindowBounds() -> CGRect? {
        if let cached = cachedWindow,
           Date().timeIntervalSince(cached.lastUpdated) < 1.0 {
            return cached.bounds
        }
        
        return findWindow()?.bounds
    }
    
    /// Get window ID
    func getWindowID() -> CGWindowID? {
        if let cached = cachedWindow,
           Date().timeIntervalSince(cached.lastUpdated) < 1.0 {
            return cached.windowID
        }
        
        return findWindow()?.windowID
    }
    
    /// Start periodic monitoring of window position/size
    func startMonitoring() {
        stopMonitoring() // Stop existing timer if any
        
        // Initial search
        _ = findWindow()
        
        // Start periodic updates
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.findWindow() // Update cache
            }
        }
        
        // Add to common run loop modes to keep it running
        if let timer = monitoringTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    /// Stop monitoring
    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
    
    /// Force refresh window info (bypass cache)
    func refresh() -> (bounds: CGRect, windowID: CGWindowID)? {
        cachedWindow = nil
        return findWindow()
    }
    
    /// Check if Ableton window is currently available
    func isWindowAvailable() -> Bool {
        return findWindow() != nil
    }
}

