import ApplicationServices
import CoreGraphics
import Foundation
import RDCore

/// Replays the client's mouse and keyboard on this Mac with CGEvent.
/// Needs Accessibility permission; without it macOS silently drops events.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressedButtons = Set<UInt8>()
    private var pressedKeys = Set<UInt16>()
    private var flags: CGEventFlags = []
    private var lastPoint = CGPoint.zero

    /// Prompts for Accessibility access the first time. Returns whether
    /// input injection will work right now.
    static func checkPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func handle(_ event: InputEvent) {
        switch event {
        case let .mouseMove(x, y):
            let point = screenPoint(x, y)
            post(mouse: dragType() ?? .mouseMoved, at: point, button: dragButton())

        case let .mouseButton(button, down, clickCount, x, y):
            let point = screenPoint(x, y)
            if down { pressedButtons.insert(button.rawValue) } else { pressedButtons.remove(button.rawValue) }
            let type: CGEventType
            let cgButton: CGMouseButton
            switch button {
            case .left: type = down ? .leftMouseDown : .leftMouseUp; cgButton = .left
            case .right: type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
            case .other: type = down ? .otherMouseDown : .otherMouseUp; cgButton = .center
            }
            post(mouse: type, at: point, button: cgButton, clickCount: max(1, Int64(clickCount)))

        case let .scroll(dx, dy):
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamp(dy)), wheel2: Int32(clamp(dx)), wheel3: 0)
            else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)

        case let .key(keyCode, down, rawFlags):
            flags = CGEventFlags(rawValue: rawFlags & 0xFFFF_0000)
            if down { pressedKeys.insert(keyCode) } else { pressedKeys.remove(keyCode) }
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Lets go of anything the client was holding, so a dropped connection
    /// can't leave a key or mouse button stuck down on this Mac.
    func releaseAll() {
        for key in pressedKeys {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)?.post(tap: .cghidEventTap)
        }
        pressedKeys.removeAll()
        flags = []
        for raw in pressedButtons {
            let (type, button): (CGEventType, CGMouseButton) = switch MouseButton(rawValue: raw) {
            case .right: (.rightMouseUp, .right)
            case .other: (.otherMouseUp, .center)
            default: (.leftMouseUp, .left)
            }
            post(mouse: type, at: lastPoint, button: button)
        }
        pressedButtons.removeAll()
    }

    // MARK: - Helpers

    private func screenPoint(_ x: Float, _ y: Float) -> CGPoint {
        // The stream shows the main display; global coordinates are in points
        // with the origin at the main display's top-left.
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let nx = CGFloat(min(max(x, 0), 1))
        let ny = CGFloat(min(max(y, 0), 1))
        lastPoint = CGPoint(x: bounds.minX + nx * (bounds.width - 1), y: bounds.minY + ny * (bounds.height - 1))
        return lastPoint
    }

    private func dragType() -> CGEventType? {
        if pressedButtons.contains(MouseButton.left.rawValue) { return .leftMouseDragged }
        if pressedButtons.contains(MouseButton.right.rawValue) { return .rightMouseDragged }
        if pressedButtons.contains(MouseButton.other.rawValue) { return .otherMouseDragged }
        return nil
    }

    private func dragButton() -> CGMouseButton {
        if pressedButtons.contains(MouseButton.right.rawValue) && !pressedButtons.contains(MouseButton.left.rawValue) {
            return .right
        }
        if pressedButtons == [MouseButton.other.rawValue] { return .center }
        return .left
    }

    private func post(mouse type: CGEventType, at point: CGPoint, button: CGMouseButton, clickCount: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickCount)
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func clamp(_ v: Float) -> Float { min(max(v, -10_000), 10_000) }
}
