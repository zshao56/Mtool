import SwiftUI
import AppKit

/// Settings-facing view model for Mtool's own keyboard and clipboard options.
/// Bridges the SwiftUI pages to `PopBarController` and the `MtoolPreferences` /
/// `ClipboardPreferences` stores.
final class MtoolSettingsStore: ObservableObject {

    // Main shortcut
    @Published private(set) var mainHotKeyEnabled: Bool
    @Published private(set) var mainHotKey: KeyCombo
    @Published private(set) var mainHotKeyRegistered: Bool
    @Published private(set) var autoPopupOnSelect: Bool

    // Double Command
    @Published private(set) var doubleCommandEnabled: Bool
    @Published private(set) var doubleCommandAvailable: Bool
    @Published private(set) var doubleCommandThreshold: Double

    // Clipboard
    @Published private(set) var clipboardEnabled: Bool
    @Published private(set) var clipboardPaused: Bool
    @Published private(set) var maxItems: Double
    @Published private(set) var retentionDays: Double
    @Published private(set) var maxImageMB: Double
    @Published private(set) var excludedApps: [String]
    @Published private(set) var plainTextPaste: Bool
    @Published private(set) var clipboardCount: Int

    private let controller: PopBarController
    private let store: ClipboardStore

    init(controller: PopBarController, store: ClipboardStore) {
        self.controller = controller
        self.store = store
        self.mainHotKeyEnabled = MtoolPreferences.mainHotKeyEnabled
        self.mainHotKey = MtoolPreferences.mainHotKey
        self.mainHotKeyRegistered = controller.mainHotKeyIsRegistered
        self.autoPopupOnSelect = MtoolPreferences.autoPopupOnSelect
        self.doubleCommandEnabled = MtoolPreferences.doubleCommandEnabled
        self.doubleCommandAvailable = controller.doubleCommandAvailable
        self.doubleCommandThreshold = MtoolPreferences.doubleCommandThreshold * 1000
        self.clipboardEnabled = ClipboardPreferences.enabled
        self.clipboardPaused = ClipboardPreferences.paused
        self.maxItems = Double(ClipboardPreferences.policy.maxItems)
        self.retentionDays = Double(ClipboardPreferences.policy.retentionDays)
        self.maxImageMB = Double(ClipboardPreferences.policy.maxImageBytes) / 1024 / 1024
        self.excludedApps = ClipboardPreferences.excludedApps
        self.plainTextPaste = ClipboardPreferences.plainTextPaste
        self.clipboardCount = store.count()
    }

    func refresh() {
        controller.startDoubleCommandIfEnabled()
        let reg = controller.mainHotKeyIsRegistered
        if reg != mainHotKeyRegistered { mainHotKeyRegistered = reg }
        let avail = controller.doubleCommandAvailable
        if avail != doubleCommandAvailable { doubleCommandAvailable = avail }
        clipboardCount = store.count()
    }

    // MARK: - Main shortcut

    func beginHotKeyRecording() -> UUID { controller.beginHotKeyRecording() }

    func endHotKeyRecording(_ id: UUID) {
        controller.endHotKeyRecording(id)
        mainHotKeyRegistered = controller.mainHotKeyIsRegistered
    }

    @discardableResult
    func setMainHotKeyEnabled(_ on: Bool) -> Bool {
        mainHotKeyEnabled = on
        let ok = controller.setMainHotKeyEnabled(on)
        mainHotKeyRegistered = controller.mainHotKeyIsRegistered
        return ok
    }

    @discardableResult
    func setMainHotKey(_ combo: KeyCombo) -> Bool {
        let ok = controller.setMainHotKey(combo)
        if ok { mainHotKey = combo }
        mainHotKeyRegistered = controller.mainHotKeyIsRegistered
        return ok
    }

    func setAutoPopupOnSelect(_ on: Bool) {
        autoPopupOnSelect = on
        MtoolPreferences.autoPopupOnSelect = on
        if on {
            // The selection monitor has to be running for the auto-popup to work.
            controller.start()
        }
    }

    // MARK: - Double Command

    @discardableResult
    func setDoubleCommandEnabled(_ on: Bool) -> Bool {
        doubleCommandEnabled = on
        let ok = controller.setDoubleCommandEnabled(on)
        doubleCommandAvailable = controller.doubleCommandAvailable
        return ok
    }

    func setDoubleCommandThreshold(_ ms: Double) {
        doubleCommandThreshold = ms
        controller.setDoubleCommandThreshold(ms / 1000)
    }

    func openAccessibilitySettings() {
        AccessibilityAuthorizer.openSettings()
    }

    // MARK: - Clipboard

    func setClipboardEnabled(_ on: Bool) {
        clipboardEnabled = on
        ClipboardPreferences.enabled = on
        if on { controller.router.startClipboard() } else { controller.router.stopClipboard() }
    }

    func setClipboardPaused(_ on: Bool) {
        clipboardPaused = on
        ClipboardPreferences.paused = on
    }

    func setMaxItems(_ value: Double) {
        maxItems = value
        var policy = ClipboardPreferences.policy
        policy.maxItems = Int(value)
        ClipboardPreferences.policy = policy
        store.prune(policy: ClipboardPreferences.policy)
    }

    func setRetentionDays(_ value: Double) {
        retentionDays = value
        var policy = ClipboardPreferences.policy
        policy.retentionDays = Int(value)
        ClipboardPreferences.policy = policy
        store.prune(policy: ClipboardPreferences.policy)
    }

    func setMaxImageMB(_ value: Double) {
        maxImageMB = value
        var policy = ClipboardPreferences.policy
        policy.maxImageBytes = Int(value * 1024 * 1024)
        ClipboardPreferences.policy = policy
    }

    func setPlainTextPaste(_ on: Bool) {
        plainTextPaste = on
        ClipboardPreferences.plainTextPaste = on
    }

    func excludeApp(_ bundleID: String) {
        guard !bundleID.isEmpty, !excludedApps.contains(bundleID) else { return }
        excludedApps.append(bundleID)
        ClipboardPreferences.excludedApps = excludedApps
    }

    func includeApp(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
        ClipboardPreferences.excludedApps = excludedApps
    }

    func clearHistory() {
        store.clearHistory()
        store.prune(policy: ClipboardPreferences.policy)
        clipboardCount = 0
    }

    func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([ClipboardStore.shared.url])
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Brand.logDirectory])
    }
}
