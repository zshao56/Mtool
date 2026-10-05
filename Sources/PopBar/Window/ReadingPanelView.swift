import SwiftUI

/// The reading window: the whole text being read, with the word being spoken
/// highlighted and kept in view, and pause / replay / copy / close. Lives in the
/// popup's result panel, so it sizes, pins and closes exactly like a result.
/// Closing it stops the read.
struct ReadingPanelView: View {
    @ObservedObject var playback: SpeechPlayback
    @ObservedObject var model: PopBarPanelModel
    let width: CGFloat
    let fixedHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if ReadingStatus.hasContent(playback) {
                ReadingStatus(playback: playback, width: width)
            }
            ReadingText(playback: playback, width: width, height: height,
                        fontSize: model.resultFontSize, style: model.readingHighlight,
                        onMeasuredHeight: { model.onMeasuredContentHeight?($0) })
        }
        .padding(ResultTextStyle.insets)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ChromeButton(symbol: model.isPinned ? "pin.fill" : "pin",
                         help: L(model.isPinned ? "popbar.unpin" : "popbar.pin"),
                         active: model.isPinned) { model.onTogglePin?() }
            ReadingReaderLabel(playback: playback)
                .padding(.leading, 4)
            Spacer()
            ReadingPlaybackButtons(playback: playback)
            CopyButton { model.onCopyResult?(playback.text) }
            ChromeButton(symbol: "xmark", help: L("popbar.close")) { model.onClose?() }
        }
    }

    private var height: CGFloat {
        guard model.autoExpandHeight else { return max(fixedHeight, 160) }
        return model.resultContentHeight ?? max(fixedHeight, 160)
    }
}

// MARK: - Shared pieces
//
// The reading window is assembled from these, and so is the History page's
// replay of a read: the two must look and behave the same.

/// The reader's name and the short, passing states beside it (preparing, from
/// the cache) — in the toolbar, so the text below never moves when they come
/// and go.
struct ReadingReaderLabel: View {
    @ObservedObject var playback: SpeechPlayback

    var body: some View {
        HStack(spacing: 4) {
            Label(playback.reader.name, systemImage: "speaker.wave.2")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            switch playback.state {
            case .preparing:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(L("speech.preparing"))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            case .playing, .paused, .finished:
                if playback.fromCache {
                    Text("· " + L("speech.fromCache"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            default:
                EmptyView()
            }
        }
    }
}

/// Pause / resume while it reads, and read again from the start. Before a read
/// has started (shown before it is asked for), Play starts it.
struct ReadingPlaybackButtons: View {
    @ObservedObject var playback: SpeechPlayback

    var body: some View {
        HStack(spacing: 4) {
            switch playback.state {
            case .idle:
                ChromeButton(symbol: "play.fill", help: L("speech.play")) { SpeechCenter.shared.start(playback) }
            case .playing:
                ChromeButton(symbol: "pause.fill", help: L("speech.pause")) { playback.togglePause() }
            case .paused:
                ChromeButton(symbol: "play.fill", help: L("speech.resume")) { playback.togglePause() }
            default:
                EmptyView()
            }
            // Through the centre, so a read elsewhere (another popup, a preview,
            // the History page) stops rather than playing over this one.
            ChromeButton(symbol: "arrow.counterclockwise", help: L("speech.replay")) {
                SpeechCenter.shared.replay(playback)
            }
        }
    }
}

/// What stays for the whole read: a failure (with Retry) or the text being
/// cut short — known from the start, so it does not appear mid-read.
struct ReadingStatus: View {
    @ObservedObject var playback: SpeechPlayback
    /// A fixed width to lay out in; nil = the width offered.
    var width: CGFloat?

    /// Whether there is anything to show. Callers include the view only then,
    /// so an empty one never takes a slot (and a gap) in their stack.
    static func hasContent(_ playback: SpeechPlayback) -> Bool {
        if case .failed = playback.state { return true }
        return playback.wasTruncated
    }

    var body: some View {
        if case .failed(let message) = playback.state {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L("speech.retry")) { SpeechCenter.shared.start(playback) }
                    .controlSize(.small)
            }
            .frame(width: width)
        } else if playback.wasTruncated {
            Label(String(format: L("speech.truncated"), SpeechPlayback.maxCharacters), systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
        }
    }
}

/// The whole text being read, with the word being spoken highlighted and its
/// line kept in view.
struct ReadingText: View {
    @ObservedObject var playback: SpeechPlayback
    let width: CGFloat
    let height: CGFloat
    let fontSize: Double
    let style: ReadingHighlightStyle
    /// The text's natural height, for an owner that sizes to fit it.
    var onMeasuredHeight: ((CGFloat) -> Void)?

    /// Where each line of the text sits, to keep the one being read in view.
    @State private var lines = ReadingLines()

    /// The word highlighted before the current one, and a counter that ticks once
    /// per word. The renderer slides the pill from the previous word to the
    /// current one as the counter animates up by one.
    @State private var previousHighlight: NSRange?
    @State private var lastHighlight: NSRange?
    @State private var highlightStep: Double = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    textBody
                    Color.clear.frame(height: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the highlight's margin, so a word at a line's start or
                // on the first line isn't clipped by the scroll view's edge. The
                // frame below widens by the same amount and is pulled back, so
                // the text itself stays exactly where it was.
                .padding(.horizontal, WordHighlight.padX)
                .padding(.vertical, WordHighlight.padY)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ResultContentHeightKey.self, value: geo.size.height)
                })
            }
            .frame(width: width + 2 * WordHighlight.padX, height: height)
            .padding(.horizontal, -WordHighlight.padX)
            .padding(.vertical, -WordHighlight.padY)
            .onPreferenceChange(ResultContentHeightKey.self) { onMeasuredHeight?($0) }
            .onChange(of: playback.highlight) { hit in
                previousHighlight = lastHighlight
                lastHighlight = hit
                withAnimation(WordHighlight.slide) { highlightStep += 1 }
            }
            .onChange(of: currentLine?.minY) { _ in
                guard currentLine != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(Self.lineAnchor, anchor: .center) }
            }
        }
    }

    /// The text exactly as it is read — one Text, so its own line breaks are
    /// the only ones. The sentences it is sent to the voice in never show here.
    private var textBody: some View {
        SpokenText(text: playback.text, highlight: playback.highlight, previous: previousHighlight,
                   step: highlightStep, style: style)
            .font(.system(size: fontSize))
            .foregroundStyle(Color.primary.opacity(ResultTextStyle.inkOpacity))
            .lineSpacing(fontSize * ResultTextStyle.lineSpacingEm)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                // An invisible mark on the line being read, for the scroll view to centre.
                if let line = currentLine {
                    Color.clear.frame(width: 1, height: line.height)
                        .id(Self.lineAnchor)
                        .padding(.top, line.minY)
                }
            }
    }

    private static let lineAnchor = "reading.currentLine"

    /// The line the spoken word is on, in the text's own coordinates.
    private var currentLine: ReadingLines.Line? {
        guard let hit = playback.highlight else { return nil }
        return lines.line(at: hit.location, text: playback.text, width: width,
                          fontSize: fontSize,
                          lineSpacing: fontSize * ResultTextStyle.lineSpacingEm)
    }
}

/// A text being read aloud, with the spoken word marked. The word keeps the
/// same font, weight and colour as the rest: only a shape is drawn behind it,
/// so nothing in the line moves as the highlight walks. Shared by the reading
/// window and the History page's replay, so both look alike.
///
/// `previous` and `step` drive the slide from the last word to this one: the
/// owner bumps `step` by one, animated, on every new highlight.
struct SpokenText: View {
    let text: String
    let highlight: NSRange?
    let previous: NSRange?
    let step: Double
    let style: ReadingHighlightStyle

    var body: some View {
        if let hit = highlight, hit.length > 0, let r = Range(hit, in: text) {
            if #available(macOS 15, *) {
                // An empty previous range would slip past the overlap check and
                // cut the text backwards, so only a real word counts.
                let previous = previous.flatMap { $0.length > 0 ? Range($0, in: text) : nil }
                marked(text, current: r, previous: previous)
                    .textRenderer(WordHighlight.Renderer(style: style, step: step, target: step.rounded(.up)))
            } else {
                // macOS 13–14 have no text renderer: fall back to a plain
                // background on the word's own glyphs (no margin, no corners).
                Text(fallbackAttributed(text, r))
            }
        } else {
            Text(verbatim: text)
        }
    }

    /// The text as one Text, with the current word (and the previous one, when
    /// it doesn't overlap) tagged for the renderer. Every part is verbatim, so
    /// `*`, `_` etc. in the text are never read as Markdown.
    @available(macOS 15, *)
    private func marked(_ piece: String, current: Range<String.Index>,
                        previous: Range<String.Index>?) -> Text {
        var cuts: [(Range<String.Index>, any TextAttribute)] = [(current, WordHighlight.Mark())]
        if let previous, !previous.overlaps(current) { cuts.append((previous, WordHighlight.PreviousMark())) }
        cuts.sort { $0.0.lowerBound < $1.0.lowerBound }
        var out = Text(verbatim: "")
        var at = piece.startIndex
        for (range, mark) in cuts {
            let plain = Text(verbatim: String(piece[at..<range.lowerBound]))
            let tagged: Text
            if mark is WordHighlight.Mark {
                tagged = Text(verbatim: String(piece[range])).customAttribute(WordHighlight.Mark())
            } else {
                tagged = Text(verbatim: String(piece[range])).customAttribute(WordHighlight.PreviousMark())
            }
            out = Text("\(out)\(plain)\(tagged)")
            at = range.upperBound
        }
        return Text("\(out)\(Text(verbatim: String(piece[at...])))")
    }

    private func fallbackAttributed(_ piece: String, _ r: Range<String.Index>) -> AttributedString {
        var result = AttributedString(piece)
        if let a = Range(r, in: result) { result[a].backgroundColor = WordHighlight.fill }
        return result
    }
}

/// The reading window's spoken-word highlight: a soft rounded pill drawn behind
/// the word, a few points wider than its glyphs. It is drawn, not styled: the
/// word's font, weight and colour are untouched, so the text never re-flows.
enum WordHighlight {
    static let padX: CGFloat = 3
    static let padY: CGFloat = 1.5
    static let radius: CGFloat = 5
    /// The pill: the accent colour at 30% in light mode and 40% in dark, where a
    /// fainter tint sinks into the dark glass and the pill's edge disappears.
    static let fill = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.40 : 0.30)
    })
    /// Highlighter yellow: stronger on light backgrounds, softer on dark ones so
    /// white text on top stays readable.
    static let marker = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: dark ? 0.40 : 0.55)
    })

    /// How the pill moves to the next word: the wheel's spring, quicker, since
    /// words change every 0.25–0.4 s and the pill must never trail the voice.
    static let slide = Animation.spring(response: 0.22, dampingFraction: 0.9)

    /// Tags the word being spoken.
    @available(macOS 15, *)
    struct Mark: TextAttribute {}
    /// Tags the word spoken just before, where the pill slides in from.
    @available(macOS 15, *)
    struct PreviousMark: TextAttribute {}

    /// How faded karaoke's not-yet-read text is.
    static let unreadOpacity = 0.4

    /// Draws the mark for the current word, then the text on top exactly as
    /// SwiftUI laid it out — the text is never restyled, so nothing re-flows.
    /// While `step` animates up to `target`, the mark is interpolated from the
    /// previous word's box to the current one's, so it slides along the line
    /// instead of jumping. On a new line it simply appears there.
    @available(macOS 15, *)
    struct Renderer: TextRenderer {
        var style: ReadingHighlightStyle
        var step: Double
        var target: Double
        var animatableData: Double {
            get { step }
            set { step = newValue }
        }

        func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
            // The current word's box per line it sits on, the line each is on,
            // and the previous word's box.
            var current: [(box: CGRect, line: CGRect)] = []
            var previous: CGRect?
            for line in layout {
                var cur: CGRect?
                for run in line {
                    let r = run.typographicBounds.rect
                    if run[Mark.self] != nil { cur = cur.map { $0.union(r) } ?? r }
                    if run[PreviousMark.self] != nil { previous = previous.map { $0.union(r) } ?? r }
                }
                if let cur { current.append((cur, line.typographicBounds.rect)) }
            }
            let t = min(max(step - (target - 1), 0), 1)
            // The mark's box right now: mid-slide on the first line of the word.
            let shown: [CGRect] = current.enumerated().map { i, item in
                if i == 0, let previous, t < 1, abs(previous.midY - item.box.midY) < item.box.height / 2 {
                    return lerp(previous, item.box, t)
                }
                return item.box
            }

            switch style {
            case .karaoke:
                drawKaraoke(layout, in: &ctx, shown: shown, lines: current.map(\.line))
            case .pill, .marker, .solid:
                let shapes = shown.map(shape(for:))
                for path in shapes { ctx.fill(path, with: .color(color)) }
                var normal = ctx
                if style == .solid {
                    // Keep the dark text out of the pill entirely, so its glyph
                    // edges can't show through the white copy drawn there.
                    var outside = Path(CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000))
                    for path in shapes { outside.addPath(path) }
                    normal.clip(to: outside, style: FillStyle(eoFill: true))
                }
                for line in layout { normal.draw(line) }
                // Solid: redraw the text in white, clipped to the pill, so whatever
                // it covers — even half a word mid-slide — shows white.
                if style == .solid {
                    for path in shapes {
                        var inside = ctx
                        inside.clip(to: path)
                        // Full white: the text is drawn at `inkOpacity`, so lift
                        // its alpha back to 1, or the word reads greyish on blue.
                        inside.addFilter(.colorMatrix(Self.tint(.white, alphaScale: 1 / ResultTextStyle.inkOpacity)))
                        for line in layout { inside.draw(line) }
                    }
                }
            }
        }

        /// Karaoke: all text faded, then full strength over everything before the
        /// sliding window (lines above it, and its own line up to its left edge),
        /// then the accent colour inside the window. The window slides like the
        /// pill, so the colour sweeps across and read text fills in behind it.
        private func drawKaraoke(_ layout: Text.Layout, in ctx: inout GraphicsContext,
                                 shown: [CGRect], lines: [CGRect]) {
            var faded = ctx
            faded.opacity = unreadOpacity
            for line in layout { faded.draw(line) }
            guard let first = shown.first, let firstLine = lines.first else { return }

            var read = Path()
            let far: CGFloat = 100_000
            // Every line above the window's line is read.
            read.addRect(CGRect(x: -far, y: -far, width: 2 * far, height: firstLine.minY + far))
            // Its own line, up to where the window starts.
            read.addRect(CGRect(x: -far, y: firstLine.minY, width: first.minX + far, height: firstLine.height))
            var done = ctx
            done.clip(to: read)
            for line in layout { done.draw(line) }

            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            for box in shown {
                var inside = ctx
                inside.clip(to: Path(box.insetBy(dx: -1, dy: -padY)))
                inside.addFilter(.colorMatrix(Self.tint(accent)))
                for line in layout { inside.draw(line) }
            }
        }

        private var color: Color {
            switch style {
            case .pill: return fill
            case .marker: return marker
            case .solid, .karaoke: return .accentColor
            }
        }

        /// Maps every pixel to one colour, keeping its alpha (so glyph edges stay
        /// smooth), optionally scaled up.
        private static func tint(_ color: NSColor, alphaScale: Double = 1) -> ColorMatrix {
            let c = color.usingColorSpace(.sRGB) ?? color
            var m = ColorMatrix()
            m.r1 = 0; m.r2 = 0; m.r3 = 0; m.r4 = 0; m.r5 = Float(c.redComponent)
            m.g1 = 0; m.g2 = 0; m.g3 = 0; m.g4 = 0; m.g5 = Float(c.greenComponent)
            m.b1 = 0; m.b2 = 0; m.b3 = 0; m.b4 = 0; m.b5 = Float(c.blueComponent)
            m.a1 = 0; m.a2 = 0; m.a3 = 0; m.a4 = Float(alphaScale); m.a5 = 0
            return m
        }

        /// The mark around a word's typographic box (ascent to descent). The pill
        /// wraps it with a small margin; the highlighter covers roughly the
        /// x-height band, from just under half height down to the baseline area,
        /// like a pen stroke — slightly wider than the word, nearly square ends.
        private func shape(for box: CGRect) -> Path {
            switch style {
            case .pill, .solid, .karaoke:
                return Path(roundedRect: box.insetBy(dx: -padX, dy: -padY),
                            cornerRadius: radius, style: .continuous)
            case .marker:
                let band = CGRect(x: box.minX - 1.5, y: box.minY + box.height * 0.48,
                                  width: box.width + 3, height: box.height * 0.40)
                return Path(roundedRect: band, cornerRadius: 2, style: .continuous)
            }
        }

        private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
            let t = CGFloat(t)
            return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                          width: a.width + (b.width - a.width) * t,
                          height: a.height + (b.height - a.height) * t)
        }
    }
}

/// Where each line of the reading text sits, laid out with TextKit the same way
/// the Text is (system font, same width and line spacing), so the scroll view can
/// keep the line being read in view. Laid out once per text, width and font size
/// — not on every word. It can be off by a line where TextKit and SwiftUI wrap a
/// word differently; that only nudges where the view scrolls.
final class ReadingLines {
    struct Line: Equatable { let minY: CGFloat; let height: CGFloat }

    private var key: (text: String, width: CGFloat, fontSize: CGFloat)?
    private var storage: NSTextStorage?
    private var manager = NSLayoutManager()
    private var container = NSTextContainer()

    func line(at location: Int, text: String, width: CGFloat,
              fontSize: CGFloat, lineSpacing: CGFloat) -> Line? {
        if key?.text != text || key?.width != width || key?.fontSize != fontSize {
            key = (text, width, fontSize)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            let storage = NSTextStorage(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: style,
            ])
            manager = NSLayoutManager()
            container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            self.storage = storage
        }
        let length = (text as NSString).length
        guard length > 0 else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: min(max(location, 0), length - 1))
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return Line(minY: rect.minY, height: rect.height)
    }
}
