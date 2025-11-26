import Foundation
import AppKit
import CoreGraphics

final class ClickMonitor {
    static let shared = ClickMonitor()
    private var eventTap: CFMachPort?
    private var callback: ((CGPoint) -> Void)?

    private init() {}

    func start(callback: @escaping (CGPoint) -> Void) {
        self.callback = callback

        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("Failed to create event tap. Check Accessibility permissions.")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    }

    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        callback = nil
    }

    func handleEvent(_ event: CGEvent) {
        let location = event.location
        callback?(location)
    }
}

private func eventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

    let monitor = Unmanaged<ClickMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleEvent(event)

    return Unmanaged.passUnretained(event)
}

