import SwiftUI

// Small, quiet building blocks in the style of native macOS menu-bar panels.

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased()).tracking(0.7)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let t = trailing {
                Text(t).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Coloured status capsule with a dot, e.g. "● Idle".
struct Pill: View {
    let text: String
    let color: Color
    var small = false

    var body: some View {
        HStack(spacing: small ? 4 : 5) {
            Circle().fill(color).frame(width: small ? 6 : 7, height: small ? 6 : 7)
            Text(text).font(.system(size: small ? 10.5 : 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, small ? 7 : 9)
        .padding(.vertical, small ? 2.5 : 4)
        .background(Capsule().fill(color.opacity(0.16)))
        .fixedSize()
    }
}

/// Neutral capsule for facts like "4-bit" or "Splash".
struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// A metric tile: small label with icon, large value, optional coloured footnote.
struct Tile: View {
    let icon: String
    let label: String
    let value: String
    var note: String? = nil
    var noteColor: Color? = nil

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let n = note {
                HStack(spacing: 3) {
                    if let c = noteColor { Circle().fill(c).frame(width: 5, height: 5) }
                    Text(n).font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(noteColor ?? .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

/// Thin rounded usage bar.
struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(5, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// Several coloured segments in one thin bar (e.g. Jarvis / other apps / free memory).
struct StackedBar: View {
    let parts: [(Double, Color)]

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                HStack(spacing: 1.5) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Rectangle().fill(part.1).frame(width: max(0, g.size.width * min(max(part.0, 0), 1) - 1.5))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
    }
}

struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).monospacedDigit().lineLimit(1)
        }
    }
}

/// One line in a card: icon, text, trailing detail.
struct InfoRow: View {
    let icon: String
    let title: String
    var tint: Color = .secondary
    var trailing: String? = nil
    var trailingColor: Color? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let t = trailing {
                Text(t).font(.system(size: 12)).monospacedDigit().foregroundStyle(trailingColor ?? .secondary).lineLimit(1)
            }
        }
    }
}

/// Label/value line inside the collapsible model details.
struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Wide, softly filled button like the Settings / Quit pair in native panels.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, prominent: prominent)
    }

    private struct Inner: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.13 : 0.065))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.1), lineWidth: 0.5)
                )
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// One small bounce when the state changes (macOS 14+). A repeating animation would keep the panel
    /// redrawing every frame and cost a quarter of a CPU core, so nothing loops.
    @ViewBuilder func bounce<V: Equatable>(on value: V) -> some View {
        if #available(macOS 14.0, *) {
            self.symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }
}
