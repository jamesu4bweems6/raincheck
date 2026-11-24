import SwiftUI

/// Quiet typographic section header with an optional trailing caption.
struct LiquidSectionHeader: View {
    let title: String
    let trailing: String?

    init(title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LiquidPalette.secondaryText)

            Spacer(minLength: 8)

            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LiquidPalette.tertiaryText)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Minimalist segmented control with native iOS 26/27 Liquid Glass morphing indicator.
struct LiquidSegmentedControl<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    @Namespace private var glassNamespace
    @Environment(\.colorScheme) private var colorScheme

    init(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    var body: some View {
        LiquidGlassGroup(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(options) { option in
                    let isSelected = option == selection
                    Button {
                        guard option != selection else { return }
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            selection = option
                        }
                    } label: {
                        Text(label(option))
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if isSelected {
                            LiquidSegmentedActivePill(colorScheme: colorScheme)
                                .liquidGlassID("liquid.segmented.active", in: glassNamespace)
                        }
                    }
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(4)
            .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
            .overlay {
                Capsule().strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
            }
        }
    }
}

private struct LiquidSegmentedActivePill: View {
    let colorScheme: ColorScheme

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            Capsule()
                .fill(Color.clear)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            fallbackPill
        }
        #else
        fallbackPill
        #endif
    }

    private var fallbackPill: some View {
        Capsule()
            .fill(LiquidPalette.elevatedSurface(colorScheme))
            .overlay {
                Capsule().strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                radius: 5,
                x: 0,
                y: 2
            )
    }
}

/// Floating neutral Liquid Glass toast pill for brief status feedback.
struct LiquidToastPill: View {
    let message: String

    init(message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(LiquidPalette.primaryText)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .liquidGlassCapsule(interactive: false)
            .accessibilityLabel(message)
    }
}

/// Minimalist centered empty state with monochrome symbol and quiet copy.
struct LiquidEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    @Environment(\.colorScheme) private var colorScheme

    init(symbol: String, title: String, message: String) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LiquidPalette.secondaryText)
                .frame(width: 64, height: 64)
                .background(LiquidPalette.subtleSurface(colorScheme), in: Circle())
                .overlay {
                    Circle().strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
                }

            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(LiquidPalette.primaryText)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(LiquidPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
    }
}

/// Subtle neutral or single-accent status chip without competing colors.
struct LiquidStatusChip: View {
    let symbol: String
    let text: String
    let emphasized: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(symbol: String, text: String, emphasized: Bool = false) {
        self.symbol = symbol
        self.text = text
        self.emphasized = emphasized
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? LiquidPalette.accent : LiquidPalette.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(chipFill, in: Capsule())
        .overlay {
            Capsule().strokeBorder(chipBorder, lineWidth: 0.5)
        }
    }

    private var chipFill: Color {
        if emphasized {
            return LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10)
        }
        return LiquidPalette.subtleSurface(colorScheme)
    }

    private var chipBorder: Color {
        if emphasized {
            return LiquidPalette.accent.opacity(colorScheme == .dark ? 0.30 : 0.22)
        }
        return LiquidPalette.hairline(colorScheme)
    }
}
