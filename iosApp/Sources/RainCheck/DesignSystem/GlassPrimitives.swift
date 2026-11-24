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
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(LiquidPalette.tertiaryText)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Visual tone for `LiquidSelectionPill` across standard surfaces and dark camera/media overlays.
enum LiquidSelectionPillTone: Sendable {
    case standard
    case darkOverlay
}

/// Crisp, non-obscuring selection pill rendered strictly beneath foreground labels and digits.
/// Deliberately avoids applying `.glassEffect` to an empty background shape inside `GlassEffectContainer`,
/// which on iOS 26 can composite a frosted interactive lens mask over sibling text/numbers.
struct LiquidSelectionPill: View {
    let tone: LiquidSelectionPillTone

    @Environment(\.colorScheme) private var colorScheme

    init(tone: LiquidSelectionPillTone = .standard) {
        self.tone = tone
    }

    var body: some View {
        Capsule()
            .fill(fillColor)
            .overlay {
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: shadowColor,
                radius: tone == .darkOverlay ? 6 : 5,
                x: 0,
                y: 2
            )
            .allowsHitTesting(false)
    }

    private var fillColor: Color {
        switch tone {
        case .standard:
            return LiquidPalette.selectedPillSurface(colorScheme)
        case .darkOverlay:
            return LiquidPalette.darkChromeSelectedPillSurface()
        }
    }

    private var borderColor: Color {
        switch tone {
        case .standard:
            return LiquidPalette.selectedPillBorder(colorScheme)
        case .darkOverlay:
            return Color.white.opacity(0.32)
        }
    }

    private var shadowColor: Color {
        switch tone {
        case .standard:
            return Color.black.opacity(colorScheme == .dark ? 0.34 : 0.08)
        case .darkOverlay:
            return Color.black.opacity(0.32)
        }
    }
}

/// Minimalist segmented control with a crisp sliding selection pill strictly beneath foreground text/digits.
struct LiquidSegmentedControl<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    @Namespace private var selectionNamespace
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
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    guard option != selection else { return }
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                        selection = option
                    }
                } label: {
                    Text(label(option))
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: LiquidMetrics.dockItemMinHeight)
                        .background {
                            if isSelected {
                                LiquidSelectionPill(tone: .standard)
                                    .matchedGeometryEffect(id: "liquid.segmented.active", in: selectionNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .zIndex(isSelected ? 0 : 1)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .frame(minHeight: LiquidMetrics.dockControlMinHeight)
        .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
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
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .frame(minHeight: 40)
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
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LiquidPalette.secondaryText)
                .frame(width: 68, height: 68)
                .background(LiquidPalette.subtleSurface(colorScheme), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(LiquidPalette.primaryText)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(LiquidPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
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
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? LiquidPalette.accent : LiquidPalette.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(chipFill, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(chipBorder, lineWidth: 0.75)
                .allowsHitTesting(false)
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
