import SwiftUI
import AppKit
import MarkdownUI

/// Drives what the capsule shows. The panel/controller mutate `phase`; the view
/// re-renders. Kept separate from the controller so the view is previewable.
final class PopBarPanelModel: ObservableObject {
    enum Phase: Equatable {
        case actions
        case loading
        case result(String)
    }

    @Published var phase: Phase = .actions
    /// Whether the capsule is pinned open (ignores auto-dismiss).
    @Published var isPinned = false
    /// Whether the result panel auto-grows its height to fit the content (issue
    /// #12). When false (default), the result keeps its fixed compact size. Seeded
    /// from `PopBarPreferences` and kept in sync so an already-open panel honors a
    /// toggle change. Width is always fixed regardless of this flag.
    @Published var autoExpandHeight = PopBarPreferences.autoExpandHeight
    /// The base font size for the result Markdown (issue #14). Seeded from
    /// `PopBarPreferences` and re-seeded on each show + on a live settings change so
    /// an already-open result re-renders at the new size. Headings/code scale as
    /// relative `.em(...)` multiples off this.
    @Published var resultFontSize: Double = PopBarPreferences.resultFontSize
    @Published var readingHighlight: ReadingHighlightStyle = PopBarPreferences.readingHighlight
    /// The height the result scroll area should use when auto-expand is ON. The
    /// panel computes this (clamping the view's measured content height against the
    /// popup's own screen — issue #12) and pushes it here; the view applies it.
    /// `nil` means "not yet measured" → fall back to the fixed height.
    @Published var resultContentHeight: CGFloat?

    /// Reports the result content's natural (unclamped) height as SwiftUI measures
    /// it. Wired by the panel, which knows the popup's screen and does the clamping
    /// + window re-fit. This is the single trigger for auto-expand re-fits, so it
    /// covers streaming deltas, one-shot results, and error results alike.
    var onMeasuredContentHeight: ((CGFloat) -> Void)?
    /// Live text shown by the result panel. Kept separate from `phase` so streaming
    /// tokens can update the text WITHOUT re-entering `.result` (which would trigger
    /// a full window re-fit on every token). The result frame is fixed, so the
    /// window stays put; only this string changes as deltas arrive.
    @Published var streamingText = ""

    /// Buttons to show (set by the controller from the user's ActionStore).
    var actions: [PopBarActionConfig] = []

    /// Live bridge from the wheel to the panel's AppKit hit-test, so the clickable
    /// region grows while a submenu ring is unfolded. Owned here because both the
    /// SwiftUI wheel (writer) and the hosting view (reader) can reach the model.
    let wheelHitRegion = WheelHitRegion()

    /// Which presentation the action row uses (capsule bar vs radial wheel). Seeded
    /// from `PopBarPreferences` on each show; only the `.actions` phase differs —
    /// loading/result chrome is shared. `@Published` so flipping it re-renders.
    @Published var style: PopBarStyle = .liquidGlass
    /// Geometry for the wheel presentation (ignored by the capsule). `@Published` so a
    /// live settings change (dragging the radius sliders) re-renders the showing wheel.
    @Published var wheelLayout = WheelLayout()
    /// Auto-hide the ring when the pointer leaves it (wheel + liquid-glass only;
    /// the capsule ignores it). Seeded from prefs on each show.
    var autoHideOnExitRing = false
    /// Whether the 3D style carves a groove between slices. Seeded on each show.
    @Published var donutDividers = false
    /// Whether the liquid style draws dividers between slices. Seeded on each show.
    @Published var liquidDividers = false
    /// Capsule icon / caption point sizes. Seeded on each show; `@Published` so a
    /// settings slider re-renders the showing preview.
    @Published var capsuleIconSize = PopBarPreferences.capsuleIconSizeDefault
    @Published var capsuleLabelSize = PopBarPreferences.capsuleLabelSizeDefault
    /// Capsule: draw the very thin outline. Seeded on each show.
    @Published var capsuleBorder = true
    /// Set only for the preview in the Appearance settings: the 3D ring is drawn
    /// in the page itself rather than in a window of its own (see `DonutInlineLayer`).
    var drawsDonutInline = false

    /// Read how the popup looks from the preferences: the style, the selected
    /// ring's geometry, the capsule's sizes and both styles' dividers. The one
    /// place this is read, for a real popup and the settings preview alike.
    func loadAppearance() {
        style = PopBarPreferences.style
        let ring = PopBarPreferences.ring(style)   // this ring style's own knobs
        wheelLayout = ring.layout   // user-adjustable radii + icon/label toggles
        autoHideOnExitRing = ring.autoHideOnExit   // wheel: hide when pointer leaves the ring
        capsuleIconSize = PopBarPreferences.capsuleIconSize
        capsuleLabelSize = PopBarPreferences.capsuleLabelSize
        capsuleBorder = PopBarPreferences.capsuleBorder
        donutDividers = PopBarPreferences.wheelDonutDividers
        liquidDividers = PopBarPreferences.wheelLiquidDividers
    }

    /// Wired by the controller.
    var onAction: ((PopBarActionConfig) -> Void)?
    /// Capsule only: the pointer came to rest on a GROUP's button (or it was
    /// clicked) — open its dropdown under `rect`, the button's frame in the
    /// hosting view's top-left-origin coordinates. Wired by the panel.
    var onGroupHover: ((PopBarActionConfig, CGRect) -> Void)?
    /// Capsule only: the pointer left the button of the group with this id.
    var onGroupHoverEnd: ((String) -> Void)?
    /// Capsule only: the pointer is on an ordinary action — any open dropdown
    /// closes at once, as a menu bar's does.
    var onPlainHover: (() -> Void)?
    /// Fired when the pointer leaves the ring (wheel styles) and auto-hide is on.
    var onExitRing: (() -> Void)?
    var onCopyResult: ((String) -> Void)?
    /// Put the result in place of the selection (the Replace button).
    var onReplaceResult: ((String) -> Void)?
    /// Whether the selection this popup acts on can be replaced — decides whether
    /// the Replace button is offered at all (see `SelectionSource.canReplace`).
    @Published var canReplace = false
    /// How the selection was read. Debug builds show it under the popup
    /// (`DebugReadViaBadge`).
    @Published var readVia: SelectionStrategyID?
    /// Whether the text in the result panel is a FINISHED result an action
    /// produced — not an error message, and not an answer still streaming in.
    /// Only that is offered for Replace.
    @Published var resultIsFinalOutput = false
    /// A one-line note under the toolbar, e.g. why a result could not be put back.
    /// Cleared whenever the popup shows something new.
    @Published var notice: String?
    /// What a `compare` result shows besides the result itself: the selection
    /// and the result with their changes marked (issue #12). nil for any other
    /// result, and while the result is still streaming in.
    @Published var comparison: TextDiff.Comparison?
    /// Whether a comparison is shown as such or as the result alone. Seeded from
    /// `PopBarPreferences` on each show; the switch in the panel sets both.
    @Published var compareView: CompareView = PopBarPreferences.compareView
    var onClose: (() -> Void)?
    var onTogglePin: (() -> Void)?

    /// The read-aloud shown in the result panel's place (a Speak action), or nil.
    /// Set together with `.result`, so the window sizes and places exactly as a
    /// result does.
    @Published var reading: SpeechPlayback?

    /// Push a streaming delta into the live result text (no phase change → no re-fit).
    func updateStreamingText(_ text: String) { streamingText = text }
}

/// The capsule's content: a row of action buttons that transitions to a loading
/// spinner and then a result panel for AI actions.
///
/// Visual crispness: the rounded corners + hairline border are masked at the
/// layer level inside `VisualEffectBlur` and the drop shadow is the panel's
/// native window shadow — not a SwiftUI `.shadow` over a transparent window,
/// which is what produces fuzzy/feathered edges.
struct PopBarContentView: View {

    @ObservedObject var model: PopBarPanelModel

    private let cornerRadius: CGFloat = 11

    /// The result content area's fixed width (always) and its fixed height when
    /// auto-expand is OFF (today's behavior — issue #7). Widened +50% in issue #14.
    private let resultWidth: CGFloat = 450
    private let resultFixedHeight: CGFloat = 130

    var body: some View {
        Group {
            if case .actions = model.phase, model.style.isWheel {
                // Both wheel styles bring their own circular backdrop, so they skip the
                // rounded-rect glass the capsule/loading/result share. `.liquidGlass`
                // is the same wheel with the bright Liquid Glass skin.
                WheelActionsView(actions: model.actions, layout: model.wheelLayout,
                                 skin: wheelSkin,
                                 autoHideOnExit: model.autoHideOnExitRing,
                                 liquidDividers: model.liquidDividers,
                                 drawsDonutInline: model.drawsDonutInline,
                                 hitRegion: model.wheelHitRegion,
                                 onExitRing: { model.onExitRing?() }) { action in
                    model.onAction?(action)
                }
            } else {
                content
                    .background(panelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .fixedSize()
    }

    /// The wheel skin for the current style. The 3D ring falls back to the liquid
    /// skin on a Mac where Metal could not be set up, rather than drawing nothing.
    private var wheelSkin: WheelSkin {
        switch model.style {
        case .liquidGlass: return .liquid
        case .donut: return DonutSupport.isAvailable ? .donut(dividers: model.donutDividers) : .liquid
        case .capsule: return .liquid   // never shown: the capsule has no ring
        }
    }

    /// Everything sits on Liquid Glass, like the Liquid ring. The capsule's action
    /// bar takes the ring's treatment exactly: no outline and no window shadow (see
    /// `PopBarPanel.updateWheelChrome`), and the same dark scrim in dark mode.
    @ViewBuilder
    private var panelBackground: some View {
        if case .actions = model.phase {
            LiquidBarBackground(cornerRadius: cornerRadius, bordered: model.capsuleBorder)
        } else {
            GlassPanelBackground(cornerRadius: cornerRadius)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .actions:
            actionsBar
        case .loading:
            loadingBar
        case .result:
            if let reading = model.reading {
                ReadingPanelView(playback: reading, model: model,
                                 width: resultWidth, fixedHeight: resultFixedHeight)
            } else {
                // Text comes from the live `streamingText`, not the phase payload, so
                // streaming deltas update in place without re-fitting the window.
                resultPanel(model.streamingText)
            }
        }
    }

    // MARK: - Actions row

    private var actionsBar: some View {
        // A group is one button; resting on it opens its dropdown (issue #3), the
        // capsule's counterpart of the wheel's second ring.
        let row = model.actions
        return HStack(spacing: 2) {
            ForEach(Array(row.enumerated()), id: \.element.id) { index, action in
                if index > 0 { separator }
                CapsuleActionButton(action: action, model: model,
                                    iconSize: model.capsuleIconSize, labelSize: model.capsuleLabelSize)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    /// The same hairline as the Liquid ring's dividers, scaled with the buttons.
    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 0.75, height: model.capsuleIconSize * 1.2 + model.capsuleLabelSize * 0.9)
    }

    // MARK: - Loading

    private var loadingBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("popbar.loading")).font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Result

    private func resultPanel(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Unified chrome toolbar: pin · copy · close all share one button style.
            HStack(spacing: 4) {
                ChromeButton(symbol: model.isPinned ? "pin.fill" : "pin",
                             help: L(model.isPinned ? "popbar.unpin" : "popbar.pin"),
                             active: model.isPinned) { model.onTogglePin?() }
                if model.comparison != nil {
                    Picker("", selection: Binding(
                        get: { model.compareView },
                        set: { model.compareView = $0; PopBarPreferences.compareView = $0 })) {
                        ForEach(CompareView.allCases, id: \.self) { view in
                            Text(L("popbar.compare.view.\(view.rawValue)")).tag(view)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                Spacer()
                if model.canReplace, model.resultIsFinalOutput, !text.isEmpty,
                   model.comparison?.isUnchanged != true {
                    ChromeButton(symbol: "arrow.2.squarepath", help: L("popbar.replace.result")) {
                        model.onReplaceResult?(text)
                    }
                }
                CopyButton { model.onCopyResult?(text) }
                ChromeButton(symbol: "xmark", help: L("popbar.close")) {
                    model.onClose?()
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: resultWidth, alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    // Measure the WHOLE scroll content — the rendered Markdown AND the
                    // bottom scroll anchor — as one stack. Measuring only the Markdown
                    // (as before) left the 1pt anchor out of the reported height, so the
                    // scroll frame we sized to it came out 1pt shorter than the actual
                    // content. That constant 1px overflow forced a scrollbar on EVERY
                    // result, however short — verified at the AppKit layer (documentView
                    // 1pt taller than the clip view). Measuring the stack as a whole makes
                    // the reported height == the real content, so frame == content.
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.topAnchor)
                        if let comparison = model.comparison, model.compareView == .diff {
                            ComparisonView(comparison: comparison, fontSize: model.resultFontSize)
                        } else if text.isEmpty {
                            // Pre-first-token: a quiet placeholder so the chrome is
                            // visible immediately without a blank void.
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L("popbar.loading")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        } else {
                            // Render the (possibly partial) streaming text as live
                            // Markdown. MarkdownUI parses best-effort, so an unclosed
                            // code fence or half-written list during streaming degrades
                            // gracefully instead of crashing. The copy button still
                            // copies the RAW `text`, not this rendered view.
                            Markdown(text)
                                .markdownTheme(Theme.popBar(baseSize: model.resultFontSize))
                                // The result is untrusted LLM output. MarkdownUI's
                                // default provider would auto-fetch any `![](http…)`
                                // image, so a prompt-injected response could make us
                                // issue arbitrary network requests (tracking pixel /
                                // SSRF) just by being displayed. Render nothing for
                                // images instead.
                                .markdownImageProvider(NoRemoteImageProvider())
                                .textSelection(.enabled)
                        }
                        // Anchor used to keep the view pinned to the bottom as text grows.
                        // Kept INSIDE the measured stack so its 1pt counts toward the
                        // reported height (otherwise the frame is 1pt too short).
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Report this full content height so the panel can size the frame to
                    // fit it exactly when auto-expand is ON. The probe sits in a
                    // background so it never affects layout; it only reports a size.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ResultContentHeightKey.self,
                                                   value: geo.size.height)
                        }
                    )
                }
                .frame(width: resultWidth, height: resultHeight)
                // Report the measured natural height to the panel (it clamps against
                // the popup's screen + re-fits the window). This is what makes a
                // one-shot/error result grow too, not just streaming deltas.
                .onPreferenceChange(ResultContentHeightKey.self) { model.onMeasuredContentHeight?($0) }
                .onChange(of: text) { _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
                // A comparison is read from the top, unlike a streaming answer
                // followed at its bottom — so is the result it switches to.
                // Animated like the scroll to the bottom above, so when a quick
                // comparison lands while that one is still moving, this one takes
                // over instead of being overtaken by it.
                .onChange(of: model.comparison) { _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                }
                .onChange(of: model.compareView) { _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
        .padding(ResultTextStyle.insets)
    }

    /// The result scroll area's height. OFF (default): exactly today's fixed
    /// `resultFixedHeight`. ON: the panel-computed clamped height (which already
    /// accounts for the popup's screen + min/max), falling back to the fixed height
    /// until the first measurement lands — beyond the cap the content scrolls.
    private var resultHeight: CGFloat {
        guard model.autoExpandHeight else { return resultFixedHeight }
        return model.resultContentHeight ?? resultFixedHeight
    }

    private static let bottomAnchor = "popbar.result.bottom"
    private static let topAnchor = "popbar.result.top"
}

// MARK: - Comparison

/// A `compare` result (issue #12): the selection, dimmed, with what the result
/// no longer has marked in red, above the result with what it added marked in
/// green. Plain text, not Markdown — this is exactly what Replace writes.
private struct ComparisonView: View {
    let comparison: TextDiff.Comparison
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(L("popbar.compare.original"))
            Text(attributed(comparison.original, mark: .removed))
                .opacity(0.78)
            Divider().padding(.vertical, 4)
            caption(L("popbar.compare.revised"))
            Text(attributed(comparison.revised, mark: .added))
        }
        .font(.system(size: fontSize))
        .lineSpacing(fontSize * ResultTextStyle.lineSpacingEm)
        .foregroundStyle(Color.primary.opacity(ResultTextStyle.inkOpacity))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 6)
    }

    private enum Mark { case removed, added }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func attributed(_ segments: [TextDiff.Segment], mark: Mark) -> AttributedString {
        var out = AttributedString()
        for segment in Self.trimmingEnds(segments) {
            var run = AttributedString(segment.text)
            if segment.changed {
                switch mark {
                case .removed:
                    run.foregroundColor = Color(nsColor: .systemRed)
                    run.backgroundColor = Color(nsColor: .systemRed).opacity(0.16)
                case .added:
                    run.backgroundColor = Color(nsColor: .systemGreen).opacity(0.26)
                }
            }
            out += run
        }
        return out
    }

    /// The segments without whitespace at the very start and end. A selection
    /// made by triple-clicking ends in a line break, which would otherwise draw
    /// as an empty line under the original and push the divider down.
    static func trimmingEnds(_ segments: [TextDiff.Segment]) -> [TextDiff.Segment] {
        var out = segments
        while let first = out.first {
            let text = String(first.text.drop(while: \.isWhitespace))
            if text.isEmpty { out.removeFirst() } else { out[0].text = text; break }
        }
        while let last = out.last {
            var text = last.text
            while text.last?.isWhitespace == true { text.removeLast() }
            if text.isEmpty { out.removeLast() } else { out[out.count - 1].text = text; break }
        }
        return out
    }
}

/// Reports the result content's natural height up to the parent so the panel can
/// size to fit it when auto-expand is ON. Takes the max of reported values within
/// a layout pass (only one probe exists, so this is effectively a pass-through).
struct ResultContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Markdown image provider

/// Renders nothing for Markdown images. The PopBar result is untrusted LLM
/// output, so we must NOT let MarkdownUI's default provider auto-fetch remote
/// images (a prompt-injected `![](https://tracker/pixel)` would otherwise turn
/// merely displaying the result into an arbitrary network request).
private struct NoRemoteImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { EmptyView() }
}

// MARK: - Markdown theme

private extension Theme {
    /// A compact Markdown theme tuned for the PopBar result panel: tight vertical
    /// margins and modest heading sizes so the popup stays dense and readable in
    /// both light & dark. Colors use system semantic styles so they adapt to
    /// appearance automatically. The body uses `baseSize` (a user setting — issue
    /// #14) and headings/code scale off it as relative `.em(...)` multiples, so the
    /// whole result scales together when the user changes the font size.
    static func popBar(baseSize: CGFloat) -> Theme {
        Theme()
        .text {
            FontSize(baseSize)
            ForegroundColor(Color.primary.opacity(ResultTextStyle.inkOpacity))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color.primary.opacity(0.07))
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(ResultTextStyle.lineSpacingEm))
                .markdownMargin(top: 0, bottom: 6)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.4))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.25))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 5, bottom: 3)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.12))
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                configuration.label
                    .padding(.leading, 8)
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
            }
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(8)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .markdownMargin(top: 4, bottom: 6)
        }
    }
}

/// A single capsule action button: icon over a tiny caption. The WHOLE tile
/// hit-tests (`.contentShape(Rectangle())`), not just the glyph.
///
/// Marked the way the Liquid ring marks a slice: no fill behind the hovered
/// button, its icon and name take the brand gradient instead.
private struct CapsuleActionButton: View {
    let action: PopBarActionConfig
    let model: PopBarPanelModel
    let iconSize: Double
    let labelSize: Double
    @State private var hovering = false
    /// This button's frame in the hosting view, kept current so a group's
    /// dropdown can be placed under it.
    @State private var frame: CGRect = .zero

    private var isGroup: Bool { action.hasChildren }

    /// The tile grows with its contents. At the default sizes (15 / 9) it is the
    /// 52 × 40 tile the bar always had.
    private var tileWidth: CGFloat { 52 * max(iconSize / 15, labelSize / 9) }
    private var iconSlot: CGFloat { iconSize * 1.2 }
    private var tileHeight: CGFloat { iconSlot + 3 + labelSize * 1.25 + 7.75 }

    var body: some View {
        Button {
            if isGroup { model.onGroupHover?(action, frame) } else { model.onAction?(action) }
        } label: {
            VStack(spacing: 3) {
                // Fixed-height icon slot. SF Symbols have different glyph bounding
                // boxes (magnifyingglass vs lightbulb vs "Aa"/textformat), so a
                // plain centered VStack let a taller icon push BOTH itself up and
                // the caption down — the "高低不一" the bar showed. Pinning the
                // icon's vertical band keeps every icon at the same position and
                // every caption on the same baseline, independent of the glyph.
                Image(systemName: action.iconSymbol)
                    .font(.system(size: iconSize, weight: .medium))
                    .frame(height: iconSlot)
                HStack(spacing: 2) {
                    Text(action.title)
                        .font(.system(size: labelSize, weight: hovering ? .semibold : .medium))
                        .lineLimit(1)
                    // Marks a group: it opens a dropdown rather than running.
                    if isGroup {
                        Image(systemName: "chevron.down")
                            .font(.system(size: labelSize * 0.67, weight: .bold))
                            .opacity(0.7)
                    }
                }
            }
            .foregroundStyle(LiquidInk.glyph(hot: hovering))
            .frame(width: tileWidth, height: tileHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { newFrame in
                    frame = newFrame
                    // The pointer can already be resting on a group when the bar
                    // appears, before its frame was known — open it now, since no
                    // new hover event will come.
                    if hovering, isGroup, newFrame != .zero { model.onGroupHover?(action, newFrame) }
                }
        })
        .onHover { inside in
            hovering = inside
            if isGroup {
                if inside { model.onGroupHover?(action, frame) } else { model.onGroupHoverEnd?(action.id) }
            } else if inside {
                model.onPlainHover?()
            }
        }
        // A group's name is on the button already, and a tooltip would sit on
        // top of its dropdown.
        .help(isGroup ? "" : action.title)
    }
}

/// The Liquid style's ink, shared by the ring and the capsule so the two match:
/// dark navy (light mode) or near-white (dark mode) at rest, the app icon's
/// gradient when hovered.
///
/// Dark mode is read from the raw OS setting rather than the view's colour
/// scheme; see `WheelActionsView.isDark` for why.
enum LiquidInk {
    static var isDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// The app icon's own gradient (`scripts/make-icon.py`: #2563EB above, #06B6D4
    /// below, leaning slightly right). Lifted a step in dark mode so it reads on the
    /// dark glass.
    static func brandColors(dark: Bool = isDark) -> (top: Color, bottom: Color) {
        dark
            ? (Color(red: 0.376, green: 0.647, blue: 0.980), Color(red: 0.133, green: 0.827, blue: 0.933))   // #60A5FA → #22D3EE
            : (Color(red: 0.145, green: 0.388, blue: 0.922), Color(red: 0.024, green: 0.714, blue: 0.831))   // #2563EB → #06B6D4
    }

    static func brandGradient(dark: Bool = isDark) -> LinearGradient {
        let c = brandColors(dark: dark)
        return LinearGradient(colors: [c.top, c.bottom], startPoint: .top, endPoint: UnitPoint(x: 0.35, y: 1))
    }

    static func glyph(hot: Bool, dark: Bool = isDark) -> AnyShapeStyle {
        if hot { return AnyShapeStyle(brandGradient(dark: dark)) }
        return AnyShapeStyle(dark ? Color.white.opacity(0.92) : Color(red: 0.17, green: 0.21, blue: 0.27))
    }
}

/// The capsule bar's (and its dropdown's) backdrop: the Liquid ring's material on
/// a rounded rectangle — system Liquid Glass with no outline, plus the ring's dark
/// scrim in dark mode so light glyphs read on any backdrop. Older systems get the
/// frost, also without an outline.
struct LiquidBarBackground: View {
    var cornerRadius: CGFloat
    /// The optional very thin outline (`capsule.border`): a 0.5 pt line, faint
    /// enough to sit with the ring's hairline dividers rather than frame the bar.
    var bordered = false

    var body: some View {
        ZStack {
            GlassPanelBackground(cornerRadius: cornerRadius, bordered: false)
            if LiquidInk.isDark {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .allowsHitTesting(false)
            }
            if bordered {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LiquidInk.isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12),
                                  lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Copy, shared by the result panel and the reading window: copies, shows a
/// check for a moment, and leaves the window open.
struct CopyButton: View {
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        ChromeButton(symbol: copied ? "checkmark" : "doc.on.doc", help: L("popbar.copy.result")) {
            copy()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
    }
}

/// The one small icon button used for pin / copy / close, so they all read as a
/// single family. Whole frame hit-tests; subtle hover + active states.
struct ChromeButton: View {
    let symbol: String
    let help: String
    var active: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.15)
                                     : (hovering ? Color.primary.opacity(0.10) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// How result text is set, shared by the text result and the reading window so
/// the two stay alike: ink a little softer than pure black/white, and roomier
/// lines — about 1.45× the font size, the usual range for short UI reading
/// (articles run 1.6–1.8×; system UI text ~1.25×). Dense black text on glass
/// read as bold; 1.6× (tried first) looked too loose for a popup.
enum ResultTextStyle {
    static let inkOpacity = 0.88
    /// Extra space between lines, as a fraction of the font size (the fonts'
    /// own line height is about 1.18×).
    static let lineSpacingEm = 0.27
    /// Space around the panel's content. The toolbar buttons are 24×22 with an
    /// ~11 pt glyph, so they already sit ~6 pt inside this.
    static let insets = EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8)
}

/// The result panel's backdrop: macOS 26 Liquid Glass (the same material as
/// the wheel), or the frosted blur on older systems and toolchains.
///
/// AppKit's `NSGlassEffectView` rather than SwiftUI's `.glassEffect`: the panel
/// is dragged by its background, which only works when the view under the
/// mouse says `mouseDownCanMoveWindow`. SwiftUI's glass puts in a view that
/// refuses, and the panel stopped moving (2026-09-29).
struct GlassPanelBackground: View {
    var cornerRadius: CGFloat
    /// The pre-macOS-26 frost's hairline outline. Liquid Glass has none either way.
    var bordered: Bool = true

    var body: some View {
        // `NSGlassEffectView` only exists in the macOS 26 SDK, so it is gated at
        // compile time as well as at run time (see WheelActionsView).
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            DraggableGlass(cornerRadius: cornerRadius)
        } else {
            VisualEffectBlur(cornerRadius: cornerRadius, bordered: bordered)
        }
        #else
        VisualEffectBlur(cornerRadius: cornerRadius, bordered: bordered)
        #endif
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private struct DraggableGlass: NSViewRepresentable {
    var cornerRadius: CGFloat

    final class GlassView: NSGlassEffectView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> GlassView {
        let view = GlassView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: GlassView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}
#endif

/// `NSVisualEffectView` blur, with rounded corners + a hairline border masked at
/// the layer level so the edge is crisp (no SwiftUI-shadow feathering). Reused by
/// the wheel presentation (`bordered: false`, then SwiftUI-masked to a ring).
struct VisualEffectBlur: NSViewRepresentable {
    var cornerRadius: CGFloat
    /// The wheel masks this to an annulus, so a rectangular border would just leave
    /// stray clipped edges — it turns the border off.
    var bordered: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = bordered ? 0.5 : 0
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.layer?.borderWidth = bordered ? 0.5 : 0
        nsView.layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
