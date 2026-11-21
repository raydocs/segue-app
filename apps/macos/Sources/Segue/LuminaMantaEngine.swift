import AppKit
import CoreGraphics
import Foundation
import SwiftUI

struct MantaPoint3D: Sendable {
    let x: Double
    let y: Double
    let z: Double
}

struct MantaProjectedVertex: Sendable {
    let x: Double
    let y: Double
    let z: Double
    let sx: Double
    let sy: Double
    let u: Double
    let v: Double
    let a: Double
}

struct MantaCameraConfig: Sendable {
    let cx: Double
    let cy: Double
    let scale: Double
    let yaw: Double
    let pitch: Double
    let roll: Double
    let elev: Double
}

struct MantaTrailPoint: Sendable {
    var x: Double
    var y: Double
    var life: Double
}

struct MantaRenderInput: Sendable {
    let time: Double
    let state: MantaVisualState
    let material: MantaMaterialSpec
    let isDark: Bool
    let calmMotion: Bool
    let pointerX: Double
    let pointerY: Double
    let surge: Double
    let barrel: Double
    let rippleAge: Double
    let leftTrail: [MantaTrailPoint]
    let rightTrail: [MantaTrailPoint]
}

/// Pure procedural 3D sculpted Lumina Manta geometry, lighting, and renderer.
/// Renders both the 12x34 liquid-glass popover hero (SwiftUI `Canvas`) and the
/// 3/4 sculpted monochrome template icon for the macOS top menu bar (`NSImage`).
enum LuminaMantaEngine {
    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, x))
    }

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Samples one vertex on the parametric 3D manta surface `P(u, v)` where
    /// `u` runs head -> trailing edge `[0, 1]` and `v` runs left -> right tip `[-1, 1]`.
    static func samplePoint(
        u: Double,
        v: Double,
        t: Double,
        speed: Double,
        spread: Double,
        rollTwist: Double
    ) -> MantaPoint3D {
        let a = abs(v)
        let sgn = v < 0 ? -1.0 : 1.0

        // Swept falcon pectoral leading edge + softly rounded forward cephalic lobes.
        let ceph = 0.19 * exp(-pow((a - 0.11) / 0.060, 2.0))
        let xLead = 0.43 - 0.77 * pow(a, 1.44) + ceph
        let tLinear = -0.58 * (1.0 - a) - 0.34 * a
        let scoop = 0.175 * sin(pow(a, 0.72) * .pi) * (1.0 - a * 0.36)
        let xBase = mix(xLead, tLinear + scoop, u)

        // Radial + chordwise underwater traveling silk wave.
        let wavePhase = t * speed - a * 2.42 - u * 0.88
        let rawWave = sin(wavePhase)
        let waveAmp = pow(a, 1.26) * 0.43 * spread
        let bankFlex = sgn * rollTwist * pow(a, 1.2) * 0.15

        // Conservation-of-length subtle span pull-in at peak deflection.
        let spanPull = 1.0 - 0.14 * pow(rawWave * a, 2.0)
        let zLocal = sgn * 1.18 * pow(a, 0.90) * spread * spanPull

        let torsoEnv = exp(-pow(a / 0.25, 2.0)) * pow(max(0, sin(u * .pi)), 0.74)
        let dorsalDome = 0.115 * torsoEnv
        let cephCurl = -0.048 * exp(-pow((a - 0.11) / 0.056, 2.0)) * max(0.0, 1.0 - u * 4.2)
        let spineUndulate = 0.040 * sin(t * speed + 0.55 - u * 1.12) * (1.0 - a * 0.5)
        let yLocal = dorsalDome + cephCurl + spineUndulate + rawWave * waveAmp + bankFlex

        return MantaPoint3D(x: xBase, y: yLocal, z: zLocal)
    }

    static func project(_ pt: MantaPoint3D, config: MantaCameraConfig) -> MantaProjectedVertex {
        let cr = cos(config.roll)
        let sr = sin(config.roll)
        let y1 = pt.y * cr - pt.z * sr
        let z1 = pt.y * sr + pt.z * cr

        let cp = cos(config.pitch)
        let sp = sin(config.pitch)
        let x2 = pt.x * cp - y1 * sp
        let y2 = pt.x * sp + y1 * cp

        let cy = cos(config.yaw)
        let sy = sin(config.yaw)
        let x3 = x2 * cy + z1 * sy
        let z3 = -x2 * sy + z1 * cy

        let ce = cos(config.elev)
        let se = sin(config.elev)
        let y4 = y2 * ce - z3 * se
        let z4 = y2 * se + z3 * ce

        let camDist = 4.6
        let persp = camDist / (camDist - z4)
        return MantaProjectedVertex(
            x: x3,
            y: y4,
            z: z4,
            sx: config.cx + x3 * config.scale * persp,
            sy: config.cy - y4 * config.scale * persp,
            u: 0,
            v: 0,
            a: 0
        )
    }

    static func computeCamera(
        size: CGSize,
        time: Double,
        state: MantaVisualState,
        calmMotion: Bool,
        pointerX: Double,
        pointerY: Double,
        surge: Double,
        barrel: Double
    ) -> (config: MantaCameraConfig, effT: Double, speed: Double, spread: Double) {
        let w = Double(size.width)
        let h = Double(size.height)
        let resting = state == .off
        let guarding = state == .guarding
        let connecting = state == .connecting

        let effT = calmMotion ? time * 0.25 : time
        let cycle = effT.truncatingRemainder(dividingBy: 4.0)
        let burst: Double
        if !calmMotion && !resting && !guarding && cycle < 1.45 {
            burst = sin((cycle / 1.45) * .pi)
        } else {
            burst = 0
        }

        let boost = calmMotion ? 0 : surge
        let speed: Double
        if resting {
            speed = 1.1
        } else if connecting {
            speed = 4.8
        } else if guarding {
            speed = 3.1
        } else {
            speed = 2.35 + burst * 0.9 + boost * 3.0
        }

        let spread: Double = resting ? 0.64 : (guarding ? 0.72 : 1.0)
        let driftX = (resting || calmMotion)
            ? 0
            : sin(effT * 0.85) * (w * 0.028) + pointerX * (w * 0.045) + boost * (w * 0.042)
        let driftY = (resting || calmMotion)
            ? 0
            : sin(effT * speed - 0.5) * (h * 0.036) + pointerY * (h * 0.048)
        let barrelRoll = calmMotion ? 0 : sin(barrel * .pi) * 0.58

        let yaw = 0.48 + (calmMotion ? 0 : pointerX * 0.16 + sin(effT * 0.7) * 0.06)
        let pitchBase = resting ? -0.02 : (connecting ? 0.14 : 0.06)
        let pitch = pitchBase + (calmMotion ? 0 : -pointerY * 0.18 + cos(effT * speed) * 0.045 + boost * 0.11)
        let rollBase = resting ? 0.06 : 0.16
        let roll = rollBase + (calmMotion ? 0 : sin(effT * 0.85) * 0.09 - pointerY * 0.22 + barrelRoll)
        let elev = 0.36 + (calmMotion ? 0 : pointerY * 0.09)

        let config = MantaCameraConfig(
            cx: w * 0.52 + driftX,
            cy: h * 0.49 + driftY,
            scale: min(w * 0.195, h * 0.42),
            yaw: yaw,
            pitch: pitch,
            roll: roll,
            elev: elev
        )
        return (config, effT, speed, spread)
    }

    static func wingtipScreenPositions(
        size: CGSize,
        time: Double,
        state: MantaVisualState,
        calmMotion: Bool,
        pointerX: Double,
        pointerY: Double,
        surge: Double,
        barrel: Double
    ) -> (left: CGPoint, right: CGPoint) {
        let params = computeCamera(
            size: size,
            time: time,
            state: state,
            calmMotion: calmMotion,
            pointerX: pointerX,
            pointerY: pointerY,
            surge: surge,
            barrel: barrel
        )
        let leftPt = project(
            samplePoint(u: 0.52, v: -1.0, t: params.effT, speed: params.speed, spread: params.spread, rollTwist: params.config.roll),
            config: params.config
        )
        let rightPt = project(
            samplePoint(u: 0.52, v: 1.0, t: params.effT, speed: params.speed, spread: params.spread, rollTwist: params.config.roll),
            config: params.config
        )
        return (CGPoint(x: leftPt.sx, y: leftPt.sy), CGPoint(x: rightPt.sx, y: rightPt.sy))
    }

    /// Renders the high-resolution 12x34 liquid-glass 3D manta into a SwiftUI `GraphicsContext`.
    static func drawHero(in context: inout GraphicsContext, size: CGSize, input: MantaRenderInput) {
        let w = Double(size.width)
        let h = Double(size.height)
        guard w > 10, h > 10 else { return }

        let mat = input.material
        let resting = input.state == .off
        let guarding = input.state == .guarding
        let isError = input.state == .error
        let boost = input.calmMotion ? 0 : input.surge

        let params = computeCamera(
            size: size,
            time: input.time,
            state: input.state,
            calmMotion: input.calmMotion,
            pointerX: input.pointerX,
            pointerY: input.pointerY,
            surge: input.surge,
            barrel: input.barrel
        )
        let cfg = params.config
        let effT = params.effT
        let speed = params.speed
        let spread = params.spread

        // 1. Feathered volumetric underwater mist glow (no hard strips).
        if !resting {
            let c1 = CGPoint(x: w * 0.64 + sin(effT * 0.4) * 14, y: h * 0.16)
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [mat.causticColor, .clear]),
                    center: c1,
                    startRadius: 4,
                    endRadius: CGFloat(w * 0.44)
                )
            )
            let auraCenter = CGPoint(x: cfg.cx, y: cfg.cy)
            let auraRadius = cfg.scale * 1.52
            context.fill(
                Path(ellipseIn: CGRect(
                    x: auraCenter.x - auraRadius,
                    y: auraCenter.y - auraRadius,
                    width: auraRadius * 2,
                    height: auraRadius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [mat.auraColor, .clear]),
                    center: auraCenter,
                    startRadius: CGFloat(auraRadius * 0.06),
                    endRadius: CGFloat(auraRadius)
                )
            )
        }

        // 2. Guard / error protective orbital halo.
        if guarding || isError {
            var ringCtx = context
            ringCtx.translateBy(x: CGFloat(w * 0.52), y: CGFloat(h * 0.50))
            ringCtx.rotate(by: .radians(input.calmMotion ? 0 : effT * (guarding ? 0.85 : 0.45)))
            let rx = h * 0.43
            let ry = h * 0.30
            var ring = Path()
            ring.addEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            ringCtx.stroke(
                ring,
                with: .color(mat.rim.swiftColor(opacity: 0.42)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [14, 7])
            )
        }

        // 3. Click / exit-switch hydrodynamic ripple.
        if input.rippleAge < 1.1 && !input.calmMotion {
            let p = input.rippleAge / 1.1
            let rx = 18 + p * h * 0.65
            let ry = 10 + p * h * 0.36
            var ripple = Path()
            ripple.addEllipse(in: CGRect(x: w * 0.52 - rx, y: h * 0.49 - ry, width: rx * 2, height: ry * 2))
            context.stroke(
                ripple,
                with: .color(mat.rim.swiftColor(opacity: (1 - p) * 0.42)),
                lineWidth: CGFloat(1.4 * (1 - p * 0.5))
            )
        }

        // 4. Hydrodynamic wingtip silk vortex ribbons.
        if !input.calmMotion && !resting && !guarding && !isError {
            drawTrail(input.leftTrail, in: &context, color: mat.trail, alphaScale: 0.38 + boost * 0.22, boost: boost)
            drawTrail(input.rightTrail, in: &context, color: mat.trail, alphaScale: 0.46 + boost * 0.24, boost: boost)
        }

        // 5. Sinuous 3D calligraphic whip tail.
        let tailSegs = 18
        var tailProj: [MantaProjectedVertex] = []
        tailProj.reserveCapacity(tailSegs + 1)
        for k in 0...tailSegs {
            let f = Double(k) / Double(tailSegs)
            let tx = -0.56 - f * 1.08
            let ty = sin(effT * speed - 1.15 - f * 3.1) * (0.04 + f * 0.14) * (resting ? 0.25 : 1.0)
            let tz = sin(effT * speed * 0.72 - f * 2.4) * (f * 0.11) * (resting ? 0.20 : 1.0)
            tailProj.append(project(MantaPoint3D(x: tx, y: ty, z: tz), config: cfg))
        }
        for k in 0..<tailSegs {
            let p0 = tailProj[k]
            let p1 = tailProj[k + 1]
            let f = Double(k) / Double(tailSegs)
            let tc = mat.mid.mixed(with: mat.iridB, t: f)
            let lw = max(0.7, cfg.scale * 0.036) * (1.0 - f * 0.84)
            var seg = Path()
            seg.move(to: CGPoint(x: p0.sx, y: p0.sy))
            seg.addLine(to: CGPoint(x: p1.sx, y: p1.sy))
            context.stroke(
                seg,
                with: .color(tc.swiftColor(opacity: 0.88 * (1.0 - f * 0.86))),
                style: StrokeStyle(lineWidth: CGFloat(lw), lineCap: .round)
            )
        }

        // 6. Build 12x34 parametric 3D mesh.
        let nu = 12
        let nv = 34
        var grid: [[MantaProjectedVertex]] = []
        grid.reserveCapacity(nu + 1)
        for i in 0...nu {
            let u = Double(i) / Double(nu)
            var row: [MantaProjectedVertex] = []
            row.reserveCapacity(nv + 1)
            for j in 0...nv {
                let v = (Double(j) / Double(nv)) * 2.0 - 1.0
                let pt = samplePoint(u: u, v: v, t: effT, speed: speed, spread: spread, rollTwist: cfg.roll)
                let projected = project(pt, config: cfg)
                row.append(MantaProjectedVertex(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    sx: projected.sx,
                    sy: projected.sy,
                    u: u,
                    v: v,
                    a: abs(v)
                ))
            }
            grid.append(row)
        }

        struct Quad {
            let p00: MantaProjectedVertex
            let p10: MantaProjectedVertex
            let p11: MantaProjectedVertex
            let p01: MantaProjectedVertex
            let zAvg: Double
        }

        var quads: [Quad] = []
        quads.reserveCapacity(nu * nv)
        for i in 0..<nu {
            for j in 0..<nv {
                let p00 = grid[i][j]
                let p10 = grid[i + 1][j]
                let p11 = grid[i + 1][j + 1]
                let p01 = grid[i][j + 1]
                let zAvg = (p00.z + p10.z + p11.z + p01.z) * 0.25
                quads.append(Quad(p00: p00, p10: p10, p11: p11, p01: p01, zAvg: zAvg))
            }
        }
        quads.sort { $0.zAvg < $1.zAvg }

        // 7. Render opaque micro-quads inside an isolated transparency layer -> seamless liquid glass!
        let lx = 0.32, ly = 0.78, lz = 0.54
        let hx = 0.18, hy = 0.44, hz = 0.88

        context.drawLayer { layer in
            layer.opacity = resting ? 0.78 : 0.90
            for q in quads {
                let ax = q.p10.x - q.p01.x
                let ay = q.p10.y - q.p01.y
                let az = q.p10.z - q.p01.z
                let bx = q.p11.x - q.p00.x
                let by = q.p11.y - q.p00.y
                let bz = q.p11.z - q.p00.z

                var nx = ay * bz - az * by
                var ny = az * bx - ax * bz
                var nz = ax * by - ay * bx
                let len = sqrt(nx * nx + ny * ny + nz * nz)
                if len > 1e-6 {
                    nx /= len
                    ny /= len
                    nz /= len
                }

                let underside = nz < 0
                if underside {
                    nx = -nx
                    ny = -ny
                    nz = -nz
                }

                let ndotl = clamp(nx * lx + ny * ly + nz * lz, 0, 1)
                let ndoth = clamp(nx * hx + ny * hy + nz * hz, 0, 1)
                let fresnel = pow(1.0 - clamp(nz, 0, 1), 1.82)
                let aAvg = (q.p00.a + q.p11.a) * 0.5

                var col = mat.shadow.mixed(with: mat.mid, t: smoothstep(0.04, 0.74, ndotl))
                col = col.mixed(with: mat.bright, t: smoothstep(0.52, 0.98, ndotl) * 0.76)
                if underside {
                    col = col.mixed(with: mat.under, t: 0.44)
                }

                let iridPhase = 0.5 + 0.5 * sin(aAvg * 3.3 + nx * 2.6 + ny * 1.8 + effT * 0.8)
                let iridTone = mat.iridA.mixed(with: mat.iridB, t: iridPhase)
                let iridAmt = clamp(fresnel * 0.64 + smoothstep(0.30, 0.96, aAvg) * 0.28, 0, 0.78)
                col = col.mixed(with: iridTone, t: iridAmt)
                col = col.mixed(with: mat.rim, t: fresnel * 0.52)

                let specAmt = clamp(pow(ndoth, 20.0) * (underside ? 0.35 : 0.88), 0, 0.94)
                col = col.mixed(with: mat.spec, t: specAmt)

                let depthDim = clamp((q.zAvg + 1.15) / 2.3, 0.80, 1.0)
                let fillColor = col.scaled(depthDim).swiftColor(opacity: 1.0)

                var quadPath = Path()
                quadPath.move(to: CGPoint(x: q.p00.sx, y: q.p00.sy))
                quadPath.addLine(to: CGPoint(x: q.p10.sx, y: q.p10.sy))
                quadPath.addLine(to: CGPoint(x: q.p11.sx, y: q.p11.sy))
                quadPath.addLine(to: CGPoint(x: q.p01.sx, y: q.p01.sy))
                quadPath.closeSubpath()

                layer.fill(quadPath, with: .color(fillColor))
                layer.stroke(quadPath, with: .color(fillColor), style: StrokeStyle(lineWidth: 0.85, lineJoin: .round))
            }
        }

        // 8. Luminous pearl leading-edge contour & dorsal spine highlight.
        context.drawLayer { glowLayer in
            glowLayer.addFilter(.shadow(color: mat.rim.swiftColor(opacity: 0.55), radius: 5))
            var lead = Path()
            for j in 0...nv {
                let p = grid[0][j]
                let pt = CGPoint(x: p.sx, y: p.sy)
                if j == 0 {
                    lead.move(to: pt)
                } else {
                    lead.addLine(to: pt)
                }
            }
            let startPt = CGPoint(x: grid[0][0].sx, y: grid[0][0].sy)
            let endPt = CGPoint(x: grid[0][nv].sx, y: grid[0][nv].sy)
            glowLayer.stroke(
                lead,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: mat.iridA.swiftColor(opacity: 0.42), location: 0.0),
                        .init(color: mat.rim.swiftColor(opacity: 0.92), location: 0.5),
                        .init(color: mat.iridB.swiftColor(opacity: 0.50), location: 1.0),
                    ]),
                    startPoint: startPt,
                    endPoint: endPt
                ),
                style: StrokeStyle(lineWidth: CGFloat(max(0.95, cfg.scale * 0.022)), lineCap: .round, lineJoin: .round)
            )

            let midJ = nv / 2
            var spine = Path()
            for i in 1..<nu {
                let p = grid[i][midJ]
                let pt = CGPoint(x: p.sx, y: p.sy)
                if i == 1 {
                    spine.move(to: pt)
                } else {
                    spine.addLine(to: pt)
                }
            }
            glowLayer.stroke(
                spine,
                with: .color(mat.spec.swiftColor(opacity: 0.52)),
                style: StrokeStyle(lineWidth: CGFloat(max(0.8, cfg.scale * 0.018)), lineCap: .round, lineJoin: .round)
            )
        }
    }

    private static func drawTrail(
        _ points: [MantaTrailPoint],
        in context: inout GraphicsContext,
        color: RGBColor,
        alphaScale: Double,
        boost: Double
    ) {
        guard points.count >= 2 else { return }
        let total = Double(points.count)
        for k in 0..<(points.count - 1) {
            let p0 = points[k]
            let p1 = points[k + 1]
            let fade = 1.0 - Double(k) / total
            let alpha = max(0, p0.life) * alphaScale * fade
            guard alpha >= 0.008 else { continue }
            var seg = Path()
            seg.move(to: CGPoint(x: p0.x, y: p0.y))
            seg.addLine(to: CGPoint(x: p1.x, y: p1.y))
            context.stroke(
                seg,
                with: .color(color.swiftColor(opacity: alpha)),
                style: StrokeStyle(lineWidth: CGFloat(max(0.55, fade * (1.45 + boost * 0.85))), lineCap: .round)
            )
        }
    }

    /// Renders the 3/4 sculpted manta silhouette as a native macOS template `NSImage`
    /// (`isTemplate = true`) so it adapts automatically to light/dark menu bars.
    @MainActor
    static func renderMenuBarTemplateImage(state: MantaVisualState, phase: Double) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else {
                return false
            }
            let w = Double(rect.width)
            let h = Double(rect.height)
            let resting = state == .off
            let guarding = state == .guarding
            let isError = state == .error
            let tucked = resting || guarding || isError
            let speed = state == .connecting ? 4.8 : (guarding ? 3.1 : 2.35)
            let spread: Double = resting ? 0.64 : ((guarding || isError) ? 0.72 : 1.0)
            let cfg = MantaCameraConfig(
                cx: w * 0.50,
                cy: h * 0.49,
                scale: h * 0.36,
                yaw: 0.48,
                pitch: tucked ? -0.02 : (state == .connecting ? 0.14 : 0.06),
                roll: tucked ? 0.06 : 0.16,
                elev: 0.42
            )

            // Guard mode subtle dashed arc behind the tucked manta.
            if guarding {
                cg.saveGState()
                cg.setStrokeColor(NSColor.black.withAlphaComponent(0.50).cgColor)
                cg.setLineWidth(1.0)
                cg.setLineDash(phase: 0, lengths: [3.2, 2.2])
                cg.strokeEllipse(in: CGRect(x: w * 0.14, y: h * 0.10, width: w * 0.68, height: h * 0.80))
                cg.restoreGState()
            }

            // Draw the tail + 5x14 mesh at full black inside an isolated transparency layer
            // so adjacent quads never double-blend seams in the resting semi-transparent state.
            let inkAlpha: CGFloat = resting ? 0.56 : 0.96
            cg.saveGState()
            cg.setAlpha(inkAlpha)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setFillColor(NSColor.black.cgColor)
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            // Tapered 3D whip tail.
            let tailSegs = 8
            for k in 0..<tailSegs {
                let f0 = Double(k) / Double(tailSegs)
                let f1 = Double(k + 1) / Double(tailSegs)
                let p0 = project(
                    MantaPoint3D(
                        x: -0.56 - f0 * 0.98,
                        y: sin(phase * speed - 1.15 - f0 * 3.1) * (0.03 + f0 * 0.12) * (tucked ? 0.2 : 1.0),
                        z: 0
                    ),
                    config: cfg
                )
                let p1 = project(
                    MantaPoint3D(
                        x: -0.56 - f1 * 0.98,
                        y: sin(phase * speed - 1.15 - f1 * 3.1) * (0.03 + f1 * 0.12) * (tucked ? 0.2 : 1.0),
                        z: 0
                    ),
                    config: cfg
                )
                cg.setLineWidth(CGFloat(1.3 * (1.0 - f0 * 0.72)))
                cg.beginPath()
                cg.move(to: CGPoint(x: p0.sx, y: p0.sy))
                cg.addLine(to: CGPoint(x: p1.sx, y: p1.sy))
                cg.strokePath()
            }

            // 5x14 monochrome sculpted silhouette.
            let nu = 5
            let nv = 14
            var grid: [[MantaProjectedVertex]] = []
            for i in 0...nu {
                let u = Double(i) / Double(nu)
                var row: [MantaProjectedVertex] = []
                for j in 0...nv {
                    let v = (Double(j) / Double(nv)) * 2.0 - 1.0
                    let pt = samplePoint(u: u, v: v, t: phase, speed: speed, spread: spread, rollTwist: cfg.roll)
                    row.append(project(pt, config: cfg))
                }
                grid.append(row)
            }

            cg.setLineWidth(0.55)
            for i in 0..<nu {
                for j in 0..<nv {
                    let a = grid[i][j]
                    let b = grid[i + 1][j]
                    let c = grid[i + 1][j + 1]
                    let d = grid[i][j + 1]
                    cg.beginPath()
                    cg.move(to: CGPoint(x: a.sx, y: a.sy))
                    cg.addLine(to: CGPoint(x: b.sx, y: b.sy))
                    cg.addLine(to: CGPoint(x: c.sx, y: c.sy))
                    cg.addLine(to: CGPoint(x: d.sx, y: d.sy))
                    cg.closePath()
                    cg.drawPath(using: .fillStroke)
                }
            }
            cg.endTransparencyLayer()
            cg.restoreGState()

            // Distinct status indicator in top-right corner:
            // - `.error`: crisp miniature `!` mark (unmistakable vs connected)
            // - `.connected` / `.connecting` / `.guarding`: crisp 3pt status dot
            cg.setFillColor(NSColor.black.withAlphaComponent(0.96).cgColor)
            cg.setStrokeColor(NSColor.black.withAlphaComponent(0.96).cgColor)
            if isError {
                cg.setLineCap(.round)
                cg.setLineWidth(1.5)
                cg.beginPath()
                cg.move(to: CGPoint(x: w - 2.6, y: 1.8))
                cg.addLine(to: CGPoint(x: w - 2.6, y: 5.2))
                cg.strokePath()
                cg.fillEllipse(in: CGRect(x: w - 3.45, y: 6.7, width: 1.7, height: 1.7))
            } else if state != .off {
                let dotRect = CGRect(x: w - 4.0, y: 1.5, width: 3.0, height: 3.0)
                cg.fillEllipse(in: dotRect)
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
