import AppKit

/// Watches the global `flagsChanged` (and `keyDown`) stream and reports a
/// completed double-tap of the configured physical modifier.
///
/// The decision itself lives in the pure `PhysicalModifierDoubleTapDetector` /
/// `ModifierDoubleTapDetector`; this class only translates real events into them.
/// The exact side matters here and is read from the event's key code — see the
/// note on `PhysicalModifierDoubleTapDetector` about Carbon's left/right limit.
///
/// Important limitation, stated plainly: a global `flagsChanged` monitor only
/// receives events when the app has Accessibility (or Input Monitoring)
/// permission. If macOS does not deliver them, the feature is reported as
/// unavailable rather than pretending it works. `onAvailabilityChanged` says so.
final class ModifierDoubleTapMonitor {

    private static let log = FileLog("DoubleCommand")

    /// Called on the main thread when a double-tap completes.
    var onTriggered: (() -> Void)?
    /// Called on the main thread when the monitor's availability changes
    /// (monitor installed / removed). The settings UI shows it.
    var onAvailabilityChanged: ((Bool) -> Void)?

    private var detector: PhysicalModifierDoubleTapDetector
    private var globalFlags: Any?
    private var globalKeys: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    /// The physical modifier being watched. `.anyCommand` is the legacy default.
    var key: ModifierTapKey { detector.key }

    init(key: ModifierTapKey = .anyCommand,
         threshold: TimeInterval = ModifierDoubleTapDetector.defaultThreshold) {
        detector = PhysicalModifierDoubleTapDetector(key: key, threshold: threshold)
    }

    var isAvailable: Bool { isRunning }

    /// Change which side is watched. Resets any gesture in flight, so switching
    /// mid-gesture cannot complete against the new key.
    func setKey(_ key: ModifierTapKey) {
        guard key != detector.key else { return }
        detector = PhysicalModifierDoubleTapDetector(key: key, threshold: detector.threshold)
    }

    func setThreshold(_ threshold: TimeInterval) {
        detector.threshold = threshold
    }

    func start() {
        guard !isRunning else { return }
        guard AccessibilityAuthorizer.isTrusted else {
            Self.log.warn("no Accessibility permission — double-tap trigger cannot be captured")
            onAvailabilityChanged?(false)
            return
        }

        globalFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // A non-modifier key means the user is typing, not double-tapping.
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.detector.reset()
        }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.detector.reset()
        })

        isRunning = globalFlags != nil
        Self.log.info("double-tap monitor \(self.isRunning ? "installed" : "unavailable (no event stream)") for \(self.key.rawValue)")
        onAvailabilityChanged?(isRunning)
    }

    func stop() {
        if let globalFlags { NSEvent.removeMonitor(globalFlags) }
        if let globalKeys { NSEvent.removeMonitor(globalKeys) }
        globalFlags = nil
        globalKeys = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        detector.reset()
        if isRunning {
            isRunning = false
            onAvailabilityChanged?(false)
        }
    }

    deinit { stop() }

    // MARK: - Event translation

    private func handleFlagsChanged(_ event: NSEvent) {
        // Secure input (a password prompt) must never be observed.
        if FocusedInputInspector.isSecureInputActive() {
            detector.reset()
            return
        }
        let flags = event.modifierFlags
        let now = ProcessInfo.processInfo.systemUptime
        let completed = detector.handle(
            keyCode: event.keyCode,
            commandDown: flags.contains(.command),
            optionDown: flags.contains(.option),
            shiftDown: flags.contains(.shift),
            controlDown: flags.contains(.control),
            at: now
        )
        if completed {
            Self.log.info("double-tap \(self.key.rawValue) detected")
            onTriggered?()
        }
    }
}
