import SegueKit
import SwiftUI

/// Physical-material finishes for the 3D sculpted Lumina Manta and popover accents.
enum MantaMaterialTheme: String, CaseIterable, Identifiable, Sendable {
    case pearl
    case celadon
    case sapphire
    case quartz

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pearl:
            return "月光琉璃"
        case .celadon:
            return "天青影瓷"
        case .sapphire:
            return "深蓝星丝"
        case .quartz:
            return "霜樱云母"
        }
    }

    var subtitle: String {
        switch self {
        case .pearl:
            return "冰白珠光 · 浅靛虹彩"
        case .celadon:
            return "宋瓷天青 · 温润水光"
        case .sapphire:
            return "丝绒群青 · 香槟金脊"
        case .quartz:
            return "柔雾粉晶 · 珍珠暮蓝"
        }
    }

    var swatchColors: [Color] {
        switch self {
        case .pearl:
            return [
                Color(red: 0.97, green: 0.98, blue: 0.99),
                Color(red: 0.73, green: 0.90, blue: 0.99),
                Color(red: 0.77, green: 0.71, blue: 0.99),
            ]
        case .celadon:
            return [
                Color(red: 0.93, green: 0.99, blue: 0.96),
                Color(red: 0.49, green: 0.83, blue: 0.78),
                Color(red: 0.17, green: 0.43, blue: 0.47),
            ]
        case .sapphire:
            return [
                Color(red: 0.99, green: 0.95, blue: 0.78),
                Color(red: 0.38, green: 0.65, blue: 0.98),
                Color(red: 0.12, green: 0.23, blue: 0.54),
            ]
        case .quartz:
            return [
                Color(red: 1.0, green: 0.95, blue: 0.95),
                Color(red: 0.98, green: 0.66, blue: 0.83),
                Color(red: 0.65, green: 0.71, blue: 0.99),
            ]
        }
    }
}

/// Coarse visual state for the menu-bar icon and hero manta, derived strictly
/// from `ConnectionModel` read-backs (never faked on click).
enum MantaVisualState: Equatable, Sendable {
    case connected
    case connecting
    case guarding
    case error
    case off

    @MainActor
    static func from(model: ConnectionModel) -> MantaVisualState {
        switch model.helperAvailability {
        case .notInstalled, .versionMismatch, .unauthorized:
            return .error
        case .unknown, .ready:
            break
        }
        if model.isRevoked {
            return .error
        }
        if model.aiLayerMode == AILayerState.degraded || model.aiListError != nil {
            return .error
        }
        if model.showsConnected {
            return .connected
        }
        if model.isConnecting {
            return .connecting
        }
        if model.helperKernelState == "kernel_failed" {
            return .error
        }
        if model.isGuarding {
            return .guarding
        }
        if model.helperAvailability == .ready && !model.helperArmed {
            if let error = model.lastError, !isExpectedIdleKernelError(error, model: model) {
                return .error
            }
            return .off
        }
        if model.lastError != nil && model.kernelState == nil {
            return .error
        }
        return .off
    }

    /// True when the helper is ready and disarmed so an unread/stopped kernel
    /// control socket is expected rather than an actionable user error.
    @MainActor
    static func isExpectedIdleKernelError(_ error: String?, model: ConnectionModel) -> Bool {
        guard let error,
              model.helperAvailability == .ready,
              !model.helperArmed,
              model.kernelState == nil,
              model.helperKernelState != "running"
        else {
            return false
        }
        return error == "Couldn't read the kernel control token."
            || error == "Couldn't reach the kernel on this Mac."
    }
}

struct RGBColor: Sendable {
    let r: Double
    let g: Double
    let b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(with other: RGBColor, t: Double) -> RGBColor {
        let clamped = max(0, min(1, t))
        return RGBColor(
            r + (other.r - r) * clamped,
            g + (other.g - g) * clamped,
            b + (other.b - b) * clamped
        )
    }

    func scaled(_ factor: Double) -> RGBColor {
        RGBColor(r * factor, g * factor, b * factor)
    }

    func swiftColor(opacity: Double = 1.0) -> Color {
        Color(
            red: max(0, min(1, r / 255.0)),
            green: max(0, min(1, g / 255.0)),
            blue: max(0, min(1, b / 255.0)),
            opacity: opacity
        )
    }
}

struct MantaMaterialSpec: Sendable {
    let shadow: RGBColor
    let mid: RGBColor
    let bright: RGBColor
    let iridA: RGBColor
    let iridB: RGBColor
    let under: RGBColor
    let rim: RGBColor
    let spec: RGBColor
    let trail: RGBColor
    let auraColor: Color
    let causticColor: Color
    let heroTop: Color
    let heroMid: Color
    let accent: Color
    let accentSecondary: Color
    let chipBackground: Color
    let chipForeground: Color
    let selectedBackground: Color
    let selectedBorder: Color
    let switchLeading: Color
    let switchTrailing: Color
    let switchShadow: Color

    static func resolve(
        theme: MantaMaterialTheme,
        state: MantaVisualState,
        isDark: Bool
    ) -> MantaMaterialSpec {
        let base = resolveTheme(theme, isDark: isDark)
        switch state {
        case .connected, .connecting:
            return base
        case .guarding:
            return isDark ? guardDark(base: base) : guardLight(base: base)
        case .error:
            return isDark ? errorDark(base: base) : errorLight(base: base)
        case .off:
            return isDark ? offDark(base: base) : offLight(base: base)
        }
    }

    private static func resolveTheme(_ theme: MantaMaterialTheme, isDark: Bool) -> MantaMaterialSpec {
        switch (theme, isDark) {
        case (.pearl, true):
            return MantaMaterialSpec(
                shadow: RGBColor(58, 84, 136),
                mid: RGBColor(176, 208, 240),
                bright: RGBColor(244, 250, 255),
                iridA: RGBColor(125, 211, 252),
                iridB: RGBColor(196, 181, 253),
                under: RGBColor(216, 232, 250),
                rim: RGBColor(238, 248, 255),
                spec: RGBColor(255, 255, 255),
                trail: RGBColor(165, 218, 252),
                auraColor: Color(red: 0.58, green: 0.77, blue: 0.99, opacity: 0.24),
                causticColor: Color(red: 0.73, green: 0.88, blue: 1.0, opacity: 0.08),
                heroTop: Color(red: 0.58, green: 0.77, blue: 0.99, opacity: 0.22),
                heroMid: Color(red: 0.77, green: 0.71, blue: 0.99, opacity: 0.10),
                accent: Color(red: 0.58, green: 0.77, blue: 0.99),
                accentSecondary: Color(red: 0.77, green: 0.71, blue: 0.99),
                chipBackground: Color(red: 0.58, green: 0.77, blue: 0.99, opacity: 0.16),
                chipForeground: Color(red: 0.86, green: 0.92, blue: 1.0),
                selectedBackground: Color(red: 0.58, green: 0.77, blue: 0.99, opacity: 0.12),
                selectedBorder: Color(red: 0.58, green: 0.77, blue: 0.99, opacity: 0.30),
                switchLeading: Color(red: 0.38, green: 0.65, blue: 0.98),
                switchTrailing: Color(red: 0.51, green: 0.55, blue: 0.97),
                switchShadow: Color(red: 0.58, green: 0.77, blue: 0.99, opacity: 0.36)
            )
        case (.pearl, false):
            return MantaMaterialSpec(
                shadow: RGBColor(62, 92, 148),
                mid: RGBColor(124, 160, 210),
                bright: RGBColor(226, 238, 254),
                iridA: RGBColor(56, 189, 248),
                iridB: RGBColor(139, 92, 246),
                under: RGBColor(186, 206, 236),
                rim: RGBColor(255, 255, 255),
                spec: RGBColor(255, 255, 255),
                trail: RGBColor(96, 148, 224),
                auraColor: Color(red: 0.39, green: 0.58, blue: 0.88, opacity: 0.16),
                causticColor: Color.white.opacity(0.42),
                heroTop: Color(red: 0.38, green: 0.65, blue: 0.98, opacity: 0.16),
                heroMid: Color(red: 0.55, green: 0.36, blue: 0.96, opacity: 0.08),
                accent: Color(red: 0.15, green: 0.39, blue: 0.92),
                accentSecondary: Color(red: 0.39, green: 0.40, blue: 0.95),
                chipBackground: Color(red: 0.15, green: 0.39, blue: 0.92, opacity: 0.10),
                chipForeground: Color(red: 0.11, green: 0.31, blue: 0.85),
                selectedBackground: Color(red: 0.23, green: 0.51, blue: 0.96, opacity: 0.09),
                selectedBorder: Color(red: 0.23, green: 0.51, blue: 0.96, opacity: 0.26),
                switchLeading: Color(red: 0.23, green: 0.51, blue: 0.96),
                switchTrailing: Color(red: 0.39, green: 0.40, blue: 0.95),
                switchShadow: Color(red: 0.23, green: 0.51, blue: 0.96, opacity: 0.26)
            )
        case (.celadon, true):
            return MantaMaterialSpec(
                shadow: RGBColor(24, 78, 92),
                mid: RGBColor(104, 196, 190),
                bright: RGBColor(220, 250, 244),
                iridA: RGBColor(125, 230, 220),
                iridB: RGBColor(147, 197, 253),
                under: RGBColor(186, 236, 230),
                rim: RGBColor(236, 254, 250),
                spec: RGBColor(255, 255, 255),
                trail: RGBColor(120, 218, 210),
                auraColor: Color(red: 0.37, green: 0.84, blue: 0.80, opacity: 0.22),
                causticColor: Color(red: 0.64, green: 0.94, blue: 0.92, opacity: 0.08),
                heroTop: Color(red: 0.37, green: 0.84, blue: 0.80, opacity: 0.22),
                heroMid: Color(red: 0.22, green: 0.74, blue: 0.97, opacity: 0.09),
                accent: Color(red: 0.49, green: 0.83, blue: 0.78),
                accentSecondary: Color(red: 0.49, green: 0.83, blue: 0.99),
                chipBackground: Color(red: 0.37, green: 0.84, blue: 0.80, opacity: 0.15),
                chipForeground: Color(red: 0.80, green: 0.98, blue: 0.95),
                selectedBackground: Color(red: 0.37, green: 0.84, blue: 0.80, opacity: 0.11),
                selectedBorder: Color(red: 0.37, green: 0.84, blue: 0.80, opacity: 0.28),
                switchLeading: Color(red: 0.17, green: 0.62, blue: 0.60),
                switchTrailing: Color(red: 0.22, green: 0.58, blue: 0.72),
                switchShadow: Color(red: 0.37, green: 0.84, blue: 0.80, opacity: 0.34)
            )
        case (.celadon, false):
            return MantaMaterialSpec(
                shadow: RGBColor(22, 78, 92),
                mid: RGBColor(48, 148, 146),
                bright: RGBColor(186, 236, 230),
                iridA: RGBColor(20, 184, 166),
                iridB: RGBColor(56, 189, 248),
                under: RGBColor(132, 204, 202),
                rim: RGBColor(246, 255, 253),
                spec: RGBColor(255, 255, 255),
                trail: RGBColor(45, 160, 158),
                auraColor: Color(red: 0.08, green: 0.72, blue: 0.65, opacity: 0.16),
                causticColor: Color.white.opacity(0.45),
                heroTop: Color(red: 0.08, green: 0.72, blue: 0.65, opacity: 0.15),
                heroMid: Color(red: 0.05, green: 0.65, blue: 0.91, opacity: 0.08),
                accent: Color(red: 0.06, green: 0.46, blue: 0.43),
                accentSecondary: Color(red: 0.01, green: 0.52, blue: 0.78),
                chipBackground: Color(red: 0.06, green: 0.46, blue: 0.43, opacity: 0.10),
                chipForeground: Color(red: 0.07, green: 0.37, blue: 0.35),
                selectedBackground: Color(red: 0.06, green: 0.46, blue: 0.43, opacity: 0.08),
                selectedBorder: Color(red: 0.06, green: 0.46, blue: 0.43, opacity: 0.25),
                switchLeading: Color(red: 0.06, green: 0.46, blue: 0.43),
                switchTrailing: Color(red: 0.01, green: 0.41, blue: 0.63),
                switchShadow: Color(red: 0.06, green: 0.46, blue: 0.43, opacity: 0.24)
            )
        case (.sapphire, true):
            return MantaMaterialSpec(
                shadow: RGBColor(16, 36, 112),
                mid: RGBColor(48, 108, 224),
                bright: RGBColor(166, 206, 255),
                iridA: RGBColor(96, 152, 254),
                iridB: RGBColor(253, 224, 138),
                under: RGBColor(132, 180, 248),
                rim: RGBColor(254, 243, 199),
                spec: RGBColor(255, 252, 240),
                trail: RGBColor(110, 166, 254),
                auraColor: Color(red: 0.26, green: 0.53, blue: 0.96, opacity: 0.28),
                causticColor: Color(red: 0.61, green: 0.78, blue: 1.0, opacity: 0.08),
                heroTop: Color(red: 0.23, green: 0.51, blue: 0.96, opacity: 0.28),
                heroMid: Color(red: 0.99, green: 0.90, blue: 0.62, opacity: 0.07),
                accent: Color(red: 0.38, green: 0.65, blue: 0.98),
                accentSecondary: Color(red: 0.99, green: 0.90, blue: 0.54),
                chipBackground: Color(red: 0.38, green: 0.65, blue: 0.98, opacity: 0.16),
                chipForeground: Color(red: 0.86, green: 0.92, blue: 1.0),
                selectedBackground: Color(red: 0.38, green: 0.65, blue: 0.98, opacity: 0.12),
                selectedBorder: Color(red: 0.38, green: 0.65, blue: 0.98, opacity: 0.30),
                switchLeading: Color(red: 0.15, green: 0.39, blue: 0.92),
                switchTrailing: Color(red: 0.26, green: 0.22, blue: 0.79),
                switchShadow: Color(red: 0.23, green: 0.51, blue: 0.96, opacity: 0.38)
            )
        case (.sapphire, false):
            return MantaMaterialSpec(
                shadow: RGBColor(24, 48, 118),
                mid: RGBColor(56, 108, 212),
                bright: RGBColor(176, 208, 252),
                iridA: RGBColor(59, 130, 246),
                iridB: RGBColor(217, 164, 72),
                under: RGBColor(122, 164, 234),
                rim: RGBColor(255, 248, 220),
                spec: RGBColor(255, 255, 255),
                trail: RGBColor(68, 118, 220),
                auraColor: Color(red: 0.23, green: 0.51, blue: 0.96, opacity: 0.16),
                causticColor: Color.white.opacity(0.44),
                heroTop: Color(red: 0.15, green: 0.39, blue: 0.92, opacity: 0.15),
                heroMid: Color(red: 0.85, green: 0.64, blue: 0.28, opacity: 0.06),
                accent: Color(red: 0.11, green: 0.31, blue: 0.85),
                accentSecondary: Color(red: 0.71, green: 0.33, blue: 0.04),
                chipBackground: Color(red: 0.11, green: 0.31, blue: 0.85, opacity: 0.10),
                chipForeground: Color(red: 0.12, green: 0.25, blue: 0.69),
                selectedBackground: Color(red: 0.11, green: 0.31, blue: 0.85, opacity: 0.08),
                selectedBorder: Color(red: 0.11, green: 0.31, blue: 0.85, opacity: 0.25),
                switchLeading: Color(red: 0.11, green: 0.31, blue: 0.85),
                switchTrailing: Color(red: 0.22, green: 0.19, blue: 0.64),
                switchShadow: Color(red: 0.11, green: 0.31, blue: 0.85, opacity: 0.26)
            )
        case (.quartz, true):
            return MantaMaterialSpec(
                shadow: RGBColor(112, 74, 128),
                mid: RGBColor(228, 166, 198),
                bright: RGBColor(255, 240, 246),
                iridA: RGBColor(251, 182, 206),
                iridB: RGBColor(165, 180, 252),
                under: RGBColor(246, 212, 228),
                rim: RGBColor(255, 246, 250),
                spec: RGBColor(255, 255, 255),
                trail: RGBColor(238, 174, 208),
                auraColor: Color(red: 0.96, green: 0.64, blue: 0.79, opacity: 0.23),
                causticColor: Color(red: 1.0, green: 0.84, blue: 0.91, opacity: 0.08),
                heroTop: Color(red: 0.96, green: 0.64, blue: 0.79, opacity: 0.22),
                heroMid: Color(red: 0.65, green: 0.71, blue: 0.99, opacity: 0.11),
                accent: Color(red: 0.98, green: 0.66, blue: 0.83),
                accentSecondary: Color(red: 0.65, green: 0.71, blue: 0.99),
                chipBackground: Color(red: 0.96, green: 0.64, blue: 0.79, opacity: 0.16),
                chipForeground: Color(red: 0.99, green: 0.91, blue: 0.95),
                selectedBackground: Color(red: 0.96, green: 0.64, blue: 0.79, opacity: 0.11),
                selectedBorder: Color(red: 0.96, green: 0.64, blue: 0.79, opacity: 0.28),
                switchLeading: Color(red: 0.86, green: 0.44, blue: 0.62),
                switchTrailing: Color(red: 0.51, green: 0.55, blue: 0.97),
                switchShadow: Color(red: 0.96, green: 0.64, blue: 0.79, opacity: 0.34)
            )
        case (.quartz, false):
            return MantaMaterialSpec(
                shadow: RGBColor(116, 72, 132),
                mid: RGBColor(204, 122, 162),
                bright: RGBColor(252, 222, 234),
                iridA: RGBColor(236, 126, 174),
                iridB: RGBColor(129, 140, 248),
                under: RGBColor(228, 172, 200),
                rim: RGBColor(255, 250, 252),
                spec: RGBColor(255, 255, 255),
                trail: RGBColor(212, 132, 174),
                auraColor: Color(red: 0.88, green: 0.50, blue: 0.68, opacity: 0.16),
                causticColor: Color.white.opacity(0.44),
                heroTop: Color(red: 0.88, green: 0.50, blue: 0.68, opacity: 0.16),
                heroMid: Color(red: 0.51, green: 0.55, blue: 0.97, opacity: 0.08),
                accent: Color(red: 0.75, green: 0.09, blue: 0.36),
                accentSecondary: Color(red: 0.31, green: 0.27, blue: 0.90),
                chipBackground: Color(red: 0.75, green: 0.09, blue: 0.36, opacity: 0.10),
                chipForeground: Color(red: 0.62, green: 0.09, blue: 0.30),
                selectedBackground: Color(red: 0.75, green: 0.09, blue: 0.36, opacity: 0.08),
                selectedBorder: Color(red: 0.75, green: 0.09, blue: 0.36, opacity: 0.24),
                switchLeading: Color(red: 0.75, green: 0.09, blue: 0.36),
                switchTrailing: Color(red: 0.39, green: 0.40, blue: 0.95),
                switchShadow: Color(red: 0.75, green: 0.09, blue: 0.36, opacity: 0.24)
            )
        }
    }

    private static func guardDark(base: MantaMaterialSpec) -> MantaMaterialSpec {
        MantaMaterialSpec(
            shadow: RGBColor(132, 74, 18),
            mid: RGBColor(224, 158, 48),
            bright: RGBColor(254, 240, 188),
            iridA: RGBColor(251, 191, 36),
            iridB: RGBColor(253, 230, 138),
            under: RGBColor(246, 206, 128),
            rim: RGBColor(255, 250, 224),
            spec: RGBColor(255, 255, 255),
            trail: RGBColor(245, 185, 72),
            auraColor: Color(red: 0.96, green: 0.69, blue: 0.19, opacity: 0.22),
            causticColor: Color(red: 0.99, green: 0.88, blue: 0.54, opacity: 0.08),
            heroTop: Color(red: 0.96, green: 0.62, blue: 0.04, opacity: 0.20),
            heroMid: Color(red: 0.96, green: 0.62, blue: 0.04, opacity: 0.05),
            accent: Color(red: 0.98, green: 0.75, blue: 0.14),
            accentSecondary: base.accent,
            chipBackground: Color(red: 0.96, green: 0.62, blue: 0.04, opacity: 0.16),
            chipForeground: Color(red: 0.98, green: 0.75, blue: 0.14),
            selectedBackground: base.selectedBackground,
            selectedBorder: base.selectedBorder,
            switchLeading: Color(red: 0.96, green: 0.62, blue: 0.04),
            switchTrailing: Color(red: 0.85, green: 0.47, blue: 0.02),
            switchShadow: Color(red: 0.96, green: 0.62, blue: 0.04, opacity: 0.34)
        )
    }

    private static func guardLight(base: MantaMaterialSpec) -> MantaMaterialSpec {
        MantaMaterialSpec(
            shadow: RGBColor(138, 72, 14),
            mid: RGBColor(204, 128, 26),
            bright: RGBColor(252, 220, 138),
            iridA: RGBColor(217, 119, 6),
            iridB: RGBColor(245, 158, 11),
            under: RGBColor(232, 178, 86),
            rim: RGBColor(255, 248, 224),
            spec: RGBColor(255, 255, 255),
            trail: RGBColor(217, 134, 24),
            auraColor: Color(red: 0.85, green: 0.47, blue: 0.02, opacity: 0.16),
            causticColor: Color(red: 1.0, green: 0.98, blue: 0.90, opacity: 0.42),
            heroTop: Color(red: 0.96, green: 0.62, blue: 0.04, opacity: 0.15),
            heroMid: Color(red: 0.96, green: 0.62, blue: 0.04, opacity: 0.04),
            accent: Color(red: 0.85, green: 0.47, blue: 0.02),
            accentSecondary: base.accent,
            chipBackground: Color(red: 0.96, green: 0.62, blue: 0.04, opacity: 0.14),
            chipForeground: Color(red: 0.71, green: 0.33, blue: 0.04),
            selectedBackground: base.selectedBackground,
            selectedBorder: base.selectedBorder,
            switchLeading: Color(red: 0.85, green: 0.47, blue: 0.02),
            switchTrailing: Color(red: 0.71, green: 0.33, blue: 0.04),
            switchShadow: Color(red: 0.85, green: 0.47, blue: 0.02, opacity: 0.25)
        )
    }

    private static func errorDark(base: MantaMaterialSpec) -> MantaMaterialSpec {
        MantaMaterialSpec(
            shadow: RGBColor(136, 36, 62),
            mid: RGBColor(225, 86, 118),
            bright: RGBColor(255, 212, 224),
            iridA: RGBColor(251, 113, 133),
            iridB: RGBColor(216, 180, 254),
            under: RGBColor(252, 165, 186),
            rim: RGBColor(255, 235, 240),
            spec: RGBColor(255, 255, 255),
            trail: RGBColor(244, 114, 142),
            auraColor: Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.22),
            causticColor: Color(red: 0.99, green: 0.64, blue: 0.69, opacity: 0.07),
            heroTop: Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.20),
            heroMid: Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.05),
            accent: Color(red: 0.98, green: 0.44, blue: 0.52),
            accentSecondary: base.accent,
            chipBackground: Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.16),
            chipForeground: Color(red: 0.98, green: 0.44, blue: 0.52),
            selectedBackground: base.selectedBackground,
            selectedBorder: base.selectedBorder,
            switchLeading: Color(red: 0.96, green: 0.25, blue: 0.37),
            switchTrailing: Color(red: 0.88, green: 0.11, blue: 0.28),
            switchShadow: Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.30)
        )
    }

    private static func errorLight(base: MantaMaterialSpec) -> MantaMaterialSpec {
        MantaMaterialSpec(
            shadow: RGBColor(148, 28, 56),
            mid: RGBColor(212, 54, 88),
            bright: RGBColor(254, 198, 212),
            iridA: RGBColor(225, 29, 72),
            iridB: RGBColor(168, 85, 247),
            under: RGBColor(244, 146, 172),
            rim: RGBColor(255, 242, 246),
            spec: RGBColor(255, 255, 255),
            trail: RGBColor(225, 68, 102),
            auraColor: Color(red: 0.88, green: 0.11, blue: 0.28, opacity: 0.16),
            causticColor: Color(red: 1.0, green: 0.94, blue: 0.96, opacity: 0.40),
            heroTop: Color(red: 0.88, green: 0.11, blue: 0.28, opacity: 0.14),
            heroMid: Color(red: 0.88, green: 0.11, blue: 0.28, opacity: 0.04),
            accent: Color(red: 0.88, green: 0.11, blue: 0.28),
            accentSecondary: base.accent,
            chipBackground: Color(red: 0.88, green: 0.11, blue: 0.28, opacity: 0.12),
            chipForeground: Color(red: 0.75, green: 0.07, blue: 0.24),
            selectedBackground: base.selectedBackground,
            selectedBorder: base.selectedBorder,
            switchLeading: Color(red: 0.88, green: 0.11, blue: 0.28),
            switchTrailing: Color(red: 0.75, green: 0.07, blue: 0.24),
            switchShadow: Color(red: 0.88, green: 0.11, blue: 0.28, opacity: 0.22)
        )
    }

    private static func offDark(base: MantaMaterialSpec) -> MantaMaterialSpec {
        MantaMaterialSpec(
            shadow: RGBColor(54, 66, 86),
            mid: RGBColor(116, 132, 158),
            bright: RGBColor(188, 200, 218),
            iridA: RGBColor(148, 163, 184),
            iridB: RGBColor(176, 188, 208),
            under: RGBColor(152, 166, 188),
            rim: RGBColor(220, 230, 242),
            spec: RGBColor(244, 248, 255),
            trail: RGBColor(148, 163, 184),
            auraColor: Color(red: 0.58, green: 0.64, blue: 0.72, opacity: 0.08),
            causticColor: Color.white.opacity(0.02),
            heroTop: Color(red: 0.58, green: 0.64, blue: 0.72, opacity: 0.06),
            heroMid: Color.clear,
            accent: Color(red: 0.58, green: 0.64, blue: 0.72),
            accentSecondary: Color(red: 0.58, green: 0.64, blue: 0.72),
            chipBackground: Color(red: 0.58, green: 0.64, blue: 0.72, opacity: 0.16),
            chipForeground: Color(red: 0.65, green: 0.71, blue: 0.78),
            selectedBackground: base.selectedBackground,
            selectedBorder: base.selectedBorder,
            switchLeading: Color(red: 0.58, green: 0.64, blue: 0.72, opacity: 0.34),
            switchTrailing: Color(red: 0.58, green: 0.64, blue: 0.72, opacity: 0.34),
            switchShadow: .clear
        )
    }

    private static func offLight(base: MantaMaterialSpec) -> MantaMaterialSpec {
        MantaMaterialSpec(
            shadow: RGBColor(76, 88, 108),
            mid: RGBColor(128, 142, 164),
            bright: RGBColor(198, 208, 224),
            iridA: RGBColor(148, 163, 184),
            iridB: RGBColor(172, 184, 204),
            under: RGBColor(164, 176, 196),
            rim: RGBColor(244, 248, 252),
            spec: RGBColor(255, 255, 255),
            trail: RGBColor(140, 154, 176),
            auraColor: Color(red: 0.39, green: 0.45, blue: 0.55, opacity: 0.06),
            causticColor: Color.white.opacity(0.20),
            heroTop: Color(red: 0.39, green: 0.45, blue: 0.55, opacity: 0.06),
            heroMid: Color.clear,
            accent: Color(red: 0.45, green: 0.51, blue: 0.60),
            accentSecondary: Color(red: 0.45, green: 0.51, blue: 0.60),
            chipBackground: Color(red: 0.39, green: 0.45, blue: 0.55, opacity: 0.12),
            chipForeground: Color(red: 0.35, green: 0.41, blue: 0.50),
            selectedBackground: base.selectedBackground,
            selectedBorder: base.selectedBorder,
            switchLeading: Color(red: 0.39, green: 0.45, blue: 0.55, opacity: 0.28),
            switchTrailing: Color(red: 0.39, green: 0.45, blue: 0.55, opacity: 0.28),
            switchShadow: .clear
        )
    }
}
