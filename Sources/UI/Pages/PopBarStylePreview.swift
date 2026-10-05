import SwiftUI

/// The live preview on the General page: the real popup — the same
/// `PopBarContentView` a selection pops up — drawn on a band of backdrop, so
/// every style and every slider below shows here as it is changed.
///
/// What it deliberately does NOT take from the user:
/// - their actions. It shows the default set, so a long personal list cannot
///   crowd the preview, and it reads the same for everyone.
/// - clicks. Hover works (slices light up, groups unfold, the 3D ring leans), but
///   nothing runs: the model has no action handler wired.
/// - auto-hide. Leaving the ring must not make the preview vanish.
///
/// The capsule's group dropdown is normally a window of its own, which the panel
/// opens (`CapsuleSubmenu`); here the same dropdown view is drawn in the page.
struct PopBarStylePreview: View {

    @ObservedObject var store: PopBarStore
    @StateObject private var model: PopBarPanelModel
    @StateObject private var dropdown: PreviewDropdown
    /// The ring reads dark mode once per build, so a system switch rebuilds it.
    @Environment(\.colorScheme) private var colorScheme

    /// Space kept clear between the popup's widest reach and the band's edges.
    private let margin: CGFloat = 12
    /// The band's height: the default ring with a group unfolded fits at its real
    /// size. It runs the full width of the section, however wide the window is.
    private let height: CGFloat = 440

    init(store: PopBarStore) {
        self.store = store
        // Filled before the first frame: an empty model would draw one frame of an
        // empty Liquid ring (and, for 3D Glass, its floating window) before
        // `onAppear` corrected it.
        _model = StateObject(wrappedValue: {
            let m = PopBarPanelModel()
            m.drawsDonutInline = true
            m.actions = DefaultActions.seed()
            Self.load(m)
            return m
        }())
        _dropdown = StateObject(wrappedValue: PreviewDropdown())
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Image("PopBarPreviewBackdrop")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                PopBarContentView(model: model)
                    // A fresh popup per style and per appearance, as a real one is.
                    .id("\(model.style.rawValue)-\(colorScheme == .dark)")
                    .scaleEffect(scale(for: size))
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                // Under its group's button, as the real one opens (the bar sits in
                // the middle of the band, so there is always room below).
                if let open = dropdown.open, !model.style.isWheel {
                    let origin = geo.frame(in: .global).origin
                    CapsuleSubmenuView(items: open.group.children, model: dropdown.menu)
                        .offset(x: open.button.minX - origin.x,
                                y: open.button.maxY - origin.y + CapsuleSubmenu.gap)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        // The store publishes BEFORE it writes the preference, so read a turn later.
        .onReceive(store.objectWillChange) { DispatchQueue.main.async { Self.load(model) } }
        .onAppear { dropdown.attach(to: model) }
        .onChange(of: model.style) { _ in dropdown.close() }
    }

    /// The preferences, minus what the preview overrides: it never hides itself.
    private static func load(_ m: PopBarPanelModel) {
        m.loadAppearance()
        m.autoHideOnExitRing = false
        m.phase = .actions
    }

    /// 1 whenever the popup fits, which it does at the default sizes; shrunk only
    /// when the sliders are pushed far enough that its widest reach would not.
    private func scale(for size: CGSize) -> CGFloat {
        // A ring needs its reach both ways; the capsule bar only across.
        let room = (model.style.isWheel ? min(size.width, size.height) : size.width) - margin * 2
        guard room > 0, reach > 0 else { return 1 }
        return min(1, room / reach)
    }

    /// The popup's widest extent, in points.
    private var reach: CGFloat {
        if model.style.isWheel {
            // The open second ring is the farthest anything is drawn.
            return model.wheelLayout.submenuOuterRadius * 2
        }
        // The capsule bar: its tiles (see `CapsuleActionButton.tileWidth`), the
        // hairlines between them and its padding.
        let n = CGFloat(model.actions.count)
        let tile = 52 * max(model.capsuleIconSize / 15, model.capsuleLabelSize / 9)
        return n * tile + max(n - 1, 0) * 4.75 + 12
    }
}

/// The capsule's group dropdown, for the preview: opened by resting on a group's
/// button, kept open while the pointer is on the button or the dropdown, closed
/// a moment after it leaves both — the timing `CapsuleSubmenu` uses. Picking an
/// item does nothing, like everything else in the preview.
final class PreviewDropdown: ObservableObject {
    struct Open { let group: PopBarActionConfig; let button: CGRect }

    @Published private(set) var open: Open?
    let menu = CapsuleSubmenuModel()
    private var closeWork: DispatchWorkItem?

    init() {
        menu.onHover = { [weak self] inside in
            if inside { self?.cancelClose() } else { self?.scheduleClose() }
        }
    }

    func attach(to model: PopBarPanelModel) {
        model.onGroupHover = { [weak self] group, rect in
            guard let self, !group.children.isEmpty, rect != .zero else { return }
            self.cancelClose()
            if self.open?.group.id != group.id { self.menu.highlighted = nil }
            self.open = Open(group: group, button: rect)
        }
        model.onGroupHoverEnd = { [weak self] id in
            guard let self, self.open?.group.id == id else { return }
            self.scheduleClose()
        }
        model.onPlainHover = { [weak self] in self?.close() }
    }

    func close() {
        cancelClose()
        open = nil
        menu.highlighted = nil
    }

    private func scheduleClose() {
        cancelClose()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CapsuleSubmenu.closeDelay, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }
}
