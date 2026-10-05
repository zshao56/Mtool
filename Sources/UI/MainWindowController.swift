import Cocoa
import SwiftUI

// MARK: - MainWindowController
//
// Hosts the SwiftUI settings UI in a single window with a native sidebar.
// Closing hides the window rather than terminating: this is a menu-bar app, and
// the popup has to keep working after you close the settings.
final class MainWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState

        let root = MainView().environmentObject(appState)
        let hosting = NSHostingController(rootView: root)

        window = NSWindow(contentViewController: hosting)
        window.title = Brand.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 860, height: 600))
        // Keyed off the bundle id rather than the name, so the remembered position
        // survives a rename.
        window.setFrameAutosaveName("\(Brand.baseID).main")
        window.center()
        super.init()
        window.delegate = self
    }

    func show() {
        // ORDER MATTERS on macOS 14+ (cooperative activation): order the window
        // front FIRST, then activate the app. The other way round routinely leaves
        // the window BEHIND the previously-frontmost app, because the system defers
        // the activation while the order-front has already run.
        //
        // Deliberately NOT `orderFrontRegardless`: that fronts the window without
        // keying it (only the ACTIVE app can own a key window), which breaks text
        // field focus app-wide — keystrokes leak to the previously-active app.
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileLog("MainWindow").debug("window shown — windowNumber=\(self.window.windowNumber)")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }
}

// MARK: - Root view

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selection) {
                ForEach(SettingsPage.Block.allCases, id: \.rawValue) { block in
                    Section {
                        ForEach(SettingsPage.block(block)) { page in
                            row(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Pin the sidebar to a FIXED width (min == max). Without this, dragging
            // the window narrow makes the split view squeeze the sidebar and clip
            // the labels — only the detail area may resize.
            .navigationSplitViewColumnWidth(212)
            .safeAreaInset(edge: .top, spacing: 0) { brand }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter(store: appState.store) }
        } detail: {
            detail
                .accessibilityIdentifier(appState.selection.axID)
                .environment(\.defaultMinListRowHeight, 34)
                .scrollContentBackground(.hidden)
                .auroraBackground()
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: toggleSidebar) { Image(systemName: "sidebar.leading") }
                            .help(L("nav.toggleSidebar"))
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 540)
        // Re-key the whole tree on an in-app language change so every label
        // re-reads. `selection` lives on the store, so it survives the rebuild.
        .id(appState.languageRevision)
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .general:    GeneralPage(store: appState.store, openOnboarding: appState.showOnboarding)
        case .actions:    ActionsPage(actions: appState.actions, llm: appState.llm)
        case .history:    HistoryPage()
        case .advanced:   AdvancedPage(store: appState.store)
        case .keyboard:   KeyboardPage(store: appState.mtool)
        case .ocr:        OCRPage(store: appState.store)
        case .clipboard:  ClipboardPage(store: appState.mtool)
        case .models:     ModelsPage(settings: appState.llm.settings)
        case .speech:     SpeechSettingsView()
        case .about:      AboutPage()
        }
    }

    private func row(_ page: SettingsPage) -> some View {
        HStack(spacing: 9) {
            SidebarIcon(symbol: page.symbol, color: page.color)
            Text(page.title)
        }
        .padding(.vertical, 2)
        .tag(page)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nav.\(page.axID)")
    }

    private var brand: some View {
        HStack(spacing: 10) {
            // Pre-scaled to exactly 34pt (AppLogo34): letting SwiftUI shrink the
            // 1024px master at draw time leaves jagged edges at this size.
            Image("AppLogo34")
                .accessibilityHidden(true) // the app name sits right next to it
            VStack(alignment: .leading, spacing: 1) {
                Text(Brand.name).font(.system(size: 14, weight: .bold))
                Text(verbatim: "v\(Brand.version)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }
        // The logo artwork carries ~3.3pt of transparent margin inside its 34pt
        // frame; 12.5 instead of 16 puts its visible edge on the same line as
        // the row icons below (measured on a 2x screenshot: both at 16pt from
        // the window edge).
        .padding(.leading, 12.5).padding(.trailing, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}

/// The line under the sidebar: whether the popup is running, with the switch
/// that pauses it — or, while the Accessibility permission is missing, only that
/// warning, since a switch cannot help until it is granted.
///
/// It sits under the navigation rather than on a page because it is about the
/// whole app, and because a pause has to be visible from every page: a paused
/// app looks exactly like a working one otherwise.
///
/// Its own view because it observes the popup's store, which the root view does
/// not: without that, it would keep whatever it said when the window opened.
private struct StatusFooter: View {
    @ObservedObject var store: PopBarStore

    /// Paused with the popup hotkey on, the popup still opens — the status says
    /// how, or a paused app that pops up would look broken.
    private var statusText: String {
        if store.popupEnabled { return L("popbar.status.running") }
        if store.popupHotKeyRegistered, let combo = store.popupHotKey {
            return String(format: L("popbar.status.pausedHotKey.format"), combo.display)
        }
        return L("popbar.status.paused")
    }

    var body: some View {
        if !store.isTrusted {
            HStack(spacing: 7) {
                StatusDot(active: false)
                Text(L("popbar.status.needsPermission"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        } else {
            HStack(spacing: 7) {
                Circle()
                    .fill(store.popupEnabled ? Color.green : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 9, height: 9)
                    .frame(width: 12, height: 12)
                Text(statusText)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                PauseButton(paused: !store.popupEnabled) {
                    store.setPopupEnabled(!store.popupEnabled)
                }
            }
            // Trailing inset is smaller so the button's glyph, not its hover box,
            // lines up with the sidebar rows; vertical is smaller because the
            // 22pt box is taller than the text.
            .padding(.leading, 16).padding(.trailing, 11).padding(.vertical, 4)
        }
    }
}

/// Borderless pause / play icon button: pause while running, play while paused.
/// The whole 22pt box is clickable and highlights on hover, not just the glyph.
private struct PauseButton: View {
    let paused: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let label = String(format: L(paused ? "menu.resume.format" : "menu.pause.format"), Brand.name)
        Button(action: action) {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("status.pauseButton")
    }
}
