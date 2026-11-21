import AppKit
import SegueKit
import SwiftUI

/// Refined 348pt macOS menu-bar utility popover driven exclusively by
/// `ConnectionModel` read-backs and the 3D sculpted Lumina Manta hero.
struct SeguePopoverView: View {
    @ObservedObject var model: ConnectionModel
    @AppStorage("segue.materialTheme") private var materialThemeRaw: String = MantaMaterialTheme.pearl.rawValue
    @AppStorage("segue.calmMotion") private var calmMotion: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var motion = MantaMotionController()

    @State private var isMenuOpen = false
    @State private var showingSettings = false
    @State private var exitsExpanded = false
    @State private var diagnosticsExpanded = false
    @State private var showingQuitNotice = false
    @State private var pendingThemeToast: String?

    private var theme: MantaMaterialTheme {
        MantaMaterialTheme(rawValue: materialThemeRaw) ?? .pearl
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var visualState: MantaVisualState {
        MantaVisualState.from(model: model)
    }

    private var material: MantaMaterialSpec {
        MantaMaterialSpec.resolve(theme: theme, state: visualState, isDark: isDark)
    }

    private var surfaceFill: Color {
        isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.036)
    }

    private var hairlineColor: Color {
        isDark ? Color.white.opacity(0.085) : Color.black.opacity(0.075)
    }

    private var mutedText: Color {
        isDark ? Color.white.opacity(0.66) : Color.black.opacity(0.58)
    }

    private var subtleText: Color {
        isDark ? Color.white.opacity(0.45) : Color.black.opacity(0.44)
    }

    private var dangerColor: Color {
        isDark ? Color(red: 0.98, green: 0.44, blue: 0.52) : Color(red: 0.78, green: 0.10, blue: 0.25)
    }

    private var warningColor: Color {
        isDark ? Color(red: 0.98, green: 0.75, blue: 0.14) : Color(red: 0.71, green: 0.35, blue: 0.02)
    }

    var body: some View {
        Group {
            if showingSettings {
                settingsView
                    .transition(.opacity)
            } else {
                mainView
                    .transition(.opacity)
            }
        }
        .frame(width: 348)
        .background(
            isDark
                ? Color(red: 0.09, green: 0.11, blue: 0.16).opacity(0.92)
                : Color(red: 0.985, green: 0.99, blue: 1.0).opacity(0.95)
        )
        .onAppear {
            isMenuOpen = true
            model.setMenuOpen(true)
        }
        .onDisappear {
            isMenuOpen = false
            showingSettings = false
            showingQuitNotice = false
            pendingThemeToast = nil
            model.cancelRestoreNetwork()
            model.setMenuOpen(false)
        }
    }

    // MARK: - Main Popover

    private var mainView: some View {
        VStack(spacing: 0) {
            heroSection
            if shouldShowAlertBanner {
                alertBanner
            }
            if model.restoreNeedsConfirmation {
                restoreConfirmBanner
            }
            bodySection
            footerSection
            if showingQuitNotice {
                quitNoticeBanner
            }
        }
    }

    private var heroSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Segue")
                    .font(.system(size: 13, weight: .semibold))
                Text(heroChipText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(material.chipForeground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(material.chipBackground)
                    )
                Spacer()
                if let since = model.connectedSince, model.showsConnected {
                    SessionUptimeText(since: since, isPaused: !isMenuOpen)
                        .foregroundStyle(subtleText)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingSettings = true
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(surfaceFill)
                        )
                }
                .buttonStyle(.plain)
                .help("偏好设置")
                .accessibilityLabel("偏好设置")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            LuminaMantaHeroView(
                controller: motion,
                visualState: visualState,
                material: material,
                isDark: isDark,
                isPopoverOpen: isMenuOpen,
                calmMotion: calmMotion
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(material.accent)
                            .frame(width: 8, height: 8)
                        Text(primaryStatusTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text(primaryStatusSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(mutedText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                SeguePowerSwitch(
                    isOn: switchIsOn,
                    isDisabled: model.isBusy || helperUnavailable || model.restoreNeedsConfirmation,
                    isDark: isDark,
                    material: material
                ) {
                    handlePowerToggle()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, 2)
        }
        .background(
            RadialGradient(
                colors: [material.heroTop, material.heroMid, .clear],
                center: UnitPoint(x: 0.54, y: 0.0),
                startRadius: 6,
                endRadius: 230
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(hairlineColor).frame(height: 1)
        }
    }

    private var bodySection: some View {
        VStack(spacing: 10) {
            dualGuaranteeStrip
            exitSelectorCard
            diagnosticsCard
        }
        .padding(12)
    }

    private var dualGuaranteeStrip: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("AI 专属锁")
                        .foregroundStyle(subtleText)
                    Spacer()
                    Text(aiLockBadgeText)
                        .fontWeight(.medium)
                        .foregroundStyle(aiLockBadgeColor)
                }
                .font(.system(size: 11))
                Text(aiLockDetailText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("普通流量")
                        .foregroundStyle(subtleText)
                    Spacer()
                    Text(ordinaryBadgeText)
                        .fontWeight(.medium)
                        .foregroundStyle(ordinaryBadgeColor)
                }
                .font(.system(size: 11))
                Text(ordinaryDetailText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private var exitSelectorCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    exitsExpanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("出口路线")
                            .font(.system(size: 11))
                            .foregroundStyle(subtleText)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(activeExitDotColor)
                                .frame(width: 6, height: 6)
                            Text(activeExitSummary)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Text(activeExitLatencyText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(mutedText)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(subtleText)
                            .rotationEffect(.degrees(exitsExpanded ? 180 : 0))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if exitsExpanded {
                Rectangle().fill(hairlineColor).frame(height: 1)
                if model.exitDetails.count > 4 {
                    ScrollView {
                        exitOptionsList
                    }
                    .frame(height: 224)
                } else {
                    exitOptionsList
                }
            }
        }
        .background(cardBackground)
    }

    private var exitOptionsList: some View {
        VStack(spacing: 3) {
            exitOptionRow(
                id: "auto",
                title: autoExitTitle,
                tag: "推荐",
                detail: "自动择优 · AI 固定出口",
                latency: activeExitQuality(for: model.currentExit)?.srttMs,
                qualityColor: canSwitchExits ? material.accent : subtleText,
                isSelected: model.exitChoice == "auto"
            )
            ForEach(model.exitDetails) { exit in
                exitOptionRow(
                    id: exit.name,
                    title: exit.name,
                    tag: exit.name == model.currentExit ? "当前" : nil,
                    detail: exitQualitySubtitle(exit.quality),
                    latency: exit.quality?.srttMs,
                    qualityColor: canSwitchExits ? qualityDotColor(exit.quality) : subtleText,
                    isSelected: model.exitChoice == exit.name
                )
            }
            if model.exitDetails.isEmpty {
                Text("连接内核后将自动载入可用出口列表")
                    .font(.system(size: 11))
                    .foregroundStyle(subtleText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .padding(6)
    }

    private func exitOptionRow(
        id: String,
        title: String,
        tag: String?,
        detail: String,
        latency: UInt64?,
        qualityColor: Color,
        isSelected: Bool
    ) -> some View {
        Button {
            guard canSwitchExits, id != model.exitChoice else { return }
            motion.triggerSwoop(toast: id == "auto" ? "正在切换至自动优选…" : "正在滑切至 \(id)…")
            Task {
                await model.selectExit(id)
                if model.lastError != nil {
                    motion.clearToast()
                } else {
                    motion.showToast(id == "auto" ? "已切换至自动优选" : "已切换至 \(id)")
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(qualityColor)
                            .frame(width: 6, height: 6)
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let tag {
                            Text(tag)
                                .font(.system(size: 10))
                                .foregroundStyle(mutedText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(surfaceFill)
                                )
                        }
                    }
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(subtleText)
                        .padding(.leading, 12)
                }
                Spacer()
                Text(canSwitchExits ? (latency.map { "\($0) ms" } ?? "—") : "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(mutedText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? material.selectedBackground : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(isSelected ? material.selectedBorder : .clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSwitchExits)
        .opacity(canSwitchExits ? 1.0 : 0.60)
    }

    private var diagnosticsCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    diagnosticsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("保护自检与故障工具")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mutedText)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(subtleText)
                        .rotationEffect(.degrees(diagnosticsExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if diagnosticsExpanded {
                Rectangle().fill(hairlineColor).frame(height: 1)
                VStack(spacing: 8) {
                    healthRow(
                        "系统保护进程 (helper)",
                        value: helperHealthText,
                        tone: model.helperAvailability == .ready ? .ok : (helperUnavailable ? .danger : .muted)
                    )
                    healthRow(
                        "AI 护盾 / DNS",
                        value: aiLayerHealthText,
                        tone: aiLayerHealthTone
                    )
                    healthRow(
                        "签名策略 (Ed25519)",
                        value: policyHealthText,
                        tone: model.policyValid ? .ok : (model.policyVersion != nil ? .warning : .muted)
                    )
                    healthRow(
                        "隧道接口 (utun)",
                        value: model.tunInterface ?? "未建立",
                        tone: model.tunInterface != nil ? .ok : .muted
                    )

                    HStack(spacing: 6) {
                        Button("配置目录") {
                            openConfigFolder()
                        }
                        .buttonStyle(SegueSecondaryButtonStyle(fill: surfaceFill, hairline: hairlineColor))

                        Button("导出诊断包") {
                            exportDiagnostics()
                        }
                        .buttonStyle(SegueSecondaryButtonStyle(fill: surfaceFill, hairline: hairlineColor))

                        Button("网络急救") {
                            requestEmergencyRestore()
                        }
                        .buttonStyle(
                            SegueSecondaryButtonStyle(
                                fill: surfaceFill,
                                hairline: hairlineColor,
                                foreground: dangerColor
                            )
                        )
                        .disabled(model.isBusy || model.restoreNeedsConfirmation)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(cardBackground)
    }

    private enum HealthTone {
        case ok
        case warning
        case danger
        case muted
    }

    private var aiLayerHealthTone: HealthTone {
        if model.aiLayerMode == AILayerState.degraded || model.aiListError != nil {
            return .danger
        }
        if model.aiLayerMode == AILayerState.tunnel {
            return .ok
        }
        if model.aiLayerMode == AILayerState.guardMode || model.helperArmed {
            return .warning
        }
        return .muted
    }

    private func healthRow(_ label: String, value: String, tone: HealthTone) -> some View {
        let color: Color = {
            switch tone {
            case .ok:
                return material.accent
            case .warning:
                return warningColor
            case .danger:
                return dangerColor
            case .muted:
                return subtleText
            }
        }()
        return HStack {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(mutedText)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(color)
        }
    }

    // MARK: - Alert & Restore Banners

    private var visibleError: String? {
        guard let error = model.lastError else { return nil }
        if MantaVisualState.isExpectedIdleKernelError(error, model: model) {
            return nil
        }
        return error
    }

    private var helperDiagnosticDetail: String? {
        if let aiListError = model.aiListError, !aiListError.isEmpty {
            return "AI 名单异常：\(aiListError)"
        }
        if model.aiLayerMode == AILayerState.degraded {
            if let helperErr = model.helperLastError, !helperErr.isEmpty {
                return "AI 护盾降级（\(helperErr)），请恢复网络或导出诊断包。"
            }
            return "AI 护盾处于降级状态，部分规则未完整生效。"
        }
        if model.helperKernelState == "kernel_failed", let stderr = model.helperKernelLastStderr {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let firstLine = trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? trimmed
                return "内核退出详情：\(String(firstLine.prefix(120)))"
            }
        }
        if let helperErr = model.helperLastError, !helperErr.isEmpty, helperErr != "kernel_failed" {
            return "保护服务报错：\(helperErr)"
        }
        return nil
    }

    private var canOfferDirectReconnect: Bool {
        guard !model.restoreNeedsConfirmation, !helperUnavailable, !model.isRevoked else {
            return false
        }
        return (model.showsConnected && model.hasControlRefusal)
            || (model.helperArmed && !model.showsConnected && !model.isConnecting)
    }

    private var canOfferDirectEmergencyRestore: Bool {
        guard !model.restoreNeedsConfirmation else { return false }
        return helperUnavailable
            || model.helperKernelState == "kernel_failed"
            || model.aiLayerMode == AILayerState.degraded
            || model.aiListError != nil
            || (visibleError != nil && model.helperArmed)
            || (model.isRevoked && model.helperArmed)
    }

    private var shouldShowAlertBanner: Bool {
        helperUnavailable
            || visibleError != nil
            || model.notice != nil
            || !model.reasonText.isEmpty
            || (model.showsConnected && model.hasControlRefusal)
            || helperDiagnosticDetail != nil
            || canOfferDirectReconnect
    }

    private var alertBannerIsDanger: Bool {
        visibleError != nil
            || helperUnavailable
            || model.isRevoked
            || model.helperKernelState == "kernel_failed"
            || model.aiLayerMode == AILayerState.degraded
            || model.aiListError != nil
    }

    private var alertBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(material.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.showsConnected && model.hasControlRefusal {
                Text("部分中继拒绝了控制通道，建议重新连接或更新 Segue。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = visibleError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(dangerColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.reasonText.isEmpty {
                Text(model.reasonText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = helperDiagnosticDetail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(dangerColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canOfferDirectReconnect || helperUnavailable || canOfferDirectEmergencyRestore {
                HStack(spacing: 6) {
                    if canOfferDirectReconnect {
                        Button("重新连接") {
                            motion.triggerSwoop(toast: "正在尝试重新连接…")
                            Task {
                                await model.connect()
                            }
                        }
                        .buttonStyle(
                            SegueSecondaryButtonStyle(
                                fill: material.selectedBackground,
                                hairline: material.selectedBorder,
                                foreground: material.chipForeground
                            )
                        )
                        .disabled(model.isBusy)
                    }
                    if helperUnavailable {
                        Button("重新检测") {
                            Task {
                                await model.refresh()
                            }
                        }
                        .buttonStyle(SegueSecondaryButtonStyle(fill: surfaceFill, hairline: hairlineColor))
                        .disabled(model.isBusy)
                    }
                    if canOfferDirectEmergencyRestore {
                        Button("急救恢复网络") {
                            requestEmergencyRestore()
                        }
                        .buttonStyle(
                            SegueSecondaryButtonStyle(
                                fill: Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.14),
                                hairline: Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.32),
                                foreground: dangerColor
                            )
                        )
                        .disabled(model.isBusy)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            alertBannerIsDanger
                ? Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.10)
                : surfaceFill
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(hairlineColor).frame(height: 1)
        }
    }

    private var restoreConfirmBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("恢复系统网络将立即断开隧道并解除 AI 锁（必要时通过独立 segue-release 守护进程清理 PF 与 DNS）。确认前不会修改系统状态。")
                .font(.system(size: 11.5))
                .foregroundStyle(isDark ? Color.white.opacity(0.90) : Color.black.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("确认恢复网络") {
                    Task {
                        await model.confirmRestoreNetwork()
                    }
                }
                .buttonStyle(
                    SegueSecondaryButtonStyle(
                        fill: Color(red: 0.96, green: 0.25, blue: 0.37),
                        hairline: .clear,
                        foreground: .white
                    )
                )
                Button("取消") {
                    model.cancelRestoreNetwork()
                }
                .buttonStyle(SegueSecondaryButtonStyle(fill: surfaceFill, hairline: hairlineColor))
            }
            .disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.96, green: 0.25, blue: 0.37, opacity: 0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(hairlineColor).frame(height: 1)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            HStack(spacing: 7) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [material.switchLeading, material.switchTrailing],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 18, height: 18)
                    .overlay(
                        Text("S")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(footerSummaryText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
            }
            Spacer()
            Button(showingQuitNotice ? "确认退出" : "退出图标") {
                if showingQuitNotice {
                    NSApp.terminate(nil)
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showingQuitNotice = true
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(showingQuitNotice ? warningColor : mutedText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(hairlineColor).frame(height: 1)
        }
    }

    private var quitNoticeBanner: some View {
        HStack {
            Text(
                switchIsOn
                    ? "退出菜单栏图标不会解除 AI 保护锁，如需彻底关闭请先拨动上方总开关。"
                    : "确认退出顶部菜单栏图标？随时可从「应用程序」重新打开。"
            )
            .font(.system(size: 11))
            .foregroundStyle(switchIsOn ? warningColor : mutedText)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("取消") {
                withAnimation(.easeInOut(duration: 0.14)) {
                    showingQuitNotice = false
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(mutedText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            switchIsOn
                ? Color(red: 0.96, green: 0.62, blue: 0.04, opacity: 0.12)
                : surfaceFill
        )
    }

    // MARK: - Inline Settings Subpage

    private var settingsView: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    let toast = pendingThemeToast
                    pendingThemeToast = nil
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingSettings = false
                    }
                    if let toast {
                        if calmMotion {
                            motion.showToast(toast)
                        } else {
                            motion.triggerSwoop(toast: toast)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(mutedText)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("偏好设置")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 42, height: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(hairlineColor).frame(height: 1)
            }

            VStack(spacing: 12) {
                // 4 Luxury Material Finishes Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("灵鳐实体材质")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(mutedText)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(MantaMaterialTheme.allCases) { item in
                            let selected = item == theme
                            Button {
                                guard item != theme else { return }
                                materialThemeRaw = item.rawValue
                                pendingThemeToast = "材质：\(item.displayName)"
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: item.swatchColors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 14, height: 14)
                                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.displayName)
                                            .font(.system(size: 12, weight: .medium))
                                        Text(item.subtitle)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(subtleText)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(material.accent)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selected ? material.selectedBackground : surfaceFill)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(selected ? material.selectedBorder : hairlineColor, lineWidth: 1)
                                        )
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
                .background(cardBackground)

                // Motion & Utility Controls
                VStack(spacing: 10) {
                    Toggle(isOn: $calmMotion) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("柔和动效模式")
                                .font(.system(size: 12, weight: .medium))
                            Text("稳态降低动画刷新，同步尊重系统减弱动态效果")
                                .font(.system(size: 10.5))
                                .foregroundStyle(subtleText)
                        }
                    }
                    .toggleStyle(.switch)

                    Rectangle().fill(hairlineColor).frame(height: 1)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("配置与签名策略目录")
                                .font(.system(size: 12, weight: .medium))
                            Text("存放 kernel.json 与签名策略包，无需账号")
                                .font(.system(size: 10.5))
                                .foregroundStyle(subtleText)
                        }
                        Spacer()
                        Button("打开") {
                            openConfigFolder()
                        }
                        .buttonStyle(SegueSecondaryButtonStyle(fill: surfaceFill, hairline: hairlineColor))
                    }
                }
                .padding(12)
                .background(cardBackground)

                Text("Segue macOS · Helper 协议 v\(HelperProtocolVersion.current)")
                    .font(.system(size: 11))
                    .foregroundStyle(subtleText)
                    .padding(.top, 2)
            }
            .padding(14)
        }
    }

    // MARK: - Helpers & Derived Copy

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(surfaceFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(hairlineColor, lineWidth: 1)
            )
    }

    private var helperUnavailable: Bool {
        switch model.helperAvailability {
        case .notInstalled, .versionMismatch, .unauthorized:
            return true
        case .unknown, .ready:
            return false
        }
    }

    private var switchIsOn: Bool {
        model.showsConnected || model.isConnecting || model.isGuarding || model.helperArmed
    }

    private var canSwitchExits: Bool {
        guard !model.isBusy, !helperUnavailable, !model.isRevoked else {
            return false
        }
        guard let kernelState = model.kernelState else {
            return false
        }
        return kernelState == .connected || kernelState == .reconnecting
    }

    private var heroChipText: String {
        switch visualState {
        case .connected:
            return "AI 锁已生效"
        case .connecting:
            return "正在锁定 AI"
        case .guarding:
            return "仅锁 AI · 不泄漏"
        case .error:
            return "需要处理"
        case .off:
            return "未开启"
        }
    }

    private var primaryStatusTitle: String {
        switch visualState {
        case .connected:
            return "已保护连接"
        case .connecting:
            return "正在跃动建连…"
        case .guarding:
            return "隧道重连中"
        case .error:
            if model.isRevoked {
                return "设备已吊销"
            }
            if model.aiLayerMode == AILayerState.degraded || model.aiListError != nil {
                return "AI 护盾降级"
            }
            if model.helperKernelState == "kernel_failed" {
                return "内核服务异常"
            }
            switch model.helperAvailability {
            case .notInstalled:
                return "未安装保护服务"
            case .versionMismatch:
                return "保护服务版本不匹配"
            case .unauthorized:
                return "保护服务拒绝连接"
            case .unknown, .ready:
                return "连接出现异常"
            }
        case .off:
            return "保护已关闭"
        }
    }

    private var primaryStatusSubtitle: String {
        switch visualState {
        case .connected:
            if let exit = model.currentExit {
                return "AI 固定走 \(exit) · 普通流量智能分流"
            }
            return "AI 流量已锁定隧道 · 普通流量智能分流"
        case .connecting:
            return "本地 Guard 已先接管 AI 域名，正在建立载波"
        case .guarding:
            return "AI 域名已被安全护盾拦住，普通网页照常访问"
        case .error:
            if model.isRevoked {
                return "此设备访问权限已被撤销，请解除保护或重新配置"
            }
            if model.aiLayerMode == AILayerState.degraded || model.aiListError != nil {
                return "规则未能完整写入系统，请查看下方详情或恢复网络"
            }
            if model.helperKernelState == "kernel_failed" {
                return "内核未能正常启动，可先重新连接或恢复网络"
            }
            switch model.helperAvailability {
            case .notInstalled:
                return "请先通过 Segue 安装镜像安装系统保护服务"
            case .versionMismatch:
                return "App 与后台保护服务协议版本不一致，请同步更新"
            case .unauthorized:
                return "系统保护服务拒绝了当前应用的签名授权"
            case .unknown, .ready:
                return model.statusLine
            }
        case .off:
            return "当前全部流量直连，拨动开关唤醒灵鳐"
        }
    }

    private var aiLockBadgeText: String {
        switch visualState {
        case .connected:
            return "隧道锁定"
        case .connecting:
            return "先锁后连"
        case .guarding:
            return "Guard 拦截"
        case .error:
            if model.aiLayerMode == AILayerState.degraded || model.aiListError != nil {
                return "护盾降级"
            }
            return model.helperArmed ? "内核级保持" : "未就绪"
        case .off:
            return "已解除"
        }
    }

    private var aiLockBadgeColor: Color {
        visualState == .off ? subtleText : material.accent
    }

    private var aiLockDetailText: String {
        switch visualState {
        case .connected:
            if let exit = model.currentExit {
                return "固定 \(exit) 出口"
            }
            return "固定 IDC 出口"
        case .connecting:
            return "Guard 防泄漏拦截中"
        case .guarding:
            return "空 NOERROR · 绝不直连"
        case .error:
            if model.aiLayerMode == AILayerState.degraded || model.aiListError != nil {
                return "规则未完整生效"
            }
            return model.helperArmed ? "规则仍在保护中" : "等待保护服务就绪"
        case .off:
            return "未拦截 AI 流量"
        }
    }

    private var ordinaryBadgeText: String {
        switch visualState {
        case .connected:
            return "智能分流"
        case .connecting, .guarding:
            return "直连可用"
        case .error, .off:
            return "系统默认"
        }
    }

    private var ordinaryBadgeColor: Color {
        visualState == .off ? subtleText : material.accentSecondary
    }

    private var ordinaryDetailText: String {
        switch visualState {
        case .connected:
            return "国内直连 · 海外加速"
        case .connecting, .guarding:
            return "未拖垮整机网络"
        case .error, .off:
            return "全部直接连接"
        }
    }

    private var autoExitTitle: String {
        if let current = model.currentExit {
            return "自动优选 · \(current)"
        }
        return "自动优选 (auto)"
    }

    private var activeExitSummary: String {
        if model.exitChoice == "auto" {
            return autoExitTitle
        }
        return model.exitChoice
    }

    private var activeExitLatencyText: String {
        guard model.showsConnected || model.kernelState == .connected else {
            return "—"
        }
        let target = model.currentExit ?? model.exitChoice
        if let ms = activeExitQuality(for: target)?.srttMs {
            return "\(ms) ms"
        }
        return "—"
    }

    private var activeExitDotColor: Color {
        guard model.showsConnected else { return subtleText }
        let target = model.currentExit ?? model.exitChoice
        return qualityDotColor(activeExitQuality(for: target))
    }

    private var helperHealthText: String {
        switch model.helperAvailability {
        case .ready:
            return "运行中 · v\(HelperProtocolVersion.current)"
        case .notInstalled:
            return "未安装"
        case .versionMismatch:
            return "版本不匹配"
        case .unauthorized:
            return "未授权"
        case .unknown:
            return "检测中"
        }
    }

    private var aiLayerHealthText: String {
        switch (model.aiLayerMode, model.dnsMode) {
        case let (layer?, dns?):
            return "\(layer) · dns:\(dns)"
        case let (layer?, nil):
            return layer
        default:
            return model.helperArmed ? "armed" : "未启用"
        }
    }

    private var policyHealthText: String {
        if let version = model.policyVersion {
            return model.policyValid ? "有效 · v\(version)" : "已失效 · v\(version)"
        }
        return model.policyValid ? "内置策略有效" : "未载入"
    }

    private var footerSummaryText: String {
        if let tun = model.tunInterface, model.showsConnected {
            return "\(tun) · \(theme.displayName)"
        }
        return "纯顶部菜单栏 · \(theme.displayName)"
    }

    private func activeExitQuality(for name: String?) -> KernelExitQuality? {
        guard let name else { return nil }
        return model.exitDetails.first(where: { $0.name == name })?.quality
    }

    private func exitQualitySubtitle(_ quality: KernelExitQuality?) -> String {
        guard let quality else {
            return "等待链路探测"
        }
        var parts: [String] = []
        if quality.loss > 0 {
            parts.append("丢包 \(Int((quality.loss * 100).rounded()))%")
        } else {
            parts.append("0% 丢包")
        }
        if quality.stalls > 0 {
            parts.append("停顿 \(quality.stalls)")
        } else {
            parts.append("链路平稳")
        }
        return parts.joined(separator: " · ")
    }

    private func qualityDotColor(_ quality: KernelExitQuality?) -> Color {
        guard let quality else { return material.accent }
        if quality.stalls > 0 || quality.loss >= 0.02 || (quality.srttMs ?? 0) >= 200 {
            return warningColor
        }
        return material.accent
    }

    // MARK: - Actions

    private func handlePowerToggle() {
        guard !model.isBusy else { return }
        if switchIsOn {
            Task {
                await model.disconnect()
            }
        } else {
            motion.triggerSwoop()
            Task {
                await model.connect()
            }
        }
    }

    private func requestEmergencyRestore() {
        withAnimation(.easeInOut(duration: 0.16)) {
            exitsExpanded = false
            showingQuitNotice = false
        }
        model.requestRestoreNetwork()
    }

    private func openConfigFolder() {
        do {
            try model.ensureConfigFolder()
            activateApp()
            guard NSWorkspace.shared.open(model.configFolder) else {
                model.present(error: "Couldn't open the config folder.")
                return
            }
        } catch {
            model.present(error: "Couldn't open the config folder.")
        }
    }

    private func exportDiagnostics() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the redacted diagnostics zip."
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            _ = try model.exportDiagnosticsZip(to: url)
            model.present(notice: "Diagnostics exported.")
        } catch {
            model.present(error: "Couldn't write the diagnostics file.")
        }
    }

    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Supporting Controls

private struct SessionUptimeText: View {
    let since: Date
    let isPaused: Bool

    var body: some View {
        if isPaused {
            Text(Self.format(interval: max(0, Date().timeIntervalSince(since))))
                .font(.system(size: 11, design: .monospaced))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(Self.format(interval: max(0, timeline.date.timeIntervalSince(since))))
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private static func format(interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private struct SeguePowerSwitch: View {
    let isOn: Bool
    let isDisabled: Bool
    let isDark: Bool
    let material: MantaMaterialSpec
    let action: () -> Void

    private var trackColors: [Color] {
        if isOn {
            return [material.switchLeading, material.switchTrailing]
        }
        let muted = isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.14)
        return [muted, muted]
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: trackColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 27)
                    .shadow(color: isOn ? material.switchShadow : .clear, radius: 8, y: 2)

                Circle()
                    .fill(Color.white)
                    .frame(width: 21, height: 21)
                    .shadow(color: Color.black.opacity(0.24), radius: 3, y: 1)
                    .padding(3)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1.0)
        .accessibilityLabel(isOn ? "断开保护" : "开启保护")
    }
}

private struct SegueSecondaryButtonStyle: ButtonStyle {
    let fill: Color
    let hairline: Color
    var foreground: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(foreground ?? Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.72 : 1.0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(hairline, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}
