import Foundation

enum InputEventType: UInt8 {
    case mouseMove     = 1
    case mouseDown     = 2
    case mouseUp       = 3
    case scroll        = 4
    case keyDown       = 5
    case keyUp         = 6
    case flagsChanged  = 7
    case mouseDragged  = 8
    case rightMouseDown  = 9
    case rightMouseUp    = 10
    case rightMouseDragged = 11
}

struct InputEvent {
    let type: InputEventType
    // Mouse: normalized coordinates (0-1)
    let x: Float
    let y: Float
    // Mouse button (0=left, 1=right)
    let button: UInt8
    let clickCount: UInt8
    // Scroll deltas
    let scrollDeltaX: Float
    let scrollDeltaY: Float
    // Keyboard
    let keyCode: UInt16
    let modifierFlags: UInt64

    func serialize() -> Data {
        var data = Data()
        data.append(type.rawValue)

        var fx = x, fy = y
        data.append(Data(bytes: &fx, count: 4))
        data.append(Data(bytes: &fy, count: 4))
        data.append(button)
        data.append(clickCount)

        var sdx = scrollDeltaX, sdy = scrollDeltaY
        data.append(Data(bytes: &sdx, count: 4))
        data.append(Data(bytes: &sdy, count: 4))

        var kc = keyCode
        data.append(Data(bytes: &kc, count: 2))
        var mf = modifierFlags
        data.append(Data(bytes: &mf, count: 8))

        return data
    }

    static func deserialize(from data: Data) -> InputEvent? {
        // type(1) + x(4) + y(4) + button(1) + clickCount(1) + sdx(4) + sdy(4) + keyCode(2) + modFlags(8) = 29
        guard data.count >= 29 else { return nil }
        guard let type = InputEventType(rawValue: data[0]) else { return nil }

        var offset = 1
        let x: Float = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Float.self) }; offset += 4
        let y: Float = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Float.self) }; offset += 4
        let button = data[offset]; offset += 1
        let clickCount = data[offset]; offset += 1
        let sdx: Float = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Float.self) }; offset += 4
        let sdy: Float = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Float.self) }; offset += 4
        let keyCode: UInt16 = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }; offset += 2
        let modifierFlags: UInt64 = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) }

        return InputEvent(type: type, x: x, y: y, button: button, clickCount: clickCount,
                          scrollDeltaX: sdx, scrollDeltaY: sdy, keyCode: keyCode, modifierFlags: modifierFlags)
    }

    // Convenience initializers
    static func mouseMove(x: Float, y: Float) -> InputEvent {
        InputEvent(type: .mouseMove, x: x, y: y, button: 0, clickCount: 0, scrollDeltaX: 0, scrollDeltaY: 0, keyCode: 0, modifierFlags: 0)
    }

    static func mouseDown(x: Float, y: Float, button: UInt8 = 0, clickCount: UInt8 = 1) -> InputEvent {
        InputEvent(type: button == 1 ? .rightMouseDown : .mouseDown, x: x, y: y, button: button, clickCount: clickCount, scrollDeltaX: 0, scrollDeltaY: 0, keyCode: 0, modifierFlags: 0)
    }

    static func mouseUp(x: Float, y: Float, button: UInt8 = 0) -> InputEvent {
        InputEvent(type: button == 1 ? .rightMouseUp : .mouseUp, x: x, y: y, button: button, clickCount: 0, scrollDeltaX: 0, scrollDeltaY: 0, keyCode: 0, modifierFlags: 0)
    }

    static func mouseDragged(x: Float, y: Float, button: UInt8 = 0) -> InputEvent {
        InputEvent(type: button == 1 ? .rightMouseDragged : .mouseDragged, x: x, y: y, button: button, clickCount: 0, scrollDeltaX: 0, scrollDeltaY: 0, keyCode: 0, modifierFlags: 0)
    }

    static func scroll(x: Float, y: Float, deltaX: Float, deltaY: Float) -> InputEvent {
        InputEvent(type: .scroll, x: x, y: y, button: 0, clickCount: 0, scrollDeltaX: deltaX, scrollDeltaY: deltaY, keyCode: 0, modifierFlags: 0)
    }

    static func keyDown(keyCode: UInt16, modifierFlags: UInt64) -> InputEvent {
        InputEvent(type: .keyDown, x: 0, y: 0, button: 0, clickCount: 0, scrollDeltaX: 0, scrollDeltaY: 0, keyCode: keyCode, modifierFlags: modifierFlags)
    }

    static func keyUp(keyCode: UInt16, modifierFlags: UInt64) -> InputEvent {
        InputEvent(type: .keyUp, x: 0, y: 0, button: 0, clickCount: 0, scrollDeltaX: 0, scrollDeltaY: 0, keyCode: keyCode, modifierFlags: modifierFlags)
    }

    static func flagsChanged(modifierFlags: UInt64) -> InputEvent {
        InputEvent(type: .flagsChanged, x: 0, y: 0, button: 0, clickCount: 0, scrollDeltaX: 0, scrollDeltaY: 0, keyCode: 0, modifierFlags: modifierFlags)
    }
}
