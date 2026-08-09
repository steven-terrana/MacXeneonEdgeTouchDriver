import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Production application wiring for the Xeneon Edge single-touch driver.
public final class MacXeneonEdgeTouchDriverApplication {
    private let configuration: DriverConfiguration
    private let displayResolver: DisplayResolver
    private let mapperStore = CoordinateMapperStore()
    private let gestureQueue = DispatchQueue(label: "\(DriverLoggers.subsystem).gesture-queue", qos: .userInteractive)
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorer: FocusRestorer

    private lazy var gestureController = GestureController(
        mapperProvider: { [mapperStore] in
            mapperStore.currentMapper
        },
        inputSink: inputSink,
        cursorController: cursorController,
        focusRestorer: focusRestorer,
        timing: GestureTiming(configuration: configuration.timing),
        schedulingQueue: gestureQueue
    )

    private lazy var hidMonitor = HIDDeviceMonitor(
        eventQueue: gestureQueue,
        seizeDevice: true,
        touchEventHandler: { [weak self] event in
            self?.enqueueTouchEvent(event)
        },
        deviceRemovalHandler: { [weak self] in
            self?.handleDeviceRemoval()
        },
        deviceMatchedHandler: { [weak self] in
            self?.handleDeviceMatched()
        }
    )

    private var stuckGestureTimer: DispatchSourceTimer?
    private var lastGestureEventTime: DispatchTime = .now()
    private let pendingMove = PendingMoveSlot()
    private var pendingDisplayRefresh: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var didRegisterDisplayCallback = false
    private var isRunning = false

    /// Creates a production application with CoreGraphics side effects.
    public convenience init(configuration: DriverConfiguration = .defaults) {
        self.init(
            configuration: configuration,
            displayResolver: DisplayResolver(configuration: configuration.display),
            inputSink: CGEventInputSink(),
            cursorController: CGCursorController(),
            focusRestorer: AXFocusRestorer()
        )
    }

    /// Creates an application with injectable side-effect dependencies.
    public init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer()
    ) {
        self.configuration = configuration
        self.displayResolver = displayResolver
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = focusRestorer
    }

    deinit {
        stop()
    }

    /// Starts the driver and runs the main CFRunLoop until stopped.
    public func run() -> Int32 {
        guard !isRunning else {
            return EXIT_SUCCESS
        }

        isRunning = true
        DriverLoggers.log(.notice, category: .lifecycle, "Starting Mac Xeneon Edge Touch Driver in single-touch mode.")
        gestureController.onBecameIdle = { [weak self] in
            self?.cancelStuckGestureTimer()
        }

        waitForSyntheticEventPermission()

        refreshDisplayMapping(reason: "startup")
        registerDisplayReconfigurationCallback()
        installSignalHandlers()

        do {
            try hidMonitor.start()
        } catch {
            DriverLoggers.log(.fault, category: .lifecycle, "Could not start HID monitor: \(error.localizedDescription)")
            stop()
            return EXIT_FAILURE
        }

        CFRunLoopRun()
        return EXIT_SUCCESS
    }

    /// Stops monitoring and restores cursor/input state.
    public func stop() {
        guard isRunning else {
            return
        }

        hidMonitor.stop()
        gestureQueue.sync {
            pendingDisplayRefresh?.cancel()
            pendingDisplayRefresh = nil
            cancelStuckGestureTimer()
            gestureController.forceCancel()
        }
        unregisterDisplayReconfigurationCallback()
        signalSources.removeAll()
        isRunning = false

        DriverLoggers.log(.notice, category: .lifecycle, "Stopped Mac Xeneon Edge Touch Driver.")
        CFRunLoopStop(CFRunLoopGetMain())
    }

    /// Coalesces reconfiguration callbacks: macOS fires one per display and
    /// again per phase, so a single hotplug produces a burst. One debounced
    /// refresh handles the whole burst once the configuration settles.
    fileprivate func handleDisplayReconfiguration() {
        gestureQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.pendingDisplayRefresh?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                self.pendingDisplayRefresh = nil
                self.refreshDisplayMapping(reason: "display reconfiguration")
            }
            self.pendingDisplayRefresh = workItem
            self.gestureQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
        }
    }

    private func refreshDisplayMapping(reason: String) {
        let refreshStart = DispatchTime.now()
        displayResolver.refresh()
        mapperStore.currentMapper = displayResolver.currentMapper
        DriverMetrics.recordDisplayRefresh(
            durationUs: DriverMetrics.microseconds(since: refreshStart),
            reason: reason
        )

        if let bounds = displayResolver.currentBounds {
            DriverLoggers.log(
                .notice,
                category: .display,
                "Resolved Xeneon Edge display after \(reason): x=\(bounds.origin.x), y=\(bounds.origin.y), width=\(bounds.width), height=\(bounds.height)."
            )
        } else {
            DriverLoggers.log(.error, category: .display, "Could not resolve Xeneon Edge display after \(reason). Touch events will be dropped.")
            gestureQueue.async { [weak self] in
                self?.cancelStuckGestureTimer()
                self?.gestureController.forceCancel()
            }
        }
    }

    /// Enqueues a touch event on the gesture queue, coalescing move events.
    ///
    /// Downs and ups are always dispatched in order. A move overwrites the
    /// pending-move slot instead of enqueuing when a move is already waiting,
    /// so a backlog never makes the cursor replay stale positions — each drain
    /// processes the newest position available.
    public func enqueueTouchEvent(_ event: TouchEvent) {
        guard event.kind == .move else {
            gestureQueue.async { [weak self] in
                self?.handleTouchEvent(event)
            }
            return
        }

        let hadPendingMove = pendingMove.replace(with: event)
        guard !hadPendingMove else {
            return
        }

        gestureQueue.async { [weak self] in
            guard let self, let move = self.pendingMove.take() else {
                return
            }
            self.handleTouchEvent(move)
        }
    }

    /// Blocks until all currently enqueued gesture work has been processed.
    public func drainGestureQueue() {
        gestureQueue.sync {}
    }

    func handleTouchEvent(_ event: TouchEvent) {
        if mapperStore.currentMapper == nil {
            refreshDisplayMapping(reason: "touch event without display mapper")
        }

        gestureController.handle(event)

        switch gestureController.state {
        case .idle:
            cancelStuckGestureTimer()

        case .singleTouch:
            lastGestureEventTime = DispatchTime.now()
            ensureStuckGestureTimer()
        }
    }

    func handleDeviceMatched() {
        refreshDisplayMapping(reason: "HID device match")
    }

    private func handleDeviceRemoval() {
        cancelStuckGestureTimer()
        gestureController.forceCancel()
    }

    /// Arms the stuck-gesture watchdog if not already armed.
    ///
    /// One timer is created per gesture rather than per event; move events at
    /// 100+ Hz only update `lastGestureEventTime`. When the timer fires it
    /// checks event recency and re-arms itself for the remainder, so cleanup
    /// still only happens after a full quiet timeout.
    private func ensureStuckGestureTimer() {
        guard stuckGestureTimer == nil else {
            return
        }

        armStuckGestureTimer(afterMs: configuration.timing.stuckGestureTimeoutMs)
    }

    private func armStuckGestureTimer(afterMs: Int) {
        let timer = DispatchSource.makeTimerSource(queue: gestureQueue)
        timer.schedule(deadline: .now() + .milliseconds(afterMs))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            self.stuckGestureTimer = nil

            let timeoutNs = UInt64(self.configuration.timing.stuckGestureTimeoutMs) * 1_000_000
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - self.lastGestureEventTime.uptimeNanoseconds
            if elapsedNs < timeoutNs {
                // Events arrived since arming; re-arm for the remaining window.
                let remainingMs = Int((timeoutNs - elapsedNs) / 1_000_000) + 1
                self.armStuckGestureTimer(afterMs: remainingMs)
                return
            }

            DriverLoggers.log(.warning, category: .gesture, "Touch gesture timed out without an up event; forcing cleanup.")
            self.gestureController.handleIdleTimeout()
        }
        timer.resume()
        stuckGestureTimer = timer
    }

    private func cancelStuckGestureTimer() {
        stuckGestureTimer?.setEventHandler {}
        stuckGestureTimer?.cancel()
        stuckGestureTimer = nil
    }

    private func registerDisplayReconfigurationCallback() {
        guard !didRegisterDisplayCallback else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)

        if result == .success {
            didRegisterDisplayCallback = true
        } else {
            DriverLoggers.log(.error, category: .display, "CGDisplayRegisterReconfigurationCallback failed with \(result.rawValue).")
        }
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard didRegisterDisplayCallback else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)

        if result != .success {
            DriverLoggers.log(.error, category: .display, "CGDisplayRemoveReconfigurationCallback failed with \(result.rawValue).")
        }
        didRegisterDisplayCallback = false
    }

    private func installSignalHandlers() {
        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            ignoreDefaultSignalAction(signalNumber)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                DriverLoggers.log(.notice, category: .lifecycle, "Received signal \(signalNumber); stopping driver.")
                self?.stop()
            }
            source.resume()
            return source
        }
    }

    /// Blocks until synthetic event permission is granted.
    ///
    /// Shows the OS permission prompt at most once per install, tracked by a
    /// marker file, then polls quietly. macOS queues rather than deduplicates
    /// TCC prompts, so any repeated prompting (e.g. across relaunches)
    /// accumulates a backlog of dialogs the user has to dismiss one by one.
    private func waitForSyntheticEventPermission() {
        if hasSyntheticEventPermission() {
            DriverLoggers.log(.notice, category: .lifecycle, "CoreGraphics post-event permission is granted.")
            return
        }

        logPermissionIdentity()
        DriverLoggers.log(.error, category: .lifecycle, "CoreGraphics post-event permission is not granted.")

        if shouldShowPermissionPrompt() {
            markPermissionPromptShown()
            DriverLoggers.log(.notice, category: .lifecycle, "Requesting permission; macOS will show a one-time prompt.")

            if CGRequestPostEventAccess() {
                DriverLoggers.log(.notice, category: .lifecycle, "CoreGraphics post-event permission was granted after request.")
                return
            }

            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(options) || hasSyntheticEventPermission() {
                DriverLoggers.log(.notice, category: .lifecycle, "Accessibility trust is granted after prompt.")
                return
            }
        }

        DriverLoggers.log(
            .fault,
            category: .lifecycle,
            "Synthetic mouse event permission is not granted. Waiting for Accessibility to be granted to the executable named in the previous log line; the driver will start automatically once it is."
        )

        var waitedSeconds = 0
        while !hasSyntheticEventPermission() {
            Thread.sleep(forTimeInterval: 2)
            waitedSeconds += 2
            if waitedSeconds % 60 == 0 {
                DriverLoggers.log(.notice, category: .lifecycle, "Still waiting for Accessibility permission (\(waitedSeconds)s).")
            }
        }

        DriverLoggers.log(.notice, category: .lifecycle, "Accessibility permission granted; starting driver.")
    }

    private func hasSyntheticEventPermission() -> Bool {
        CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }

    /// Marker file recording that this installed binary already showed the OS
    /// permission prompt. Removed by the installer when the binary changes.
    private static var permissionPromptMarkerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriver", isDirectory: true)
            .appendingPathComponent(".permission-prompt-shown", isDirectory: false)
    }

    private func shouldShowPermissionPrompt() -> Bool {
        !FileManager.default.fileExists(atPath: Self.permissionPromptMarkerURL.path)
    }

    private func markPermissionPromptShown() {
        let url = Self.permissionPromptMarkerURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    private func logPermissionIdentity() {
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "Unknown executable"
        let launcherPath = NSRunningApplication(processIdentifier: getppid())?.bundleURL?.path ?? "Unknown launcher"

        DriverLoggers.log(.error, category: .lifecycle, "Permission identity: executable=\(executablePath), launcher=\(launcherPath).")
    }

    private func ignoreDefaultSignalAction(_ signalNumber: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)

        if sigaction(signalNumber, &action, nil) != 0 {
            DriverLoggers.log(.error, category: .lifecycle, "sigaction failed for signal \(signalNumber).")
        }
    }
}

/// Lock-protected slot holding the newest undelivered move event.
private final class PendingMoveSlot {
    private let lock = NSLock()
    private var event: TouchEvent?

    /// Stores `event`, returning whether a move was already pending.
    func replace(with event: TouchEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hadPending = self.event != nil
        self.event = event
        return hadPending
    }

    /// Removes and returns the pending move, if any.
    func take() -> TouchEvent? {
        lock.lock()
        defer { lock.unlock() }
        let taken = event
        event = nil
        return taken
    }
}

private final class CoordinateMapperStore {
    private let lock = NSLock()
    private var storedMapper: CoordinateMapper?

    var currentMapper: CoordinateMapper? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedMapper
        }
        set {
            lock.lock()
            storedMapper = newValue
            lock.unlock()
        }
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard let context else {
        return
    }

    // The begin phase fires before the configuration actually changes;
    // refreshing then reads stale bounds. Wait for the completion callback.
    guard !flags.contains(.beginConfigurationFlag) else {
        return
    }

    let application = Unmanaged<MacXeneonEdgeTouchDriverApplication>.fromOpaque(context).takeUnretainedValue()
    application.handleDisplayReconfiguration()
}
