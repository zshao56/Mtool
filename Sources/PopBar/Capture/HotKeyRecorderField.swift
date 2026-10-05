import SwiftUI
import AppKit
import Carbon.HIToolbox   // cmdKey/shiftKey/optionKey/controlKey masks

/// A click-to-record shortcut field for a Carbon combo (⌥Space, ⌘⇧S …).
///
/// This field records ONE thing: a key plus at least one real modifier (⌘/⌥/⌃).
/// The modifier-only double-tap gesture has its own recorder below, precisely so
/// the two cannot be confused — a plain combo recording must never be mistaken
/// for a double-tap and vice versa.
struct HotKeyRecorderField: View {
    /// Nil shows a "click to record" prompt — a hotkey with no default (the popup one).
    let combo: KeyCombo?
    /// Called with the newly recorded combo. The parent persists it and may reject it
    /// (e.g. the combo is already taken) — this view just reports intent.
    let onRecorded: (KeyCombo) -> Void
    let onBeginRecording: () -> UUID
    let onEndRecording: (UUID) -> Void

    @State private var isRecording = false
    @State private var timedOut = false
    @State private var keyMonitor: Any?
    @State private var recordingToken: UUID?
    @State private var recordingWindow: NSWindow?
    @State private var timeoutWork: DispatchWorkItem?

    init(combo: KeyCombo?,
         onBeginRecording: @escaping () -> UUID,
         onEndRecording: @escaping (UUID) -> Void,
         onRecorded: @escaping (KeyCombo) -> Void) {
        self.combo = combo
        self.onBeginRecording = onBeginRecording
        self.onEndRecording = onEndRecording
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
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
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
        keyMonitor = nil
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

/// A click-to-record field for a modifier-only double-tap gesture.
///
/// It cannot share `HotKeyRecorderField`'s Carbon path: `RegisterEventHotKey`
/// masks cannot tell the left Command from the right one, so the side is read
/// from the `flagsChanged` key code instead (see `PhysicalModifierDoubleTapDetector`).
/// While recording, the controller suspends the real trigger, so performing the
/// gesture here cannot also fire the shortcut in the background.
struct ModifierDoubleTapRecorderField: View {
    let key: ModifierTapKey
    let threshold: TimeInterval
    let onRecorded: (ModifierTapKey) -> Void
    let onBeginRecording: () -> UUID
    let onEndRecording: (UUID) -> Void

    @State private var isRecording = false
    @State private var timedOut = false
    @State private var flagsMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var recordingToken: UUID?
    @State private var recordingWindow: NSWindow?
    @State private var timeoutWork: DispatchWorkItem?
    /// Reference storage keeps the detector across SwiftUI updates.
    @State private var recorder = LocalModifierTapRecorder()

    init(key: ModifierTapKey,
         threshold: TimeInterval,
         onBeginRecording: @escaping () -> UUID,
         onEndRecording: @escaping (UUID) -> Void,
         onRecorded: @escaping (ModifierTapKey) -> Void) {
        self.key = key
        self.threshold = threshold
        self.onBeginRecording = onBeginRecording
        self.onEndRecording = onEndRecording
        self.onRecorded = onRecorded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isRecording { stopRecording() } else { startRecording() }
            } label: {
                Text(isRecording ? L("mtool.keyboard.doubleCommand.key.recording") : L(key.localizationKey))
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

    private static let recordingTimeout: TimeInterval = 15

    private func startRecording() {
        guard !isRecording, flagsMonitor == nil else { return }
        timedOut = false
        recordingWindow = NSApp.keyWindow
        recordingToken = onBeginRecording()
        recorder.reset(threshold: threshold)
        isRecording = true
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
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

    private func stopRecording() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        isRecording = false
        recordingWindow = nil
        if let id = recordingToken {
            recordingToken = nil
            onEndRecording(id)
        }
    }

    private func completeRecording(_ action: () -> Void) {
        let id = recordingToken
        recordingToken = nil
        stopRecording()
        action()
        if let id { onEndRecording(id) }
    }

    /// A non-modifier key means the user is typing, not tapping a modifier.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 { stopRecording() }
        recorder.reset(threshold: threshold)
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        if FocusedInputInspector.isSecureInputActive() {
            recorder.reset(threshold: threshold)
            return nil
        }
        let flags = event.modifierFlags
        if let detected = recorder.handle(
            keyCode: event.keyCode,
            commandDown: flags.contains(.command),
            optionDown: flags.contains(.option),
            shiftDown: flags.contains(.shift),
            controlDown: flags.contains(.control),
            at: ProcessInfo.processInfo.systemUptime
        ) {
            completeRecording { onRecorded(detected) }
        }
        return nil
    }
}

/// Class wrapper so the recorder's value-type state survives SwiftUI view rebuilds.
private final class LocalModifierTapRecorder {
    private var recorder = ModifierDoubleTapRecorder()

    func reset(threshold: TimeInterval) { recorder.reset(threshold: threshold) }

    func handle(keyCode: UInt16, commandDown: Bool, optionDown: Bool,
                shiftDown: Bool, controlDown: Bool, at time: TimeInterval) -> ModifierTapKey? {
        recorder.handle(keyCode: keyCode, commandDown: commandDown, optionDown: optionDown,
                        shiftDown: shiftDown, controlDown: controlDown, at: time)
    }
}
