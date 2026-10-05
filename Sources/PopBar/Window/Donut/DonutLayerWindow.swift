import AppKit
import SwiftUI

/// Shows `content` in a borderless child window that lies exactly under this view
/// and IGNORES THE MOUSE — so nothing in it can ever take a click.
///
/// Why the 3D ring needs this: the window server treats every pixel of a Metal
/// drawable, and of a SwiftUI `drawingGroup`, as the window's own for clicks — even
/// where it is fully transparent (measured: a transparent MTKView or drawingGroup in
/// a clear panel swallowed a click that a plain transparent view let through). Drawn
/// in the popup itself, the donut would make its whole square, the hole included,
/// deaf to the app underneath. Drawn here, below the popup, it is only a picture;
/// the popup keeps nothing but the near-invisible ring it already uses to receive
/// clicks (`WheelActionsView.interactiveSurface`), exactly like the flat styles.
///
/// A child window moves, hides and re-shows with its parent (also measured), so the
/// popup's own show/hide/drag logic needs no changes.
struct DonutLayerWindow<Content: View>: NSViewRepresentable {
    /// The appearance the drawing is made in. System materials (the Liquid Glass
    /// under the glass donut) follow it: left to inherit a dark system, the glass
    /// itself turned grey over a light page.
    var appearance: NSAppearance?
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
        let a = Anchor()
        a.coordinator = context.coordinator
        context.coordinator.hosting.rootView = AnyView(content)
        return a
    }

    func updateNSView(_ a: Anchor, context: Context) {
        let c = context.coordinator
        if c.window.appearance != appearance { c.window.appearance = appearance }
        c.hosting.rootView = AnyView(content)
        a.sync()
    }

    static func dismantleNSView(_ a: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        let window: NSWindow
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        private var observers: [NSObjectProtocol] = []

        init() {
            let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.contentView = hosting
            hosting.sizingOptions = []   // this window's size comes from the anchor, never from SwiftUI
            window = w
        }

        func attach(to parent: NSWindow) {
            guard window.parent !== parent else { return }
            detach()
            window.collectionBehavior = parent.collectionBehavior
            parent.addChildWindow(window, ordered: .below)
            // Moving or resizing the popup moves this view on screen without re-running
            // SwiftUI. A child window is meant to follow its parent by itself, but not
            // when the parent is repositioned while hidden — which is exactly how the
            // popup is shown at a new spot (measured: the ring stayed where the popup
            // had been created). So follow explicitly.
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    // queue nil = delivered synchronously, while the popup is still
                    // being placed; on `.main` it would run a turn later, after the
                    // popup had already been shown with the ring at its old spot.
                    forName: name, object: parent, queue: nil) { [weak self] _ in
                        self?.onParentChange?()
                    })
            }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }

        var onParentChange: (() -> Void)?

        deinit { detach() }
    }

    /// The placeholder inside the popup: invisible, never hit, and the thing whose
    /// screen rectangle the child window copies.
    final class Anchor: NSView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let c = coordinator else { return }
            if let w = window {
                c.onParentChange = { [weak self] in self?.sync() }
                c.attach(to: w)
                sync()
            } else {
                c.detach()
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            sync()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            sync()
        }

        func sync() {
            // Before SwiftUI's first layout the anchor is 0×0: nothing to copy yet.
            guard let c = coordinator, let w = window, !bounds.isEmpty else { return }
            if c.window.parent == nil { c.attach(to: w) }
            let r = w.convertToScreen(convert(bounds, to: nil))
            if c.window.frame != r { c.window.setFrame(r, display: false) }
        }
    }
}

/// The same drawing as `DonutLayerWindow`, but as an ordinary subview — for the
/// ring drawn inside the settings page, where nothing is meant to be clicked and
/// a separate window would not scroll or clip with the page.
///
/// Hosted in its own `NSHostingView` so it can carry the same pinned appearance
/// the child window has (the glass under the donut goes grey when it inherits a
/// dark page), and it never takes the mouse either: the wheel's hover surface,
/// drawn on top of it, still sees the pointer.
struct DonutInlineLayer<Content: View>: NSViewRepresentable {
    var appearance: NSAppearance?
    let content: Content

    final class Host: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host(rootView: AnyView(content))
        host.sizingOptions = []   // sized by SwiftUI's frame, never from its content
        host.appearance = appearance
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        if host.appearance != appearance { host.appearance = appearance }
        host.rootView = AnyView(content)
    }
}
