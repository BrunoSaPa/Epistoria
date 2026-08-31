import EpistoriaCore
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum EpistoriaSourceImportTypes {
    static let supported: [UTType] = {
        let packaged = [
            "md", "epub", "docx", "odt", "pptx", "odp", "xlsx",
            "aac", "caf", "m4a", "mp3", "wav",
            "m4v", "mov", "mp4",
        ]
            .compactMap { UTType(filenameExtension: $0) }
        return [.pdf, .image, .plainText, .html, .commaSeparatedText] + packaged
    }()
}

extension SourceKind {
    var epistoriaSymbol: String {
        switch self {
        case .audio, .lecture: "waveform"
        case .video, .youtube: "play.rectangle"
        case .image: "photo"
        case .csv, .xlsx, .googleSheet: "tablecells"
        case .epub, .book: "book.closed"
        case .pptx, .odp, .googleSlides: "rectangle.on.rectangle"
        case .pdf: "doc.richtext"
        default: "doc.text"
        }
    }
}

enum EpistoriaDesign {
    /// The fixed identity colors used by the app icon and brand mark.
    static let brandInk = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let brandPaper = Color.white
    static let brandCircleScale: CGFloat = 430.0 / 1_024.0

    /// Adaptive label color for text, icons, selection, and prominent fills.
    static let ink = Color(uiColor: .label)

    /// Accessible secondary copy. It keeps small text above contrast thresholds on the page.
    static let mutedInk = Color(uiColor: UIColor { traits in
        let highContrast = traits.accessibilityContrast == .high
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: highContrast ? 0.84 : 0.72, alpha: 1)
        }
        return UIColor(white: highContrast ? 0.24 : 0.35, alpha: 1)
    })

    /// Adaptive inverse of `ink`, used only on prominent monochrome fills.
    static let inverseInk = Color(uiColor: .systemBackground)

    /// The notebook page. Light Mode is paper white; Dark Mode follows the system reading surface.
    static let page = Color(uiColor: .systemBackground)

    /// Structural navigation may differ from the page without introducing another hue.
    static let sidebar = Color(uiColor: .secondarySystemBackground)

    /// Surfaces stay on the page plane unless a real grouping boundary is needed.
    static let surface = page
    static let subtleFill = Color(uiColor: .secondarySystemFill)
    static let hoverFill = Color(uiColor: .tertiarySystemFill)
    static let border = Color(uiColor: .separator)

    /// Compatibility alias for feature views that have not yet adopted the `page` name.
    static let canvas = page

    /// Monochrome interaction tint. Shape, weight, and labels carry meaning instead of hue.
    static let accent = ink

    /// Success and attention remain monochrome; destructive failures alone use system red.
    static let positive = Color.primary
    static let attention = mutedInk

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 20
        static let xLarge: CGFloat = 32
        static let page: CGFloat = 36
    }

    enum Layout {
        static let pageWidth: CGFloat = 920
        static let readingWidth: CGFloat = 760
        static let editorWidth: CGFloat = 980
    }

    static let cardRadius: CGFloat = 8
    static let compactRadius: CGFloat = 6
}

struct EpistoriaBrandMark: View {
    var size: CGFloat = 42

    var body: some View {
        Image("EpistoriaMark")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct EpistoriaSectionHeading: View {
    let title: String
    var subtitle: String?
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EpistoriaStatusPill: View {
    let title: String
    let symbol: String
    var tone: Tone = .neutral

    enum Tone {
        case neutral
        case positive
        case attention

        fileprivate var color: Color {
            switch self {
            case .neutral: EpistoriaDesign.accent
            case .positive: EpistoriaDesign.positive
            case .attention: EpistoriaDesign.attention
            }
        }
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(EpistoriaDesign.subtleFill, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct EpistoriaQuickAction: View {
    let title: String
    let subtitle: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(prominent ? EpistoriaDesign.inverseInk : EpistoriaDesign.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(prominent ? EpistoriaDesign.inverseInk : Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(
                            prominent ? EpistoriaDesign.inverseInk.opacity(0.78) : EpistoriaDesign.mutedInk
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(
                        prominent ? EpistoriaDesign.inverseInk.opacity(0.75) : EpistoriaDesign.mutedInk
                    )
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                prominent ? EpistoriaDesign.ink : EpistoriaDesign.surface,
                in: RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
                    .stroke(
                        prominent ? Color.clear : EpistoriaDesign.border.opacity(0.55),
                        lineWidth: 0.5
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(EpistoriaPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Gives custom rows immediate touch-down feedback while keeping motion optional and restrained.
struct EpistoriaPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.995 : 1)
    }
}

/// Full-width secondary action with a visible boundary on the paper page.
struct EpistoriaSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .fontWeight(.medium)
            .foregroundStyle(EpistoriaDesign.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(
                EpistoriaDesign.page,
                in: RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
                    .stroke(EpistoriaDesign.mutedInk, lineWidth: 1)
                    .accessibilityHidden(true)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.995 : 1)
    }
}

/// Full-width primary action that grows with Dynamic Type instead of using a fixed control size.
struct EpistoriaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(EpistoriaDesign.inverseInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
                    .fill(EpistoriaDesign.ink)
                    .accessibilityHidden(true)
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.995 : 1)
    }
}

private struct EpistoriaCardModifier: ViewModifier {
    let padding: CGFloat
    let highlighted: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                EpistoriaDesign.surface,
                in: RoundedRectangle(cornerRadius: EpistoriaDesign.cardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: EpistoriaDesign.cardRadius, style: .continuous)
                    .stroke(
                        highlighted ? Color.primary.opacity(0.28) : EpistoriaDesign.border.opacity(0.50),
                        lineWidth: highlighted ? 1.5 : 0.5
                    )
            }
    }
}

extension View {
    func epistoriaCard(padding: CGFloat = 18, highlighted: Bool = false) -> some View {
        modifier(EpistoriaCardModifier(padding: padding, highlighted: highlighted))
    }

    func epistoriaPageBackground() -> some View {
        background(EpistoriaDesign.page.ignoresSafeArea())
    }
}

/// Coordinates editor focus with the root split view without coupling feature routes to it.
@MainActor
@Observable
final class EpistoriaWorkspacePresentation {
    private(set) var activeImmersiveEditorID: UUID?

    var isEditingImmersively: Bool { activeImmersiveEditorID != nil }

    func beginImmersiveEditing(id: UUID) {
        activeImmersiveEditorID = id
    }

    func endImmersiveEditing(id: UUID) {
        guard activeImmersiveEditorID == id else { return }
        activeImmersiveEditorID = nil
    }

    func reset() {
        activeImmersiveEditorID = nil
    }
}

private struct EpistoriaWorkspacePresentationKey: EnvironmentKey {
    static let defaultValue: EpistoriaWorkspacePresentation? = nil
}

extension EnvironmentValues {
    var epistoriaWorkspacePresentation: EpistoriaWorkspacePresentation? {
        get { self[EpistoriaWorkspacePresentationKey.self] }
        set { self[EpistoriaWorkspacePresentationKey.self] = newValue }
    }
}
