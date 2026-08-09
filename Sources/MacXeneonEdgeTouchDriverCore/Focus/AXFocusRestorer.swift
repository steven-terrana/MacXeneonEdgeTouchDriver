import ApplicationServices
import CoreGraphics
import Foundation

/// Restores focus to the exact AX window that was focused before a touch gesture.
public final class AXFocusRestorer: FocusRestorer {
    private struct CapturedWindow {
        let application: AXUIElement
        let window: AXUIElement
    }

    /// Cap for every AX call so an unresponsive app cannot stall the gesture queue.
    private static let messagingTimeoutSeconds: Float = 0.15

    private let systemWideElement: AXUIElement
    private var capturedWindow: CapturedWindow?

    public init(systemWideElement: AXUIElement = AXUIElementCreateSystemWide()) {
        self.systemWideElement = systemWideElement
        AXUIElementSetMessagingTimeout(systemWideElement, Self.messagingTimeoutSeconds)
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

        AXUIElementSetMessagingTimeout(application, Self.messagingTimeoutSeconds)
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeoutSeconds)
        capturedWindow = CapturedWindow(application: application, window: window)
    }

    public func restoreCapturedWindow() {
        guard let capturedWindow else {
            return
        }
        self.capturedWindow = nil
        let restoreStart = DispatchTime.now()
        var didVerifyRestore = false
        var stage = "fast-path"
        defer {
            DriverMetrics.recordFocusRestore(
                durationUs: DriverMetrics.microseconds(since: restoreStart),
                verified: didVerifyRestore,
                stage: stage
            )
        }

        // Fast path: if focus never left the captured window (common when the
        // tap landed on the Xeneon display without changing key window), or a
        // single attribute set restores it, skip the expensive escalation.
        if isWindowFocused(capturedWindow) {
            didVerifyRestore = true
            return
        }

        // Do not use app-level AXFrontmost here; it raises sibling windows from the same application.
        stage = "attr-set"
        let focusedWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFocusedWindowAttribute as CFString,
            capturedWindow.window
        )
        if isWindowFocused(capturedWindow) {
            didVerifyRestore = true
            return
        }

        // Escalation: full restore sequence for apps that ignore the simple set.
        stage = "full-sequence"
        let mainWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXMainWindowAttribute as CFString,
            capturedWindow.window
        )
        let raiseResult = AXUIElementPerformAction(capturedWindow.window, kAXRaiseAction as CFString)
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
        if isWindowFocused(capturedWindow) {
            didVerifyRestore = true
            return
        }

        // Last resort: synthetic title-bar click. Kept last because it can hit
        // toolbar controls in apps with unified title/toolbar areas.
        stage = "title-click"
        let sessionClickResult = clickCapturedWindowTitleBar(capturedWindow)
        let refocusedWindowResult = AXUIElementSetAttributeValue(
            capturedWindow.application,
            kAXFocusedWindowAttribute as CFString,
            capturedWindow.window
        )

        didVerifyRestore = isWindowFocused(capturedWindow)
        guard didVerifyRestore else {
            DriverLoggers.log(
                .warning,
                category: .focus,
                "Could not verify restore of the previously focused window. focusedWindow=\(focusedWindowResult.rawValue), mainWindow=\(mainWindowResult.rawValue), raise=\(raiseResult.rawValue), windowMain=\(mainResult.rawValue), windowFocused=\(focusedResult.rawValue), sessionClick=\(sessionClickResult), refocusedWindow=\(refocusedWindowResult.rawValue)."
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
        guard let focusedApplication = copyElementAttribute(systemWideElement, attribute: kAXFocusedApplicationAttribute),
              elementsMatch(focusedApplication, capturedWindow.application) else {
            return false
        }

        guard let focusedWindow = copyElementAttribute(capturedWindow.application, attribute: kAXFocusedWindowAttribute) else {
            return false
        }

        return elementsMatch(focusedWindow, capturedWindow.window)
    }

    /// Compares AX elements, falling back to pid equality for application
    /// elements because CFEqual can fail across separately copied tokens.
    private func elementsMatch(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) {
            return true
        }

        var lhsPid: pid_t = 0
        var rhsPid: pid_t = 0
        guard AXUIElementGetPid(lhs, &lhsPid) == .success,
              AXUIElementGetPid(rhs, &rhsPid) == .success else {
            return false
        }

        // Same pid alone is not sufficient for windows, but combined with the
        // focused-window comparison path it prevents spurious app mismatches.
        return lhsPid == rhsPid && CFHash(lhs) == CFHash(rhs)
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
