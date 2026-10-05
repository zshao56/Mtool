import SwiftUI
import AppKit

// The guide's pages. Layout "A" of docs/onboarding-options.html: the steps down
// the left (always saying which one is required), the current page on the right,
// its buttons in a footer. Every string goes through `L()`; the app's name
// arrives as `%@` like everywhere else.

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: 0) {
            OnboardingSidebar(model: model)
                .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                if model.step == .welcome {
                    // The welcome page is one centred greeting, not a page of
                    // content, and has nothing that could need scrolling.
                    WelcomePage()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        page
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 34).padding(.top, 34).padding(.bottom, 18)
                    }
                    Divider()
                }
                footer
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .auroraBackground()
        }
        // Fill the window, whatever its size: a FIXED 740×520 frame here, with the
        // safe area ignored, was laid out from below the (transparent) title bar
        // and left a blank strip that tall along the bottom. The window's size is
        // set once, in `OnboardingWindowController`.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Same as the settings window: re-read every string after an in-app
        // language change.
        .id(model.appState.languageRevision)
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome:         WelcomePage()
        case .accessibility:   AccessibilityStepPage(model: model, store: model.store)
        case .screenRecording: ScreenRecordingStepPage(model: model, store: model.store)
        case .ai:              AIStepPage(model: model, settings: model.settings)
        case .tryIt:           TryItPage(model: model, store: model.store)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            footerLeading
            Spacer()
            footerTrailing
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var footerLeading: some View {
        switch model.step {
        case .welcome:
            // Just "Start": the window's own close button is the way out here.
            EmptyView()
        case .accessibility:
            if !model.store.isTrusted {
                Button(L("onboarding.button.later")) { model.later() }.buttonStyle(.borderless)
            }
        case .screenRecording:
            switch model.status(of: .screenRecording) {
            case .done:
                EmptyView()
            case .waitingRelaunch:
                Button(L("onboarding.button.skip")) { model.skipScreenRecording() }.buttonStyle(.borderless)
                Button(L("onboarding.sr.openAgain")) { model.openScreenRecording() }
                    .buttonStyle(.link)
            default:
                Button(L("onboarding.button.skip")) { model.skipScreenRecording() }.buttonStyle(.borderless)
            }
        case .ai:
            Button(L("onboarding.button.skip")) { model.skipAI() }.buttonStyle(.borderless)
        case .tryIt:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footerTrailing: some View {
        switch model.step {
        case .welcome:
            primary(L("onboarding.button.start")) { model.next() }
        case .accessibility:
            if model.store.isTrusted {
                primary(L("onboarding.button.continue")) { model.next() }
            } else {
                primary(L("onboarding.button.openSettings")) { model.openAccessibility() }
            }
        case .screenRecording:
            switch model.status(of: .screenRecording) {
            case .done:
                primary(L("onboarding.button.continue")) { model.next() }
            case .waitingRelaunch:
                primary(String(format: L("onboarding.button.relaunch"), Brand.name)) { model.relaunch() }
            default:
                primary(L("onboarding.button.openSettings")) { model.openScreenRecording() }
            }
        case .ai:
            let n = model.picks.count
            primary(n > 0 ? String(format: L("onboarding.button.addActions"), n)
                          : L("onboarding.button.continue")) { model.next() }
        case .tryIt:
            primary(L("onboarding.button.done")) { model.finish() }
        }
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Sidebar

private struct OnboardingSidebar: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("AppLogo").resizable().frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Brand.name).font(.system(size: 14, weight: .bold))
                    Text(L("onboarding.sidebar.subtitle")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4).padding(.top, 50).padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.element) { index, step in
                    row(step, number: index + 1)
                }
            }

            Spacer()
            Text(L("onboarding.sidebar.note"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6).padding(.bottom, 16)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ step: OnboardingStep, number: Int) -> some View {
        let status = model.status(of: step)
        let current = model.step == step
        return Button { model.go(step) } label: {
            HStack(spacing: 9) {
                badge(status, number: number, current: current)
                VStack(alignment: .leading, spacing: 0) {
                    Text(step.title).font(.system(size: 13))
                    if let sub = status.label {
                        Text(sub).font(.system(size: 11)).foregroundStyle(status.labelColor)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(current ? Color.accentColor.opacity(0.14) : .clear))
            // The whole row is the target, not just its text.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.step.\(step.rawValue)")
    }

    @ViewBuilder
    private func badge(_ status: OnboardingStepStatus, number: Int, current: Bool) -> some View {
        switch status {
        case .done:
            Circle().fill(Color.green).frame(width: 20, height: 20)
                .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
        case .waitingRelaunch:
            Circle().fill(Color.orange).frame(width: 20, height: 20)
                .overlay(Text(verbatim: "!").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
        default:
            Circle()
                .strokeBorder(current ? Color.accentColor : Color.primary.opacity(0.22), lineWidth: current ? 1.5 : 1.2)
                .frame(width: 20, height: 20)
                .overlay(Text(verbatim: "\(number)")
                    .font(.system(size: 11, weight: current ? .semibold : .regular))
                    .foregroundStyle(current ? Color.accentColor : .secondary))
        }
    }
}

extension OnboardingStep {
    var title: String {
        switch self {
        case .welcome:         return L("onboarding.step.welcome")
        case .accessibility:   return L("onboarding.step.accessibility")
        case .screenRecording: return L("onboarding.step.screenRecording")
        case .ai:              return L("onboarding.step.ai")
        case .tryIt:           return L("onboarding.step.try")
        }
    }

    var symbol: String {
        switch self {
        case .welcome:         return "hand.wave.fill"
        case .accessibility:   return "accessibility"
        case .screenRecording: return "viewfinder"
        case .ai:              return "sparkles"
        case .tryIt:           return "text.cursor"
        }
    }

    var color: Color {
        switch self {
        case .welcome:         return .blue
        case .accessibility:   return .blue
        case .screenRecording: return .teal
        case .ai:              return .indigo
        case .tryIt:           return .green
        }
    }
}

extension OnboardingStepStatus {
    /// The small line under a step's name in the sidebar.
    var label: String? {
        switch self {
        case .none:            return nil
        case .required:        return L("onboarding.status.required")
        case .optional:        return L("onboarding.status.optional")
        case .done:            return L("onboarding.status.done")
        case .skipped:         return L("onboarding.status.skipped")
        case .waitingRelaunch: return L("onboarding.status.waitingRelaunch")
        }
    }

    var labelColor: Color {
        switch self {
        case .required: return .red
        case .done:     return .green
        default:        return .secondary
        }
    }
}

// MARK: - Shared pieces

/// A colored tile at any size (the settings rows use a fixed 26pt `IconTile`).
private struct StepTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(
                LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.18)))
    }
}

/// "Required" / "Optional" pill beside a title.
private struct StepTag: View {
    let required: Bool
    var body: some View {
        Text(required ? L("onboarding.status.required") : L("onboarding.status.optional"))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(required ? Color.red : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(required ? Color.red.opacity(0.12) : Color.primary.opacity(0.07)))
    }
}

/// A page's heading: tile, title, and its tag.
private struct StepHeader: View {
    let step: OnboardingStep
    let title: String
    var required: Bool?
    var lead: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                StepTile(symbol: step.symbol, color: step.color, size: 34)
                Text(title).font(.system(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let required { StepTag(required: required) }
            }
            if let lead {
                Text(lead)
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8).padding(.bottom, 14)
            } else {
                Spacer().frame(height: 14)
            }
        }
    }
}

/// One line of "why": a small grey tile, then text with an optional bold lead-in.
private struct WhyRow: View {
    let symbol: String
    var bold: String?
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StepTile(symbol: symbol, color: Color(nsColor: .systemGray), size: 20)
                .padding(.top, 1)
            (bold.map { Text($0).fontWeight(.semibold) } ?? Text(verbatim: "")) + Text(text)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private enum StatusKind { case wait, ok, warn }

/// The rounded status strip: grey while waiting, green when done, orange for
/// "one more thing".
private struct StatusBox<Content: View>: View {
    let kind: StatusKind
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: kind == .warn ? .top : .center, spacing: 8) {
            switch kind {
            case .wait: PulsingDot()
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warn:
                Circle().fill(Color.orange).frame(width: 8, height: 8).padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .foregroundStyle(kind == .wait ? Color.secondary : kind == .ok ? Color.green : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(background))
        .padding(.vertical, 6)
    }

    private var background: Color {
        switch kind {
        case .wait: return Color.primary.opacity(0.06)
        case .ok:   return Color.green.opacity(0.13)
        case .warn: return Color.orange.opacity(0.14)
        }
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color.secondary).frame(width: 8, height: 8)
            .opacity(on ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// A small drawing of the System Settings pane, pointing at the switch to flip.
private struct SystemSettingsMini: View {
    let pane: String
    let on: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("onboarding.mini.privacy")).font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == 1 ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08))
                        .frame(height: 5)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
            .frame(width: 52)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.05))

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "‹ \(pane)").font(.system(size: 10.5, weight: .semibold)).padding(.bottom, 2)
                miniRow(logo: true, name: Brand.name, on: on, point: !on)
                miniRow(logo: false, name: L("onboarding.mini.otherApp"), on: true, point: false)
                Text(verbatim: "＋　−").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
        }
        .frame(width: 210, height: 92)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func miniRow(logo: Bool, name: String, on: Bool, point: Bool) -> some View {
        HStack(spacing: 5) {
            if logo {
                Image("AppLogo").resizable().frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).frame(width: 14, height: 14)
            }
            Text(name).font(.system(size: 10.5)).foregroundStyle(logo ? .primary : .tertiary)
            Spacer(minLength: 0)
            Capsule().fill(on ? Color.green : Color.primary.opacity(0.18))
                .frame(width: 20, height: 12)
                .overlay(Circle().fill(.white).frame(width: 10, height: 10)
                    .frame(maxWidth: .infinity, alignment: on ? .trailing : .leading).padding(.horizontal, 1))
            if point {
                Text(verbatim: "←").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
    }
}

private func smallText(_ s: String) -> some View {
    Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

private func okLine(_ s: String) -> some View {
    StatusBox(kind: .ok) { Text(s) }
}

// MARK: - Welcome

private struct WelcomePage: View {
    // Deliberately short: the steps are already listed in the sidebar, so the
    // first page only says what this is and gets out of the way.
    var body: some View {
        VStack(spacing: 0) {
            Image("AppLogo").resizable().frame(width: 88, height: 88)
            Text(String(format: L("onboarding.welcome.title"), Brand.name))
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 14)
            Text(L("onboarding.welcome.tagline"))
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 34)
        // Sit a little above the true centre: the footer below adds visual weight.
        .offset(y: -12)
    }
}

// MARK: - Accessibility

private struct AccessibilityStepPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var store: PopBarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(step: .accessibility,
                       title: String(format: L("onboarding.ax.title"), Brand.name),
                       required: true,
                       lead: String(format: L("onboarding.ax.lead"), Brand.name))
            if store.isTrusted { granted } else { waiting }
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 9) {
            WhyRow(symbol: "cursorarrow", bold: L("onboarding.ax.why1.b"), text: L("onboarding.ax.why1"))
            WhyRow(symbol: "text.alignleft", bold: L("onboarding.ax.why2.b"), text: L("onboarding.ax.why2"))
            WhyRow(symbol: "lock.fill", text: L("onboarding.ax.privacy"))
            HStack(alignment: .center, spacing: 14) {
                SystemSettingsMini(pane: L("onboarding.mini.accessibility"), on: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "1. " + L("onboarding.ax.how1"))
                    Text(verbatim: "2. " + String(format: L("onboarding.ax.how2"), Brand.name))
                    Text(verbatim: "3. " + L("onboarding.ax.how3"))
                }
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 5)
            StatusBox(kind: .wait) { Text(String(format: L("onboarding.ax.waiting"), Brand.name)) }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    smallText(String(format: L("onboarding.ax.help1"), Brand.name, Brand.name))
                    smallText(String(format: L("onboarding.ax.help2"), Brand.name))
                }
                .padding(.top, 4)
            } label: {
                Text(String(format: L("onboarding.ax.help.title"), Brand.name))
                    .font(.system(size: 12)).foregroundStyle(Color.accentColor)
            }
        }
    }

    private var granted: some View {
        VStack(alignment: .leading, spacing: 6) {
            okLine(L("onboarding.ax.granted"))
            HStack(spacing: 14) {
                SystemSettingsMini(pane: L("onboarding.mini.accessibility"), on: true)
                smallText(String(format: L("onboarding.ax.howToRevoke"), Brand.name))
            }
        }
    }
}

// MARK: - Screen Recording

private struct ScreenRecordingStepPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var store: PopBarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(step: .screenRecording, title: L("onboarding.sr.title"), required: false)
            switch model.status(of: .screenRecording) {
            case .done:
                okLine(String(format: L("onboarding.sr.on"), store.screenOCRHotKey.display))
            case .waitingRelaunch:
                intro
                StatusBox(kind: .warn) {
                    Text(L("onboarding.sr.relaunch.title")).fontWeight(.semibold)
                    Text(String(format: L("onboarding.sr.relaunch.body"), Brand.name, Brand.name))
                    Text(L("onboarding.sr.relaunch.system"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                }
            default:
                intro
                HStack(spacing: 14) {
                    SystemSettingsMini(pane: L("onboarding.mini.screenRecording"), on: false)
                    smallText(L("onboarding.sr.skipNote"))
                }
                .padding(.top, 4)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 9) {
            WhyRow(symbol: "viewfinder", bold: L("onboarding.sr.why1.b"),
                   text: String(format: L("onboarding.sr.why1"), store.screenOCRHotKey.display, Brand.name))
            WhyRow(symbol: "lock.fill",
                   text: String(format: L("onboarding.sr.privacy"), Brand.name))
        }
        .padding(.bottom, 10)
    }
}

// MARK: - AI

private struct AIStepPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: LLMSettingsStore

    /// Order of the "AI" template section; each gets a one-line description.
    private static let templateDescriptions = [
        "onboarding.ai.tpl.summarize", "onboarding.ai.tpl.grammar", "onboarding.ai.tpl.tone",
        "onboarding.ai.tpl.analyze", "onboarding.ai.tpl.explainCode",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(step: .ai, title: L("onboarding.ai.title"), required: false,
                       lead: L("onboarding.ai.lead"))
            FlowLayout(spacing: 6) {
                ForEach(LLMConfig.providers, id: \.self) { p in providerChip(p) }
            }
            .padding(.bottom, 10)
            keyRows
            Text(L("onboarding.ai.templates"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.top, 14).padding(.bottom, 8)
            picks
            smallText(L("onboarding.ai.footnote")).padding(.top, 8)
        }
    }

    private func providerChip(_ p: String) -> some View {
        let selected = settings.provider == p
        return Button { model.selectProvider(p) } label: {
            HStack(spacing: 4) {
                Text(Self.providerName(p)).fontWeight(selected ? .semibold : .regular)
                if let sub = Self.providerNote(p) {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var keyRows: some View {
        let p = settings.provider
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if p == "ollama" {
                    Text(L("onboarding.ai.key.label.generic")).frame(width: 110, alignment: .leading)
                    Text(L("onboarding.ai.key.ollama")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Text(String(format: L("onboarding.ai.key.label"), Self.providerName(p)))
                        .lineLimit(1).frame(width: 110, alignment: .leading)
                    SecureField(L("onboarding.ai.key.placeholder"), text: $model.keyDraft)
                        .textFieldStyle(.roundedBorder)
                }
                Button(model.testState == .testing ? L("onboarding.ai.testing") : L("onboarding.ai.test")) {
                    model.test()
                }
                .disabled(model.testState == .testing
                          || (p != "ollama" && model.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                              && !settings.hasKey(for: p)))
            }
            .font(.system(size: 12.5))

            HStack(spacing: 8) {
                Spacer().frame(width: 110)
                VStack(alignment: .leading, spacing: 3) {
                    if p != "ollama" {
                        if settings.hasKey(for: p) && model.keyDraft.isEmpty {
                            Text(L("onboarding.ai.key.saved")).foregroundStyle(.green)
                        } else if let site = Self.providerSite(p), let url = URL(string: "https://\(site)") {
                            HStack(spacing: 3) {
                                Text(L("onboarding.ai.key.none")).foregroundStyle(.secondary)
                                Link(String(format: L("onboarding.ai.key.create"), site), destination: url)
                            }
                        }
                    }
                    switch model.testState {
                    case .ok(let m):
                        Text(String(format: L("onboarding.ai.test.ok"), m.isEmpty ? "—" : m))
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    default:
                        EmptyView()
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private var picks: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.aiTemplates.enumerated()), id: \.element.id) { index, template in
                if index > 0 { Divider() }
                pickRow(template, description: index < Self.templateDescriptions.count
                        ? L(Self.templateDescriptions[index]) : nil)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private func pickRow(_ template: PopBarActionConfig, description: String?) -> some View {
        let on = model.picks.contains(template.id)
        return Button { model.togglePick(template.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                StepTile(symbol: template.iconSymbol, color: .indigo, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.title).font(.system(size: 13))
                    if let description {
                        Text(description).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Provider names as the guide shows them. The settings page keeps its own
    // (`LLMConfig.displayName`), which is also what the config file stores.
    static func providerName(_ p: String) -> String {
        switch p {
        case "doubao":  return L("onboarding.ai.provider.doubao")
        case "alibaba": return L("onboarding.ai.provider.alibaba")
        default:        return LLMConfig.displayName(p)
        }
    }

    static func providerNote(_ p: String) -> String? {
        switch p {
        case "doubao":  return L("onboarding.ai.provider.doubao.note")
        case "alibaba": return L("onboarding.ai.provider.alibaba.note")
        case "ollama":  return L("onboarding.ai.provider.ollama.note")
        default:        return nil
        }
    }

    static func providerSite(_ p: String) -> String? {
        switch p {
        case "deepseek": return "platform.deepseek.com"
        case "openai":   return "platform.openai.com"
        case "doubao":   return "console.volcengine.com/ark"
        case "alibaba":  return "bailian.console.aliyun.com"
        default:         return nil
        }
    }
}

/// Lays children out left to right, wrapping onto a new line when out of room.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                let y = row.y + row.height + spacing
                rows.append(Row(items: [index], y: y, width: size.width, height: size.height))
                continue
            }
            row.items.append(index)
            row.width = needed
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Try it

private struct TryItPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var store: PopBarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(step: .tryIt, title: L("onboarding.try.title"), lead: L("onboarding.try.lead"))
            if !store.isTrusted {
                StatusBox(kind: .warn) {
                    HStack(spacing: 6) {
                        Text(L("onboarding.try.needsAX"))
                        Button(L("onboarding.try.grantFirst")) { model.go(.accessibility) }
                            .buttonStyle(.link)
                    }
                }
            }
            SampleText(text: L("onboarding.try.sample1") + "\n" + L("onboarding.try.sample2"),
                       onSelect: { text, point in model.sampleSelected(text, at: point) },
                       onMouseDown: { model.sampleClicked() })
                .frame(height: 84)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                .padding(.top, 4)
            if model.progress.tried {
                okLine(L("onboarding.try.success"))
            } else {
                StatusBox(kind: .wait) { Text(L("onboarding.try.waiting")) }
            }
            if store.isScreenRecordingAuthorized && store.screenOCREnabled {
                HStack(spacing: 12) {
                    Text(verbatim: "Lunch at 12:30 · Room 402")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 6).fill(
                            LinearGradient(colors: [.orange.opacity(0.25), .pink.opacity(0.2)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)))
                    smallText(String(format: L("onboarding.try.ocr"), store.screenOCRHotKey.display))
                }
                .padding(.top, 6)
            }
            HStack(spacing: 8) {
                Image("MenuBarIcon").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 14, height: 14).foregroundStyle(.secondary)
                smallText(String(format: L("onboarding.try.menuBar"), Brand.name))
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - Sample text

/// The "Try it" sample: a read-only, selectable text view that reports its own
/// selection. The global input monitor never sees clicks in our own windows, so
/// this view is what notices the selection and hands it to the popup.
private struct SampleText: NSViewRepresentable {
    let text: String
    let onSelect: (String, CGPoint) -> Void
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> SampleTextView {
        let view = SampleTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setAccessibilityIdentifier("onboarding.sample")
        apply(to: view)
        return view
    }

    func updateNSView(_ view: SampleTextView, context: Context) {
        if view.string != text { apply(to: view) }
        view.onSelect = onSelect
        view.onMouseDown = onMouseDown
    }

    private func apply(to view: SampleTextView) {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.3
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]))
        view.onSelect = onSelect
        view.onMouseDown = onMouseDown
    }
}

final class SampleTextView: NSTextView {
    var onSelect: ((String, CGPoint) -> Void)?
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        // NSTextView tracks the whole drag (or double-click) inside this call and
        // returns on mouse-up, with the selection already made.
        super.mouseDown(with: event)
        let range = selectedRange()
        guard range.length > 0, let text = (string as NSString?)?.substring(with: range) else { return }
        onSelect?(text, NSEvent.mouseLocation)
    }
}
