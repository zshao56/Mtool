import AppKit
import SwiftUI

/// The dropdown a GROUP opens in the capsule style — the capsule's counterpart
/// of the wheel's second ring (issue #3).
///
/// It opens as soon as the pointer rests on the group's button (no click), just
/// below the bar and aligned to that button, and flips above the bar when the
/// screen has no room below. It is drawn by us, in the capsule's own frosted
/// material, not an `NSMenu`: a system menu would take over event handling
/// (tracking loop, its own look) inside a panel that must never take focus.
///
/// It is a separate child window rather than part of the capsule's panel: the
/// capsule is sized to its row and placed relative to the selection, and a
/// dropdown hanging out of it would have to grow that window and every
/// placement rule with it. As a child window it moves with the capsule and
/// orders above it for free.
///
/// Main thread only.
final class CapsuleSubmenu {

    static let rowHeight: CGFloat = 28
    /// Gap between the bar and the dropdown.
    static let gap: CGFloat = 4
    /// How long the pointer may be outside both the group button and the
    /// dropdown before it closes — long enough to cross the gap between them.
    static let closeDelay: TimeInterval = 0.25

    private let model = CapsuleSubmenuModel()
    private let panel: NSPanel
    private let hosting: FirstClickHostingView<CapsuleSubmenuView>
    private var closeWork: DispatchWorkItem?

    /// The group whose dropdown is open, if any.
    private(set) var openGroupID: String?

    /// An item was chosen.
    var onPick: ((PopBarActionConfig) -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = PopBarPanel.level
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // like the bar it hangs from: no window-shadow rim
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        hosting = FirstClickHostingView(rootView: CapsuleSubmenuView(items: [], model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        model.onPick = { [weak self] action in
            self?.close()
            self?.onPick?(action)
        }
        model.onHover = { [weak self] inside in
            if inside { self?.cancelClose() } else { self?.scheduleClose() }
        }
    }

    /// Open (or switch to) `group`'s dropdown under `button`, a rect in screen
    /// coordinates, attached to `parent`.
    func open(_ group: PopBarActionConfig, under button: NSRect, barFrame: NSRect, parent: NSWindow) {
        cancelClose()
        guard !group.children.isEmpty else { close(); return }
        if openGroupID == group.id, panel.isVisible { return }
        openGroupID = group.id
        model.highlighted = nil

        // The items go in as the view's own value, not through the observable
        // model: a published change reaches SwiftUI on a later pass, so measuring
        // right after it would size the window for the PREVIOUS items. A new
        // root view is laid out when it is measured.
        hosting.rootView = CapsuleSubmenuView(items: group.children, model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)

        let screen = parent.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        // Below the bar if it fits, otherwise above it.
        var origin = CGPoint(x: button.minX, y: barFrame.minY - Self.gap - size.height)
        if origin.y < visible.minY { origin.y = barFrame.maxY + Self.gap }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrameOrigin(origin)

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    /// The pointer left a group button (`leaving`) or the dropdown (nil): close
    /// unless it arrives in the dropdown or back on the group within
    /// `closeDelay`. Leaving a group whose dropdown is NOT the open one is
    /// ignored — moving from one group straight onto the next can report the
    /// first one's exit after the second one's entry.
    func scheduleClose(leaving groupID: String? = nil) {
        guard let open = openGroupID else { return }
        if let groupID, groupID != open { return }
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }

    func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    func close() {
        cancelClose()
        openGroupID = nil
        model.highlighted = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// What the dropdown shows. Separate from the capsule's model so opening it
/// never re-renders (or re-fits) the bar.
final class CapsuleSubmenuModel: ObservableObject {
    @Published var highlighted: String?
    var onPick: ((PopBarActionConfig) -> Void)?
    /// Pointer entered (true) or left (false) the dropdown.
    var onHover: ((Bool) -> Void)?
}

struct CapsuleSubmenuView: View {
    let items: [PopBarActionConfig]
    @ObservedObject var model: CapsuleSubmenuModel

    // No scroll view, on purpose: rows inside an `NSScrollView` are hit-tested
    // to AppKit subviews that do not accept the first click, and in a window
    // that never becomes key the first click on an item would be swallowed.
    // A group long enough to need scrolling is better split into two groups.
    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(5)
        .frame(minWidth: 150, maxWidth: 260)
        .fixedSize()
        .background(LiquidBarBackground(cornerRadius: 10, bordered: PopBarPreferences.capsuleBorder))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { model.onHover?($0) }
    }

    private func row(_ item: PopBarActionConfig) -> some View {
        Button { model.onPick?(item) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.iconSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(item.title.isEmpty ? L("popbar.action.untitled") : item.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            // Marked like the bar: no fill, the icon and name take the brand gradient.
            .foregroundStyle(LiquidInk.glyph(hot: model.highlighted == item.id))
            .padding(.horizontal, 8)
            .frame(height: CapsuleSubmenu.rowHeight)
            // The whole row is the target, not just the icon and the text.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.highlighted = item.id } else if model.highlighted == item.id { model.highlighted = nil }
        }
    }
}

/// Accepts the first click, so an item runs on a single click even though the
/// dropdown's window never becomes key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
