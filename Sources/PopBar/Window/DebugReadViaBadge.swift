#if DEBUG
import AppKit
import Combine
import SwiftUI

/// Debug builds only: a small label under the popup saying how the selection was
/// read — AX (asked the app), Clipboard (the app, or a program in it, copied
/// during the drag), ⌘C (pressed for the user).
///
/// Its own window, not part of the popup: it never takes a click
/// (`ignoresMouseEvents`), never changes the popup's size, and sits outside the
/// ring so the wheel stays readable.
final class DebugReadViaBadge {

    /// Switched in Settings → General → Diagnostics (debug builds only). Kept in
    /// the debug build's own UserDefaults, not the shared config file, so the
    /// release build never sees it. Default on.
    static let enabledKey = "debug.showReadViaBadge"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private let window: NSPanel
    private let model: PopBarPanelModel
    private var viaChange: AnyCancellable?

    init(model: PopBarPanelModel) {
        self.model = model
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 18),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        window.level = PopBarPanel.level
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.contentView = NSHostingView(rootView: BadgeView(model: model))
        // Growing the same selection in place can change how it was read without
        // the popup moving; re-fit the label around its current centre.
        viaChange = model.$readVia.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.window.isVisible else { return }
            let f = self.window.frame
            self.place(under: CGPoint(x: f.midX, y: f.maxY + 4))
        }
    }

    /// Put the label centred under `popupBottom` (screen coordinates: the popup's
    /// visible bottom edge and horizontal centre), or hide it when there is
    /// nothing to say.
    func place(under popupBottom: CGPoint) {
        guard Self.isEnabled, model.readVia != nil, let content = window.contentView else { hide(); return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        window.setContentSize(size)
        window.setFrameOrigin(CGPoint(x: (popupBottom.x - size.width / 2).rounded(),
                                      y: (popupBottom.y - 4 - size.height).rounded()))
        window.orderFront(nil)
    }

    func hide() { window.orderOut(nil) }

    private struct BadgeView: View {
        @ObservedObject var model: PopBarPanelModel

        var body: some View {
            Text(model.readVia.map(Self.label) ?? "")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .fixedSize()
        }

        static func label(_ via: SelectionStrategyID) -> String {
            switch via {
            case .accessibility: return "AX"
            case .copyOnSelect:  return "Clipboard"
            case .clipboardCopy: return "⌘C"
            case .appleScript:   return "AppleScript"
            case .menuAction:    return "Menu"
            }
        }
    }
}
#endif
