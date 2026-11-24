import SwiftUI
import UIKit

/// Monochrome-first neutral color palette with a single restrained accent for Liquid Glass surfaces.
enum LiquidPalette {
    static let accent = Color("AccentColor")

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color(uiColor: .tertiaryLabel)

    static func canvasBackground(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(red: 0.039, green: 0.039, blue: 0.047)
        default:
            return Color(red: 0.961, green: 0.961, blue: 0.969)
        }
    }

    static func elevatedSurface(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(white: 0.115)
        default:
            return Color(white: 1.0)
        }
    }

    static func subtleSurface(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.08)
        default:
            return Color.black.opacity(0.045)
        }
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.14)
        default:
            return Color.black.opacity(0.08)
        }
    }

    static func editionDisplayName(forHost host: String) -> String {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else {
            return "雨课堂"
        }

        let hostWithoutPort = stripPort(from: normalized)
        switch hostWithoutPort {
        case "www.yuketang.cn", "yuketang.cn":
            return "雨课堂"
        case "pro.yuketang.cn":
            return "雨课堂 Pro"
        case "changjiang.yuketang.cn":
            return "长江雨课堂"
        case "huanghe.yuketang.cn":
            return "黄河雨课堂"
        case "www.xuetangx.com", "xuetangx.com":
            return "学堂在线"
        case "127.0.0.1", "localhost", "::1":
            return "本地演练"
        default:
            if hostWithoutPort.hasSuffix(".yuketang.cn") {
                return "雨课堂校内版"
            }
            if hostWithoutPort.hasSuffix(".xuetangx.com") {
                return "学堂在线"
            }
            return "自定义站点"
        }
    }

    private static func normalizeHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        if let slashIndex = value.firstIndex(of: "/") {
            value = String(value[..<slashIndex])
        }
        if let queryIndex = value.firstIndex(of: "?") {
            value = String(value[..<queryIndex])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripPort(from host: String) -> String {
        if host.hasPrefix("[") {
            if let closingBracket = host.firstIndex(of: "]") {
                return String(host[host.index(after: host.startIndex)..<closingBracket])
            }
            return host
        }
        if let colonIndex = host.lastIndex(of: ":"),
           host.firstIndex(of: ":") == colonIndex {
            return String(host[..<colonIndex])
        }
        return host
    }
}

/// Consistent spatial tokens for minimalist pages and glass surfaces.
enum LiquidMetrics {
    static let cornerRadiusCard: CGFloat = 24
    static let cornerRadiusControl: CGFloat = 14
    static let pageHorizontalPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 20
    static let cardPadding: CGFloat = 18
}

/// Single-tone neutral backdrop canvas for every screen.
struct LiquidCanvas: View {
    @Environment(\.colorScheme) private var colorScheme

    init() {}

    var body: some View {
        LiquidPalette.canvasBackground(colorScheme)
            .ignoresSafeArea()
    }
}

/// Groups sibling Liquid Glass controls so iOS 26/27 renders coherent morphing surfaces.
struct LiquidGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct LiquidGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            fallbackCard(content: content, shape: shape)
        }
        #else
        fallbackCard(content: content, shape: shape)
        #endif
    }

    private func fallbackCard(content: Content, shape: RoundedRectangle) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.05),
                radius: 14,
                x: 0,
                y: 6
            )
    }
}

private struct LiquidGlassCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                content.glassEffect(.regular, in: Capsule())
            }
        } else {
            fallbackCapsule(content: content)
        }
        #else
        fallbackCapsule(content: content)
        #endif
    }

    private func fallbackCapsule(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.04),
                radius: 8,
                x: 0,
                y: 3
            )
    }
}

private struct LiquidFallbackPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration)
    }

    private struct BodyView: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(LiquidPalette.accent, in: Capsule())
                .opacity(configuration.isPressed ? 0.84 : (isEnabled ? 1.0 : 0.45))
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

private struct LiquidFallbackSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration)
    }

    private struct BodyView: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.body.weight(.medium))
                .foregroundStyle(LiquidPalette.primaryText)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                }
                .opacity(configuration.isPressed ? 0.76 : (isEnabled ? 1.0 : 0.45))
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

extension View {
    func liquidGlassCard(cornerRadius: CGFloat = LiquidMetrics.cornerRadiusCard) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius))
    }

    func liquidGlassCapsule(interactive: Bool = false) -> some View {
        modifier(LiquidGlassCapsuleModifier(interactive: interactive))
    }

    @ViewBuilder
    func liquidGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self.matchedGeometryEffect(id: id, in: namespace)
        }
        #else
        self.matchedGeometryEffect(id: id, in: namespace)
        #endif
    }

    @ViewBuilder
    func liquidPrimaryButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .tint(LiquidPalette.accent)
        } else {
            self.buttonStyle(LiquidFallbackPrimaryButtonStyle())
        }
        #else
        self.buttonStyle(LiquidFallbackPrimaryButtonStyle())
        #endif
    }

    @ViewBuilder
    func liquidSecondaryButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(LiquidFallbackSecondaryButtonStyle())
        }
        #else
        self.buttonStyle(LiquidFallbackSecondaryButtonStyle())
        #endif
    }

    @ViewBuilder
    func liquidTabBarBehavior() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
