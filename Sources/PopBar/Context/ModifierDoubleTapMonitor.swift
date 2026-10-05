import AppKit

/// Watches the global `flagsChanged` (and `keyDown`) stream and reports a
/// completed double-tap Command. The decision itself lives in the pure
/// `ModifierDoubleTapDetector`; this class only translates real events into it.
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

    private var detector: ModifierDoubleTapDetector
    private var globalFlags: Any?
    private var globalKeys: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init(threshold: TimeInterval = ModifierDoubleTapDetector.defaultThreshold) {
        self.detector = ModifierDoubleTapDetector(threshold: threshold)
    }

    var isAvailable: Bool { isRunning }

    func setThreshold(_ threshold: TimeInterval) {
        detector.threshold = threshold
    }

    func start() {
        guard !isRunning else { return }
        guard AccessibilityAuthorizer.isTrusted else {
            Self.log.warn("no Accessibility permission — double-Command cannot be captured")
            onAvailabilityChanged?(false)
            return
        }

        globalFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // A non-modifier key means the user is typing, not double-tapping.
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.detector.handle(.otherKeyDown, at: ProcessInfo.processInfo.systemUptime)
        }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.detector.reset()
        })

        isRunning = globalFlags != nil
        Self.log.info("double-Command monitor \(self.isRunning ? "installed" : "unavailable (no event stream)")")
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
            detector.handle(.secureInputActive, at: ProcessInfo.processInfo.systemUptime)
            return
        }
        let flags = event.modifierFlags
        let commandDown = flags.contains(.command)
        let otherModifiers = flags.contains(.shift) || flags.contains(.option) || flags.contains(.control)
        let now = ProcessInfo.processInfo.systemUptime

        if detector.handleFlags(commandDown: commandDown, otherModifiers: otherModifiers, at: now) {
            Self.log.info("double-Command detected")
            onTriggered?()
        }
    }
}
