import SwiftUI

/// The settings window's sidebar: a fixed list of pages.
///
/// This replaces the plug-in tool registry the code was extracted from. That
/// registry existed so a multi-tool app could grow tabs without the shell knowing
/// about them; this app is one tool, so the indirection bought nothing and the
/// pages are simply named here. Order in `allCases` is order in the sidebar, and
/// `Block` decides where the separators fall.
enum SettingsPage: String, CaseIterable, Hashable, Identifiable {
    case general
    case advanced
    case actions
    case keyboard
    case ocr
    case history
    case clipboard
    case models
    case speech
    case about

    var id: String { rawValue }

    /// Which sidebar block the row sits in. Blocks are separated by a gap with no
    /// header, the way System Settings separates its groups.
    enum Block: Int, CaseIterable { case popup, history, app }

    var block: Block {
        switch self {
        case .general, .advanced, .actions, .keyboard, .ocr: return .popup
        case .history, .clipboard:                          return .history
        case .models, .speech, .about:                      return .app
        }
    }

    var title: String {
        switch self {
        case .general:    return L("page.general")
        case .actions:    return L("page.actions")
        case .history:    return L("page.history")
        case .advanced:   return L("page.advanced")
        case .keyboard:   return L("page.keyboard")
        case .ocr:        return L("page.ocr")
        case .clipboard:  return L("page.clipboard")
        case .models:     return L("page.models")
        case .speech:     return L("page.speech")
        case .about:      return L("page.about")
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "gearshape.fill"
        case .actions:    return "list.bullet.rectangle.fill"
        case .history:    return "clock.arrow.circlepath"
        case .advanced:   return "slider.horizontal.3"
        case .keyboard:   return "keyboard.fill"
        case .ocr:        return "viewfinder"
        case .clipboard:  return "doc.on.clipboard.fill"
        case .models:     return "brain.head.profile"
        case .speech:     return "speaker.wave.2.fill"
        case .about:      return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general:    return Color(nsColor: .systemGray)
        case .actions:    return .indigo
        case .history:    return .green
        case .advanced:   return .purple
        case .keyboard:   return .indigo
        case .ocr:        return .teal
        case .clipboard:  return .green
        case .models:     return .blue
        case .speech:     return .orange
        case .about:      return .pink
        }
    }

    /// Stable id stem for accessibility identifiers — never localized.
    var axID: String { "page_\(rawValue)" }

    static func block(_ block: Block) -> [SettingsPage] {
        allCases.filter { $0.block == block }
    }
}
