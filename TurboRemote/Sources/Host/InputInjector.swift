import Foundation
import CoreGraphics
import AppKit

final class InputInjector {
    private let eventSource: CGEventSource?
    private var screenWidth: CGFloat = 1920
    private var screenHeight: CGFloat = 1080

    init() {
        eventSource = CGEventSource(stateID: .combinedSessionState)
    }

    func updateScreenSize(width: Int, height: Int) {
        // Use the actual display pixel dimensions (not retina)
        // CGEvent uses point coordinates, not pixels
        screenWidth = CGFloat(width)
        screenHeight = CGFloat(height)
    }

    func inject(_ event: InputEvent) {
        // Convert normalized coordinates to screen points
        let px = CGFloat(event.x) * screenWidth
        let py = CGFloat(event.y) * screenHeight
        let point = CGPoint(x: px, y: py)

        switch event.type {
        case .mouseMove:
            postMouseEvent(.mouseMoved, at: point, button: .left)

        case .mouseDown:
            let cgEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown,
                                  mouseCursorPosition: point, mouseButton: .left)
            if event.clickCount > 1 {
                cgEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
            }
            cgEvent?.post(tap: .cghidEventTap)

        case .mouseUp:
            postMouseEvent(.leftMouseUp, at: point, button: .left)

        case .mouseDragged:
            postMouseEvent(.leftMouseDragged, at: point, button: .left)

        case .rightMouseDown:
            postMouseEvent(.rightMouseDown, at: point, button: .right)

        case .rightMouseUp:
            postMouseEvent(.rightMouseUp, at: point, button: .right)

        case .rightMouseDragged:
            postMouseEvent(.rightMouseDragged, at: point, button: .right)

        case .scroll:
            let cgEvent = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(event.scrollDeltaY),
                                  wheel2: Int32(event.scrollDeltaX),
                                  wheel3: 0)
            cgEvent?.post(tap: .cghidEventTap)

        case .keyDown:
            let cgEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: event.keyCode, keyDown: true)
            cgEvent?.flags = CGEventFlags(rawValue: event.modifierFlags)
            cgEvent?.post(tap: .cghidEventTap)

        case .keyUp:
            let cgEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: event.keyCode, keyDown: false)
            cgEvent?.flags = CGEventFlags(rawValue: event.modifierFlags)
            cgEvent?.post(tap: .cghidEventTap)

        case .flagsChanged:
            let cgEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
            cgEvent?.type = .flagsChanged
            cgEvent?.flags = CGEventFlags(rawValue: event.modifierFlags)
            cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        let cgEvent = CGEvent(mouseEventSource: eventSource, mouseType: type,
                              mouseCursorPosition: point, mouseButton: button)
        cgEvent?.post(tap: .cghidEventTap)
    }

    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
