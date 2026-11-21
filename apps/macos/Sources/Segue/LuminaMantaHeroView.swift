import Foundation
import SwiftUI

/// Thread-safe kinematics and wingtip vortex trail state stepped from SwiftUI `Canvas`
/// without mutating `@Published` properties or triggering main-actor warnings in Swift 6.
final class MantaKinematicsBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pointerTargetX: Double = 0
    private var pointerTargetY: Double = 0
    private var pointerX: Double = 0
    private var pointerY: Double = 0
    private var surge: Double = 0
    private var barrel: Double = 0
    private var rippleAge: Double = 99
    private var leftTrail: [MantaTrailPoint] = []
    private var rightTrail: [MantaTrailPoint] = []
    private var elapsed: Double = 1.25
    private var lastTimestamp: TimeInterval?
    private var preWarmedSize: CGSize = .zero
    private var lastVisualState: MantaVisualState?

    func updateHover(location: CGPoint, in size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        lock.lock()
        pointerTargetX = (Double(location.x / size.width) - 0.5) * 2.0
        pointerTargetY = (Double(location.y / size.height) - 0.5) * 2.0
        lock.unlock()
    }

    func endHover() {
        lock.lock()
        pointerTargetX = 0
        pointerTargetY = 0
        lock.unlock()
    }

    func triggerSwoop() {
        lock.lock()
        surge = 1.0
        barrel = 1.0
        rippleAge = 0
        lock.unlock()
    }

    func stepAndMakeInput(
        date: Date,
        size: CGSize,
        state: MantaVisualState,
        material: MantaMaterialSpec,
        isDark: Bool,
        calmMotion: Bool
    ) -> MantaRenderInput {
        lock.lock()
        defer { lock.unlock() }

        let now = date.timeIntervalSinceReferenceDate
        let rawDt = lastTimestamp.map { max(0.0, now - $0) } ?? 0.0
        let resumedFromPause = rawDt > 0.5
        let dt = resumedFromPause ? 0.0 : min(0.05, rawDt)
        lastTimestamp = now
        elapsed += dt

        let stateChangedToActive = (lastVisualState != state) && (state == .connected || state == .connecting)
        lastVisualState = state

        if size.width > 20 && size.height > 20 && (preWarmedSize != size || resumedFromPause || stateChangedToActive) {
            preWarmTrailsLocked(size: size, time: elapsed, state: state, calmMotion: calmMotion)
            preWarmedSize = size
        }

        let lerpRate = min(1.0, dt * 5.2)
        pointerX += (pointerTargetX - pointerX) * lerpRate
        pointerY += (pointerTargetY - pointerY) * lerpRate
        surge = max(0, surge - dt * 1.05)
        barrel = max(0, barrel - dt * 1.15)
        rippleAge += dt

        if dt > 0 {
            advanceTrailsLocked(size: size, time: elapsed, dt: dt, state: state, calmMotion: calmMotion)
        }

        return MantaRenderInput(
            time: elapsed,
            state: state,
            material: material,
            isDark: isDark,
            calmMotion: calmMotion,
            pointerX: pointerX,
            pointerY: pointerY,
            surge: surge,
            barrel: barrel,
            rippleAge: rippleAge,
            leftTrail: leftTrail,
            rightTrail: rightTrail
        )
    }

    private func preWarmTrailsLocked(size: CGSize, time: Double, state: MantaVisualState, calmMotion: Bool) {
        leftTrail.removeAll(keepingCapacity: true)
        rightTrail.removeAll(keepingCapacity: true)
        guard !calmMotion, state == .connected || state == .connecting else { return }
        let stepDt = 0.032
        for k in 0..<32 {
            let simT = max(0, time - Double(32 - k) * stepDt)
            advanceTrailsLocked(size: size, time: simT, dt: stepDt, state: state, calmMotion: false)
        }
    }

    private func advanceTrailsLocked(
        size: CGSize,
        time: Double,
        dt: Double,
        state: MantaVisualState,
        calmMotion: Bool
    ) {
        guard !calmMotion else {
            leftTrail.removeAll(keepingCapacity: true)
            rightTrail.removeAll(keepingCapacity: true)
            return
        }
        let tips = LuminaMantaEngine.wingtipScreenPositions(
            size: size,
            time: time,
            state: state,
            calmMotion: false,
            pointerX: pointerX,
            pointerY: pointerY,
            surge: surge,
            barrel: barrel
        )

        let activeFlow = state == .connected || state == .connecting
        if activeFlow {
            leftTrail.insert(MantaTrailPoint(x: Double(tips.left.x), y: Double(tips.left.y), life: 1.0), at: 0)
            rightTrail.insert(MantaTrailPoint(x: Double(tips.right.x), y: Double(tips.right.y), life: 1.0), at: 0)
        }

        let scaleFactor = max(0.5, Double(size.width) / 348.0)
        let vx = ((state == .connecting ? -84.0 : -46.0) - surge * 76.0) * scaleFactor
        let vy = ((state == .connecting ? 22.0 : 14.0) + surge * 13.0) * scaleFactor
        let decay = state == .connecting ? 1.30 : 0.88

        updateTrailLocked(&leftTrail, vx: vx, vy: vy, time: time, dt: dt, decay: decay)
        updateTrailLocked(&rightTrail, vx: vx, vy: vy, time: time, dt: dt, decay: decay)
    }

    private func updateTrailLocked(
        _ trail: inout [MantaTrailPoint],
        vx: Double,
        vy: Double,
        time: Double,
        dt: Double,
        decay: Double
    ) {
        var idx = trail.count - 1
        while idx >= 0 {
            trail[idx].x += vx * dt
            trail[idx].y += (vy + sin(time * 3.0 + Double(idx) * 0.25) * 3.2) * dt
            trail[idx].life -= dt * decay
            if trail[idx].life <= 0 || idx >= 34 {
                trail.remove(at: idx)
            }
            idx -= 1
        }
    }
}

/// Coordinates interactive swoop impulses and brief hero toast pills.
@MainActor
final class MantaMotionController: ObservableObject {
    @Published private(set) var toastMessage: String?

    let kinematics = MantaKinematicsBuffer()
    private var toastTask: Task<Void, Never>?

    func updateHover(location: CGPoint, in size: CGSize) {
        kinematics.updateHover(location: location, in: size)
    }

    func endHover() {
        kinematics.endHover()
    }

    func triggerSwoop(toast: String? = nil) {
        kinematics.triggerSwoop()
        if let toast {
            showToast(toast)
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                self?.toastMessage = nil
            }
        }
    }

    func clearToast() {
        toastTask?.cancel()
        toastTask = nil
        toastMessage = nil
    }
}

/// Interactive 142pt panoramic 3D Lumina Manta viewport inside the menu-bar popover.
/// Pauses automatically when the popover is hidden or reduced motion is active (0% GPU).
struct LuminaMantaHeroView: View {
    @ObservedObject var controller: MantaMotionController
    let visualState: MantaVisualState
    let material: MantaMaterialSpec
    let isDark: Bool
    let isPopoverOpen: Bool
    let calmMotion: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var effectiveCalm: Bool {
        calmMotion || systemReduceMotion
    }

    private var isPaused: Bool {
        !isPopoverOpen || (effectiveCalm && visualState != .connecting)
    }

    var body: some View {
        let kinematics = controller.kinematics
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                TimelineView(.animation(paused: isPaused)) { timeline in
                    Canvas { context, size in
                        let input = kinematics.stepAndMakeInput(
                            date: timeline.date,
                            size: size,
                            state: visualState,
                            material: material,
                            isDark: isDark,
                            calmMotion: effectiveCalm
                        )
                        LuminaMantaEngine.drawHero(in: &context, size: size, input: input)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard !effectiveCalm else { return }
                    switch phase {
                    case let .active(location):
                        controller.updateHover(location: location, in: proxy.size)
                    case .ended:
                        controller.endHover()
                    }
                }
                .onTapGesture {
                    if visualState != .off && !effectiveCalm {
                        controller.triggerSwoop()
                    }
                }

                if let toast = controller.toastMessage {
                    Text(toast)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(material.chipForeground)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(material.chipBackground)
                                .overlay(
                                    Capsule()
                                        .stroke(material.selectedBorder, lineWidth: 0.8)
                                )
                        )
                        .padding(.trailing, 12)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .frame(height: 142)
    }
}
