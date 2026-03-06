import MetalKit
import AppKit

final class InputCaptureMTKView: MTKView {
    var onInputEvent: ((InputEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Coordinate Mapping

    private func normalizedPoint(for event: NSEvent) -> (Float, Float) {
        let loc = convert(event.locationInWindow, from: nil)
        let x = Float(loc.x / bounds.width)
        // Flip Y: NSView origin is bottom-left, screen origin is top-left
        let y = Float(1.0 - loc.y / bounds.height)
        return (max(0, min(1, x)), max(0, min(1, y)))
    }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        let (x, y) = normalizedPoint(for: event)
        onInputEvent?(.mouseMove(x: x, y: y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let (x, y) = normalizedPoint(for: event)
        onInputEvent?(.mouseDown(x: x, y: y, button: 0, clickCount: UInt8(event.clickCount)))
    }

    override func mouseUp(with event: NSEvent) {
        let (x, y) = normalizedPoint(for: event)
        onInputEvent?(.mouseUp(x: x, y: y, button: 0))
    }

    override func mouseDragged(with event: NSEvent) {
        let (x, y) = normalizedPoint(for: event)
        onInputEvent?(.mouseDragged(x: x, y: y, button: 0))
    }

    override func rightMouseDown(with event: NSEvent) {
        let (x, y) = normalizedPoint(for: event)
        onInputEvent?(.mouseDown(x: x, y: y, button: 1, clickCount: UInt8(event.clickCount)))
    }

    override func rightMouseUp(with event: NSEvent) {
        let (x, y) = normalizedPoint(for: event)
        onInputEvent?(.mouseUp(x: x, y: y, button: 1))
    }

    override func rightMouseDragged(with event: NSEvent) {
        let (x, y) = normalizedPoint(for: event)
        onInputEvent?(.mouseDragged(x: x, y: y, button: 1))
    }

    override func scrollWheel(with event: NSEvent) {
        let (x, y) = normalizedPoint(for: event)
        onInputEvent?(.scroll(x: x, y: y, deltaX: Float(event.scrollingDeltaX), deltaY: Float(event.scrollingDeltaY)))
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        onInputEvent?(.keyDown(keyCode: event.keyCode, modifierFlags: UInt64(event.modifierFlags.rawValue)))
    }

    override func keyUp(with event: NSEvent) {
        onInputEvent?(.keyUp(keyCode: event.keyCode, modifierFlags: UInt64(event.modifierFlags.rawValue)))
    }

    override func flagsChanged(with event: NSEvent) {
        onInputEvent?(.flagsChanged(modifierFlags: UInt64(event.modifierFlags.rawValue)))
    }
}
