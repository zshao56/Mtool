import SwiftUI
import AppKit
import Carbon.HIToolbox   // cmdKey/shiftKey/optionKey/controlKey masks

/// A click-to-record shortcut field. The controller suspends its Carbon hotkeys
/// during recording so the local monitor can see an existing shortcut again.
struct HotKeyRecorderField: View {
    /// Nil shows a "click to record" prompt — a hotkey with no default (the popup one).
    let combo: KeyCombo?
    /// Called with the newly recorded combo. The parent persists it and may reject it
    /// (e.g. the combo is already taken) — this view just reports intent.
    let onRecorded: (KeyCombo) -> Void
    let onBeginRecording: () -> UUID
    let onEndRecording: (UUID) -> Void
    let onDoubleCommandRecorded: (() -> Void)?
    let doubleCommandThreshold: TimeInterval

    @State private var isRecording = false
    @State private var timedOut = false
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var recordingToken: UUID?
    @State private var recordingWindow: NSWindow?
    @State private var timeoutWork: DispatchWorkItem?
    @State private var doubleDetector = LocalDoubleCommandDetector()

    init(combo: KeyCombo?,
         onBeginRecording: @escaping () -> UUID,
         onEndRecording: @escaping (UUID) -> Void,
         onDoubleCommandRecorded: (() -> Void)? = nil,
         doubleCommandThreshold: TimeInterval = ModifierDoubleTapDetector.defaultThreshold,
         onRecorded: @escaping (KeyCombo) -> Void) {
        self.combo = combo
        self.onBeginRecording = onBeginRecording
        self.onEndRecording = onEndRecording
        self.onDoubleCommandRecorded = onDoubleCommandRecorded
        self.doubleCommandThreshold = doubleCommandThreshold
        self.onRecorded = onRecorded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isRecording { stopRecording() } else { startRecording() }
            } label: {
                Text(isRecording ? L("popbar.ocr.hotkey.recording") : combo?.display ?? L("popbar.hotkey.record"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                    .frame(minWidth: 100)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .overlay(
                        Capsule().strokeBorder(isRecording ? Color.accentColor
                                                            : Color.primary.opacity(0.15))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if timedOut {
                Text(L("mtool.keyboard.record.timeout"))
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard isRecording else { return }
            if let window = recordingWindow {
                if note.object as? NSWindow === window { stopRecording() }
            } else {
                stopRecording()
            }
        }
    }

    // MARK: - Recording lifecycle

    private static let recordingTimeout: TimeInterval = 15

    private func startRecording() {
        guard !isRecording, keyMonitor == nil else { return }
        timedOut = false
        recordingWindow = NSApp.keyWindow
        recordingToken = onBeginRecording()
        doubleDetector.reset(threshold: doubleCommandThreshold)
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
        if onDoubleCommandRecorded != nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                handleFlagsChanged(event)
            }
        }
        let id = recordingToken
        let work = DispatchWorkItem {
            guard isRecording, recordingToken == id else { return }
            timedOut = true
            stopRecording()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordingTimeout, execute: work)
    }

    /// Tears down the local monitor and leaves recording state. Safe to call repeatedly.
    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        isRecording = false
        recordingWindow = nil
        if let id = recordingToken {
            recordingToken = nil
            onEndRecording(id)
        }
    }

    /// Keep the controller's hotkeys suspended until the candidate is persisted.
    private func completeRecording(_ action: () -> Void) {
        let id = recordingToken
        recordingToken = nil
        stopRecording()
        action()
        if let id { onEndRecording(id) }
    }

    /// Handles a key-down while recording. Returns nil to swallow the event.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let mask = carbonModifiers(from: event.modifierFlags)

        // Esc with no modifiers cancels recording.
        if event.keyCode == 53 && mask == 0 {
            stopRecording()
            return nil
        }

        doubleDetector.cancelForOtherKey()

        // Require a "real" modifier (⌘/⌥/⌃); ignore bare keys and shift-only so plain
        // typing isn't captured. Keep waiting (swallow) until one arrives.
        let flags = event.modifierFlags
        let hasRealModifier = flags.contains(.command)
            || flags.contains(.option)
            || flags.contains(.control)
        guard hasRealModifier else { return nil }

        let recorded = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mask)
        completeRecording { onRecorded(recorded) }
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        guard onDoubleCommandRecorded != nil else { return event }
        if FocusedInputInspector.isSecureInputActive() {
            doubleDetector.reset(threshold: doubleCommandThreshold)
            return nil
        }
        let flags = event.modifierFlags
        let commandDown = flags.contains(.command)
        let otherModifiers = flags.contains(.shift) || flags.contains(.option) || flags.contains(.control)
        if doubleDetector.handleFlags(commandDown: commandDown, otherModifiers: otherModifiers, at: ProcessInfo.processInfo.systemUptime) {
            completeRecording { onDoubleCommandRecorded?() }
        }
        return nil
    }

    /// Maps AppKit modifier flags to the Carbon mask used by `KeyCombo`.
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}

/// Reference storage keeps the four modifier transitions together across SwiftUI updates.
private final class LocalDoubleCommandDetector {
    private var detector = ModifierDoubleTapDetector()

    func reset(threshold: TimeInterval) {
        detector = ModifierDoubleTapDetector(threshold: threshold)
    }

    func cancelForOtherKey() {
        detector.handle(.otherKeyDown, at: ProcessInfo.processInfo.systemUptime)
    }

    func handleFlags(commandDown: Bool, otherModifiers: Bool, at time: TimeInterval) -> Bool {
        detector.handleFlags(commandDown: commandDown, otherModifiers: otherModifiers, at: time)
    }
}
