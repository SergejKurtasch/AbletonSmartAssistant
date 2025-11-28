import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import OSLog

final class ClickMonitor {
    static let shared = ClickMonitor()
    var eventTap: CFMachPort? // internal for access from eventCallback
    private var callback: ((CGPoint) -> Void)?
    private let logger = Logger(subsystem: "ASAApp", category: "ClickMonitor")
    private var hasRequestedPermissions = false // Flag to prevent showing dialog every time

    private init() {}
    
    /// Checks if Accessibility permissions are granted WITHOUT showing dialog
    var hasAccessibilityPermissions: Bool {
        let checkOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(checkOptions)
    }
    
    /// Requests Accessibility permissions (shows dialog only once)
    func requestAccessibilityPermissions() {
        guard !hasRequestedPermissions else {
            logger.info("Permissions already requested, not showing dialog again")
            return
        }
        
        hasRequestedPermissions = true
        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOptions)
        logger.info("Requested Accessibility permissions")
    }

    func start(callback: @escaping (CGPoint) -> Void) {
        // Stop previous monitoring if it was running
        stop()
        
        self.callback = callback

        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)

        // Check Accessibility API availability WITHOUT showing dialog
        let accessibilityEnabled = hasAccessibilityPermissions
        
        if !accessibilityEnabled {
            logger.warning("Accessibility permissions not granted")
            // Show dialog only if we haven't shown it yet
            if !hasRequestedPermissions {
                logger.info("Requesting Accessibility permissions (first time)...")
                requestAccessibilityPermissions()
            } else {
                logger.warning("Accessibility permissions not granted. Please enable them in Settings → Privacy & Security → Accessibility and restart the application")
            }
            // Don't create event tap if permissions are not granted
            return
        } else {
            logger.info("Accessibility permissions already granted")
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            logger.error("Failed to create event tap. Check Accessibility permissions in Settings → Privacy & Security → Accessibility")
            return
        }

        // Enable event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource = runLoopSource else {
            logger.error("Failed to create run loop source")
            self.eventTap = nil
            return
        }
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Check that tap is actually enabled
        let isEnabled = CGEvent.tapIsEnabled(tap: eventTap)
        logger.info("ClickMonitor successfully started, event tap active: \(isEnabled)")
        
        if !isEnabled {
            logger.error("Event tap not enabled, trying to enable again...")
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
            logger.info("ClickMonitor stopped")
        }
        callback = nil
    }

    func handleEvent(_ event: CGEvent) {
        let location = event.location
        logger.info("Click detected at point: (\(location.x), \(location.y))")
        
        // Call callback on main queue to avoid threading issues
        DispatchQueue.main.async { [weak self] in
            self?.callback?(location)
        }
    }
    
    var isRunning: Bool {
        return eventTap != nil
    }
}

private func eventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

    let monitor = Unmanaged<ClickMonitor>.fromOpaque(refcon).takeUnretainedValue()
    
    // Check event type
    switch type {
    case .tapDisabledByTimeout:
        // Event tap was disabled by timeout, need to restart
        let logger = Logger(subsystem: "ASAApp", category: "ClickMonitor")
        logger.warning("Event tap disabled by timeout, restarting...")
        // Restart tap if it still exists
        if let eventTap = monitor.eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        return Unmanaged.passUnretained(event)
        
    case .tapDisabledByUserInput:
        // Event tap was disabled by user
        let logger = Logger(subsystem: "ASAApp", category: "ClickMonitor")
        logger.warning("Event tap disabled by user")
        return Unmanaged.passUnretained(event)
        
    case .leftMouseDown, .rightMouseDown:
        // Handle clicks
        let logger = Logger(subsystem: "ASAApp", category: "ClickMonitor")
        logger.info("Received click event: \(type.rawValue)")
        monitor.handleEvent(event)
        return Unmanaged.passUnretained(event)
        
    default:
        // Skip other events
        return Unmanaged.passUnretained(event)
    }
}

