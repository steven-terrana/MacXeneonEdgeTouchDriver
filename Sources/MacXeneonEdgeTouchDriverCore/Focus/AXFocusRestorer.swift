import ApplicationServices
import CoreGraphics
import Foundation

/// Restores focus to the exact AX window that was focused before a touch gesture.
public final class AXFocusRestorer: FocusRestorer {
    private struct CapturedWindow {
        let application: AXUIElement
        let window: AXUIElement
    }

    private let systemWideElement: AXUIElement
    private var capturedWindow: CapturedWindow?

    public init(systemWideElement: AXUIElement = AXUIElementCreateSystemWide()) {
        self.systemWideElement = systemWideElement
    }

    public func captureFocusedWindow() {
        capturedWindow = nil

        guard let application = copyElementAttribute(systemWideElement, attribute: kAXFocusedApplicationAttribute) else {
            DriverLoggers.log(.debug, category: .focus, "Could not capture focused application before touch gesture.")
            return
        }

        guard let window = copyElementAttribute(application, attribute: kAXFocusedWindowAttribute) else {
            DriverLoggers.log(.debug, category: .focus, "Could not capture focused window before touch gesture.")
            return
        }

        capturedWindow = CapturedWindow(application: application, window: window)
    }

    public func prepareTargetWindow(at point: CGPoint) {
        var targetElement: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &targetElement
        )
        guard hitTestResult == .success, let targetElement else {
            DriverLoggers.log(
                .debug,
                category: .focus,
                "Could not resolve the target accessibility element before touch click: \(hitTestResult.rawValue)."
            )
            return
        }

        var targetPID = pid_t()
        let targetPIDResult = AXUIElementGetPid(targetElement, &targetPID)
        guard targetPIDResult == .success else {
            DriverLoggers.log(
                .debug,
                category: .focus,
                "Could not resolve the target application pid before touch click: \(targetPIDResult.rawValue)."
            )
            return
        }

        let targetApplication = AXUIElementCreateApplication(targetPID)
        let targetWindow = copyElementAttribute(targetElement, attribute: kAXWindowAttribute)

        if let capturedWindow,
           let targetWindow,
           CFEqual(capturedWindow.application, targetApplication),
           CFEqual(capturedWindow.window, targetWindow) {
            return
        }

        let frontmostResult = AXUIElementSetAttributeValue(
            targetApplication,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )

        guard let targetWindow else {
            DriverLoggers.log(
                .warning,
                category: .focus,
                "Target application activation had no resolvable window. frontmost=\(frontmostResult.rawValue)."
            )
            return
        }

        let focusedWindowResult = AXUIElementSetAttributeValue(
            targetApplication,
            kAXFocusedWindowAttribute as CFString,
            targetWindow
        )
        let mainWindowResult = AXUIElementSetAttributeValue(
            targetApplication,
            kAXMainWindowAttribute as CFString,
            targetWindow
        )
        let raiseResult = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)

        let deadline = Date().addingTimeInterval(0.050)
        while !isWindowFocused(application: targetApplication, window: targetWindow),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        let didFocusTarget = isWindowFocused(application: targetApplication, window: targetWindow)

        if frontmostResult != .success ||
            focusedWindowResult != .success ||
            mainWindowResult != .success ||
            raiseResult != .success ||
            !didFocusTarget {
            DriverLoggers.log(
                .warning,
                category: .focus,
                "Target window preparation was incomplete. frontmost=\(frontmostResult.rawValue), focusedWindow=\(focusedWindowResult.rawValue), mainWindow=\(mainWindowResult.rawValue), raise=\(raiseResult.rawValue), verified=\(didFocusTarget)."
            )
        }
    }

    public func restoreCapturedWindow() {
        guard let capturedWindow else {
            return
        }
        self.capturedWindow = nil

        // Do not use app-level AXFrontmost here; it raises sibling windows from the same application.
        let focusedWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFocusedWindowAttribute as CFString,
            capturedWindow.window
        )
        let mainWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXMainWindowAttribute as CFString,
            capturedWindow.window
        )
        let raiseResult = AXUIElementPerformAction(capturedWindow.window, kAXRaiseAction as CFString)
        let sessionClickResult = clickCapturedWindowTitleBar(capturedWindow)
        let refocusedWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFocusedWindowAttribute as CFString,
            capturedWindow.window
        )
        let remadeMainWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXMainWindowAttribute as CFString,
            capturedWindow.window
        )
        let mainResult = AXUIElementSetAttributeValue(
            capturedWindow.window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let focusedResult = AXUIElementSetAttributeValue(
            capturedWindow.window,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        guard isWindowFocused(capturedWindow) else {
            DriverLoggers.log(
                .warning,
                category: .focus,
                "Could not verify restore of the previously focused window. focusedWindow=\(focusedWindowResult.rawValue), mainWindow=\(mainWindowResult.rawValue), raise=\(raiseResult.rawValue), sessionClick=\(sessionClickResult), refocusedWindow=\(refocusedWindowResult.rawValue), remadeMainWindow=\(remadeMainWindowResult.rawValue), windowMain=\(mainResult.rawValue), windowFocused=\(focusedResult.rawValue)."
            )
            return
        }
    }

    public func discardCapturedWindow() {
        capturedWindow = nil
    }

    private func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func isWindowFocused(_ capturedWindow: CapturedWindow) -> Bool {
        isWindowFocused(application: capturedWindow.application, window: capturedWindow.window)
    }

    private func isWindowFocused(application: AXUIElement, window: AXUIElement) -> Bool {
        guard let focusedApplication = copyElementAttribute(systemWideElement, attribute: kAXFocusedApplicationAttribute),
              CFEqual(focusedApplication, application) else {
            return false
        }

        guard let focusedWindow = copyElementAttribute(application, attribute: kAXFocusedWindowAttribute) else {
            return false
        }

        return CFEqual(focusedWindow, window)
    }

    private func clickCapturedWindowTitleBar(_ capturedWindow: CapturedWindow) -> Bool {
        guard let clickPoint = titleBarClickPoint(for: capturedWindow.window) else {
            return false
        }

        let originalPosition = CGEvent(source: nil)?.location
        postMouseEvent(type: .leftMouseDown, at: clickPoint)
        postMouseEvent(type: .leftMouseUp, at: clickPoint)

        if let originalPosition {
            CGWarpMouseCursorPosition(originalPosition)
        }
        return true
    }

    private func postMouseEvent(type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .privateState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            DriverLoggers.log(.error, category: .focus, "Failed to create focus restore mouse event of type \(type.rawValue).")
            return
        }

        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.left.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func titleBarClickPoint(for window: AXUIElement) -> CGPoint? {
        if let title = copyElementAttribute(window, attribute: kAXTitleUIElementAttribute),
           let position = copyCGPointAttribute(title, attribute: kAXPositionAttribute),
           let size = copyCGSizeAttribute(title, attribute: kAXSizeAttribute),
           size.width > 0,
           size.height > 0 {
            return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        }

        guard let position = copyCGPointAttribute(window, attribute: kAXPositionAttribute),
              let size = copyCGSizeAttribute(window, attribute: kAXSizeAttribute),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGPoint(
            x: position.x + min(max(size.width / 2, 24), max(size.width - 24, 1)),
            y: position.y + min(max(12, 1), max(size.height - 1, 1))
        )
    }

    private func copyCGPointAttribute(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = (value as! AXValue)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func copyCGSizeAttribute(_ element: AXUIElement, attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = (value as! AXValue)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}
