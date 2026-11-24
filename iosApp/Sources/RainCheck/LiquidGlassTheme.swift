//
//  LiquidGlassTheme.swift
//  RainCheck
//
//  iOS 26 / 27 Liquid Glass（液态玻璃）设计系统与多版本编译/运行兼容护栏。
//
//  设计原则（遵循 Apple Liquid Glass HIG）：
//   - 液态玻璃用于浮动导航层、操作胶囊、状态徽章、浮层工具栏与交互控制卡片；
//   - 底层铺设自适应深浅色流体极光画布（LiquidAuroraCanvas），赋予玻璃真实的折射层次；
//   - 正文列表、凭据表单与报文实验室保持高对比度可读表面，避免玻璃叠玻璃造成视觉杂乱；
//   - 所有 iOS 26+ 原生 API 均通过 `#if compiler(>=6.2)` + `if #available(iOS 26.0, *)` 封装，
//     在 Xcode 26/27（iOS 26/27）上呈现 100% 原生液态玻璃折射与流体融合，
//     在旧版 SDK / iOS 16–25 上平滑降级为多层材质 + 方向性高光描边 + 内折射光晕。
//

import SwiftUI
import UIKit

// MARK: - 色彩语义与校区色谱

enum LiquidPalette {
    static let sapphire = Color(red: 0.17, green: 0.45, blue: 0.96)
    static let cyan = Color(red: 0.08, green: 0.72, blue: 0.88)
    static let violet = Color(red: 0.49, green: 0.34, blue: 0.96)
    static let emerald = Color(red: 0.10, green: 0.76, blue: 0.54)
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.14)
    static let coral = Color(red: 0.95, green: 0.33, blue: 0.38)
    static let rose = Color(red: 0.92, green: 0.28, blue: 0.62)
    static let slate = Color(red: 0.46, green: 0.52, blue: 0.62)

    /// 按站点 / 校区着色的液态玻璃折射色调。
    static func accent(forHost host: String, editionId: String? = nil) -> Color {
        let lowerHost = host.lowercased()
        let lowerId = (editionId ?? "").lowercased()
        if lowerId == "mock" || lowerHost.hasPrefix("127.0.0.1") || lowerHost.hasPrefix("localhost") {
            return rose
        }
        if lowerId == "tsinghua" || lowerId == "pro" || lowerHost.contains("pro.yuketang.cn") {
            return violet
        }
        if lowerId == "changjiang" || lowerHost.contains("changjiang.yuketang.cn") {
            return cyan
        }
        if lowerId == "huanghe" || lowerHost.contains("huanghe.yuketang.cn") {
            return amber
        }
        if lowerId == "xuetangx" || lowerHost.contains("xuetangx.com") {
            return emerald
        }
        if lowerId == "www" || lowerHost.contains("www.yuketang.cn") {
            return sapphire
        }
        return slate
    }

    static func editionBadgeName(forHost host: String) -> String {
        let lower = host.lowercased()
        if lower.hasPrefix("127.0.0.1") || lower.hasPrefix("localhost") { return "本地演练" }
        if lower.contains("pro.yuketang.cn") { return "荷塘 / Pro" }
        if lower.contains("changjiang.yuketang.cn") { return "长江" }
        if lower.contains("huanghe.yuketang.cn") { return "黄河" }
        if lower.contains("xuetangx.com") { return "学堂在线" }
        if lower.contains("www.yuketang.cn") { return "雨课堂" }
        return "自定义"
    }
}

// MARK: - 流体极光画布

/// 自适应深浅色动态极光背景，为上方液态玻璃控件提供柔和光影与色彩折射底衬。
struct LiquidAuroraCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var accent: Color

    @State private var drift = false

    init(accent: Color = LiquidPalette.sapphire) {
        self.accent = accent
    }

    var body: some View {
        ZStack {
            baseLayer
            auroraLayer
            ambientVignette
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    private var baseLayer: some View {
        (colorScheme == .dark
            ? Color(red: 0.04, green: 0.06, blue: 0.11)
            : Color(red: 0.94, green: 0.96, blue: 0.99))
    }

    @ViewBuilder
    private var auroraLayer: some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            meshAurora
        } else {
            radialAurora
        }
        #else
        radialAurora
        #endif
    }

    #if compiler(>=6.0)
    @available(iOS 18.0, *)
    private var meshAurora: some View {
        let isDark = colorScheme == .dark
        let dx: Float = drift ? 0.08 : -0.06
        let dy: Float = drift ? -0.07 : 0.06
        let points: [SIMD2<Float>] = [
            SIMD2(0.0, 0.0), SIMD2(0.5 + dx * 0.5, 0.0), SIMD2(1.0, 0.0),
            SIMD2(0.0, 0.5 + dy * 0.5), SIMD2(0.52 + dx, 0.46 + dy), SIMD2(1.0, 0.5 - dy * 0.4),
            SIMD2(0.0, 1.0), SIMD2(0.5 - dx * 0.5, 1.0), SIMD2(1.0, 1.0)
        ]
        let colors: [Color] = isDark
            ? [
                Color(red: 0.05, green: 0.08, blue: 0.16),
                accent.opacity(0.32),
                LiquidPalette.violet.opacity(0.24),
                LiquidPalette.cyan.opacity(0.20),
                accent.opacity(0.26),
                Color(red: 0.07, green: 0.09, blue: 0.18),
                Color(red: 0.04, green: 0.05, blue: 0.10),
                LiquidPalette.emerald.opacity(0.14),
                Color(red: 0.05, green: 0.07, blue: 0.13)
            ]
            : [
                Color(red: 0.92, green: 0.95, blue: 1.00),
                accent.opacity(0.22),
                LiquidPalette.violet.opacity(0.16),
                LiquidPalette.cyan.opacity(0.16),
                Color(red: 0.97, green: 0.98, blue: 1.00),
                accent.opacity(0.14),
                Color(red: 0.93, green: 0.95, blue: 0.99),
                LiquidPalette.emerald.opacity(0.10),
                Color(red: 0.95, green: 0.96, blue: 1.00)
            ]
        return MeshGradient(width: 3, height: 3, points: points, colors: colors, smoothsColors: true)
            .opacity(isDark ? 0.95 : 0.92)
    }
    #endif

    private var radialAurora: some View {
        let isDark = colorScheme == .dark
        return ZStack {
            RadialGradient(
                colors: [accent.opacity(isDark ? 0.34 : 0.20), .clear],
                center: drift ? .topTrailing : .topLeading,
                startRadius: 20,
                endRadius: 420
            )
            RadialGradient(
                colors: [LiquidPalette.cyan.opacity(isDark ? 0.24 : 0.15), .clear],
                center: drift ? .bottomLeading : .center,
                startRadius: 30,
                endRadius: 380
            )
            RadialGradient(
                colors: [LiquidPalette.violet.opacity(isDark ? 0.22 : 0.12), .clear],
                center: drift ? .center : .bottomTrailing,
                startRadius: 20,
                endRadius: 360
            )
        }
    }

    private var ambientVignette: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.black.opacity(0.10), Color.clear, Color.black.opacity(0.28)]
                : [Color.white.opacity(0.25), Color.clear, Color.white.opacity(0.15)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 液态玻璃变体与核心修饰器

enum LiquidGlassVariant: Sendable {
    case regular
    case clear
}

/// 统一液态玻璃表面修饰器：iOS 26+ 调用原生 `.glassEffect`，旧版提供精细多层降级渲染。
struct LiquidGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let variant: LiquidGlassVariant
    let tint: Color?
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(shape: S, variant: LiquidGlassVariant, tint: Color?, interactive: Bool) {
        self.shape = shape
        self.variant = variant
        self.tint = tint
        self.interactive = interactive
    }

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            nativeGlass(content)
        } else {
            fallbackGlass(content)
        }
        #else
        fallbackGlass(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func nativeGlass(_ content: Content) -> some View {
        let base: Glass = variant == .clear ? .clear : .regular
        let tinted: Glass = tint.map { base.tint($0) } ?? base
        let resolved: Glass = interactive ? tinted.interactive() : tinted
        return content.glassEffect(resolved, in: shape)
    }
    #endif

    private func fallbackGlass(_ content: Content) -> some View {
        let isDark = colorScheme == .dark
        let material: Material = variant == .clear ? .ultraThinMaterial : .thinMaterial
        let tintOpacity: Double = variant == .clear
            ? (isDark ? 0.10 : 0.08)
            : (isDark ? 0.18 : 0.13)

        return content
            .background {
                ZStack {
                    shape.fill(material)
                    if let tint {
                        shape.fill(tint.opacity(tintOpacity))
                    }
                    // 顶部折射内高光
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDark ? 0.16 : 0.45),
                                Color.white.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
            .overlay {
                // 方向性镜面描边
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.34 : 0.78),
                            (tint ?? Color.white).opacity(isDark ? 0.18 : 0.25),
                            Color.white.opacity(isDark ? 0.08 : 0.32)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(
                color: (tint ?? Color.black).opacity(isDark ? 0.26 : 0.10),
                radius: variant == .clear ? 10 : 16,
                x: 0,
                y: variant == .clear ? 4 : 8
            )
    }
}

/// 液态玻璃流体融合容器：iOS 26+ 使用原生 `GlassEffectContainer(spacing:)`。
struct LiquidGlassGroup<Content: View>: View {
    let spacing: CGFloat?
    @ViewBuilder let content: @MainActor () -> Content

    init(spacing: CGFloat? = 12, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// 液态玻璃形变过渡标识：iOS 26+ 绑定 `.glassEffectID(_:in:)`。
struct LiquidGlassMorphID<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// TabView 原生液态玻璃滚动最小化行为封装。
struct LiquidTabBarBehaviorModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - 液态玻璃按钮样式

enum LiquidButtonProminence: Sendable {
    case glass
    case prominent
}

/// 降级模式下的物理按压液态玻璃按钮样式。
struct LiquidFallbackButtonStyle: ButtonStyle {
    let prominence: LiquidButtonProminence
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    init(prominence: LiquidButtonProminence, tint: Color) {
        self.prominence = prominence
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        let isDark = colorScheme == .dark
        let pressed = configuration.isPressed
        return configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominence == .prominent ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background {
                if prominence == .prominent {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.76)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.32), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                        }
                } else {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(tint.opacity(isDark ? 0.16 : 0.10))
                    }
                }
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(prominence == .prominent ? 0.45 : (isDark ? 0.34 : 0.72)),
                            Color.white.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(
                color: tint.opacity(prominence == .prominent ? 0.34 : 0.12),
                radius: pressed ? 4 : 12,
                x: 0,
                y: pressed ? 2 : 6
            )
            .scaleEffect(pressed ? 0.965 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.48)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: pressed)
    }
}

/// 统一液态玻璃操作按钮：iOS 26+ 使用 `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`。
struct LiquidGlassActionButton<Label: View>: View {
    let prominence: LiquidButtonProminence
    let tint: Color
    let role: ButtonRole?
    let action: @MainActor () -> Void
    @ViewBuilder let label: @MainActor () -> Label

    init(
        prominence: LiquidButtonProminence = .glass,
        tint: Color = LiquidPalette.sapphire,
        role: ButtonRole? = nil,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder label: @escaping @MainActor () -> Label
    ) {
        self.prominence = prominence
        self.tint = tint
        self.role = role
        self.action = action
        self.label = label
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            nativeButton
        } else {
            fallbackButton
        }
        #else
        fallbackButton
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    @ViewBuilder
    private var nativeButton: some View {
        switch prominence {
        case .glass:
            Button(role: role, action: { action() }) {
                label()
            }
            .buttonStyle(.glass)
            .tint(tint)
        case .prominent:
            Button(role: role, action: { action() }) {
                label()
            }
            .buttonStyle(.glassProminent)
            .tint(tint)
        }
    }
    #endif

    private var fallbackButton: some View {
        Button(role: role, action: { action() }) {
            label()
        }
        .buttonStyle(LiquidFallbackButtonStyle(prominence: prominence, tint: tint))
    }
}

// MARK: - View 扩展快捷语法

extension View {
    func liquidGlass<S: InsettableShape>(
        _ variant: LiquidGlassVariant = .regular,
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        modifier(LiquidGlassSurface(shape: shape, variant: variant, tint: tint, interactive: interactive))
    }

    func liquidGlassCard(
        cornerRadius: CGFloat = 24,
        variant: LiquidGlassVariant = .regular,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        liquidGlass(
            variant,
            tint: tint,
            interactive: interactive,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    func liquidGlassCapsule(
        variant: LiquidGlassVariant = .regular,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        liquidGlass(variant, tint: tint, interactive: interactive, in: Capsule())
    }

    func liquidGlassMorphID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        modifier(LiquidGlassMorphID(id: id, namespace: namespace))
    }

    func liquidTabBarBehavior() -> some View {
        modifier(LiquidTabBarBehaviorModifier())
    }

    /// 高对比度内容阅读表面（遵循 Apple HIG：正文列表与报文数据保持清晰易读，不盲目套高折射玻璃）。
    func liquidReadableSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(LiquidReadableSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// 无废弃警告且严格并发安全的跨版本 `onChange` 封装。
    @ViewBuilder
    func onValueChange<V: Equatable & Sendable>(
        of value: V,
        perform action: @escaping @MainActor (V) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in
                MainActor.assumeIsolated {
                    action(newValue)
                }
            }
        } else {
            onChange(of: value) { newValue in
                MainActor.assumeIsolated {
                    action(newValue)
                }
            }
        }
    }
}

private struct LiquidReadableSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(
                    colorScheme == .dark
                        ? Color(red: 0.09, green: 0.11, blue: 0.17).opacity(0.84)
                        : Color.white.opacity(0.82)
                )
            }
            .overlay {
                shape.strokeBorder(
                    colorScheme == .dark
                        ? Color.white.opacity(0.11)
                        : Color.black.opacity(0.06),
                    lineWidth: 0.75
                )
            }
    }
}

// MARK: - 复用液态玻璃组件

/// 状态 / 参数胶囊徽章。
struct LiquidStatusPill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = LiquidPalette.sapphire
    var interactive: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .liquidGlassCapsule(variant: .clear, tint: tint, interactive: interactive)
    }
}

/// 分区标题栏（高对比度文字 + 可选右侧摘要胶囊）。
struct LiquidSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var trailingBadge: String? = nil
    var tint: Color = LiquidPalette.sapphire

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let trailingBadge {
                LiquidStatusPill(text: trailingBadge, tint: tint)
            }
        }
    }
}

// MARK: - 触觉反馈

@MainActor
enum LiquidHaptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}
