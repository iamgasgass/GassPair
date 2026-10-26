import SwiftUI

// Building blocks for the usbmuxd screens, on top of the project's existing
// `pillButton()` / `glassCard(cornerRadius:)` / `glassCapsule()` modifiers:
// native Liquid Glass on iOS 26+, translucent materials on iOS 16–25.

extension View {
    /// Primary action: `.glassProminent` on iOS 26+, `.borderedProminent` below.
    @ViewBuilder
    func prominentPillButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Text field drawn on a glass capsule.
    func glassField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassCapsule()
    }

    /// Small round glass badge (icons in card headers).
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Groups glass shapes so they blend/morph together on iOS 26+ (no-op below).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A titled glass card, the Liquid Glass replacement for a `Form` section.
struct GlassSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, systemImage: String? = nil, footer: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
            } else {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            content
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}

/// "Title ……… value" row used inside glass cards.
struct GlassInfoRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
