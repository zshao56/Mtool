import Foundation
import CoreGraphics
import Combine
import SwiftUI
import QuartzCore

/// What the wheel wants the donut to show right now. Handed over as one value on
/// every SwiftUI update, so the renderer never reads the wheel's `@State` itself.
struct DonutTargets: Equatable {
    /// Pointer in the wheel's local space (y down, origin at the canvas corner);
    /// nil once it has left the wheel.
    var pointer: CGPoint?
    var hoveredIndex: Int?
    /// The hovered slice is the open group and the pointer is out on its second
    /// ring: the parent keeps a softer tint (the app's rule for every skin).
    var parentSoft = false
    var hoveredChild: Int?
    var expanded = false
    /// The open group's axis, in the wheel's degrees (−90 = twelve o'clock,
    /// clockwise) — possibly "unwrapped" past ±180, exactly as the wheel animates it.
    var subMidDegrees: Double?
    var subCount = 0
    /// Angular width of the whole run once fully out, in degrees.
    var subSpanDegrees: Double = 0
    var subFull = false
}

/// Everything about the donut that MOVES: the tilt toward the pointer, the second
/// ring unfolding, the highlight fading between slices. One reference-type owner so
/// the Metal view (which draws it) and the label overlay (which follows it) read the
/// same numbers on the same frame, and so `hit(at:)` can un-project the pointer
/// through the tilt the user is actually looking at.
///
/// Held by the wheel as plain `@State` (NOT `@StateObject`): the wheel itself must
/// not re-render every frame. Only the small overlay observes `frame`.
final class DonutMotion: ObservableObject {

    /// Bumped once per rendered frame; the label overlay re-lays itself out on it.
    @Published private(set) var frame = 0

    /// Called when a target changes and a paused renderer has to start again.
    var onNeedsFrame: (() -> Void)?

    // MARK: Tuning (locked in the prototype)

    /// How far the ring leans toward the pointer.
    static let maxTilt: Double = 8 * .pi / 180
    /// Eye distance, in points. The same projection CSS `perspective(900px)` gave
    /// the prototype.
    static let perspective: Double = 900
    /// Tube height as a fraction of its width (the prototype's "厚度" at 80%).
    static let squash: Double = 0.8

    // MARK: Geometry (set by the wheel)

    var canvas: CGFloat = 0
    var layout = WheelLayout()
    /// How many slices the main ring is cut into.
    var sliceCount = 1

    // MARK: Targets

    private(set) var targets = DonutTargets()

    func setTargets(_ t: DonutTargets) {
        guard t != targets else { return }
        targets = t
        onNeedsFrame?()
    }

    /// Back to rest: flat, folded, nothing lit. For a wheel shown afresh — the
    /// panel keeps its view (and so this object) between popups, and the new one
    /// must not open with the last one's tilt or an unfolded second ring.
    func reset() {
        tilt = .zero; tiltV = .zero
        unfold = 0; unfoldV = 0
        subMidV = 0; subSpan = 0; subSpanV = 0
        sel = sel.map { _ in 0 }
        subSel = subSel.map { _ in 0 }
        targets = DonutTargets()
        onNeedsFrame?()
    }

    // MARK: Animated state

    /// Tilt as an axis-angle vector in the ring's plane (y up); |w| is the angle.
    private(set) var tilt = SIMD2<Double>(0, 0)
    private var tiltV = SIMD2<Double>(0, 0)
    /// 0 = second ring folded under the main ring, 1 = fully out.
    private(set) var unfold: Double = 0
    private var unfoldV: Double = 0
    /// The second ring's axis, in the wheel's degrees.
    private(set) var subMid: Double = -90
    private var subMidV: Double = 0
    /// The second ring's full angular width, in degrees. Animated like the axis:
    /// moving from a two-item group to a five-item one must GROW the arc, not snap
    /// it from 80° to 200° in one frame (`SubmenuRing` animates its span too).
    private(set) var subSpan: Double = 0
    private var subSpanV: Double = 0
    private(set) var sel: [Float] = []
    private(set) var subSel: [Float] = []

    /// Advance every spring by `dt`. Returns whether anything is still moving.
    func step(_ dt: Double) -> Bool {
        let t = targets
        var moving = false

        let goal = goalTilt(for: t.pointer)
        // Slightly under-damped: one small settle, no wobble.
        let k = 190.0, c = 2 * k.squareRoot() * 0.72
        tiltV += (k * (goal - tilt) - c * tiltV) * dt
        tilt += tiltV * dt
        if abs(tiltV.x) + abs(tiltV.y) > 1e-4 || abs(goal.x - tilt.x) + abs(goal.y - tilt.y) > 1e-5 { moving = true }

        // Second ring: the wheel's own open spring, `.spring(response: 0.36,
        // dampingFraction: 0.9)`, so the donut unfolds on the same clock as the
        // settle timer that decides when its children go live.
        let w0: Double = 2 * Double.pi / 0.36
        let ok: Double = w0 * w0
        let oc: Double = 2 * 0.9 * w0
        let to: Double = t.expanded ? 1 : 0
        let accU: Double = ok * (to - unfold) - oc * unfoldV
        unfoldV += accU * dt
        unfold += unfoldV * dt
        if abs(to - unfold) > 1e-4 || abs(unfoldV) > 1e-3 { moving = true } else { unfold = to; unfoldV = 0 }
        if let mid = t.subMidDegrees {
            let span = t.subFull ? 360 : t.subSpanDegrees
            // Folded: jump straight to the new axis and width (out of sight). Out: travel.
            if unfold < 0.01 && !t.expanded {
                subMid = mid; subMidV = 0
                subSpan = span; subSpanV = 0
            } else {
                let accM: Double = ok * (mid - subMid) - oc * subMidV
                subMidV += accM * dt
                subMid += subMidV * dt
                if abs(mid - subMid) > 1e-3 || abs(subMidV) > 1e-2 { moving = true } else { subMid = mid; subMidV = 0 }
                let accS: Double = ok * (span - subSpan) - oc * subSpanV
                subSpanV += accS * dt
                subSpan += subSpanV * dt
                if abs(span - subSpan) > 1e-3 || abs(subSpanV) > 1e-2 { moving = true } else { subSpan = span; subSpanV = 0 }
            }
        }

        // Highlights: an exponential ease, so crossing slices reads as a glide.
        let n = max(sliceCount, 1)
        if sel.count != n { sel = Array(repeating: 0, count: n) }
        if subSel.count != max(t.subCount, 1) { subSel = Array(repeating: 0, count: max(t.subCount, 1)) }
        let f = Float(1 - exp(-dt * 16))
        func ease(_ v: inout Float, _ goal: Float) {
            let nv = v + (goal - v) * f
            if abs(nv - v) > 1e-4 { moving = true }
            v = abs(goal - nv) < 1e-4 ? goal : nv
        }
        for i in 0..<sel.count {
            ease(&sel[i], i == t.hoveredIndex ? (t.parentSoft ? 0.55 : 1) : 0)
        }
        for i in 0..<subSel.count {
            ease(&subSel[i], i == t.hoveredChild ? 1 : 0)
        }

        frame &+= 1
        return moving
    }

    /// Where the tilt is headed for a pointer at `p`: toward the pointer, growing
    /// from nothing at the centre to full at the ring's midline; flat once the
    /// pointer is past the wheel's reach.
    func goalTilt(for p: CGPoint?) -> SIMD2<Double> {
        guard let p, canvas > 0 else { return .zero }
        let c = Double(canvas) / 2
        let q = SIMD2(Double(p.x) - c, c - Double(p.y))
        let d = (q.x * q.x + q.y * q.y).squareRoot()
        let reach = Double(targets.expanded ? layout.submenuOuterRadius : layout.outerRadius) + Double(layout.overshootSlack)
        guard d <= reach, d > 0 else { return .zero }
        var m = min(d / Double(layout.midRadius), 1)
        m = m * m * (3 - 2 * m)
        let th = Self.maxTilt * m
        // axis = z × u, so the side under the pointer sinks away from the eye
        return SIMD2(-q.y / d * th, q.x / d * th)
    }

    // MARK: Projection

    /// The tilt as a row-major 3×3 rotation (ring-local → world), y up.
    var rotation: [Double] { Self.rotation(tilt) }

    static func rotation(_ tilt: SIMD2<Double>) -> [Double] {
        let th = (tilt.x * tilt.x + tilt.y * tilt.y).squareRoot()
        guard th > 1e-9 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        let x = tilt.x / th, y = tilt.y / th, cs = cos(th), sn = sin(th), C = 1 - cs
        return [cs + x * x * C, x * y * C, y * sn,
                y * x * C, cs + y * y * C, -x * sn,
                -y * sn, x * sn, cs]
    }

    /// A ring-local point (y up, relative to the centre) → the wheel's view space.
    func project(x: Double, y: Double, z: Double) -> CGPoint {
        let m = rotation
        let wx = m[0] * x + m[1] * y + m[2] * z
        let wy = m[3] * x + m[4] * y + m[5] * z
        let wz = m[6] * x + m[7] * y + m[8] * z
        let s = Self.perspective / (Self.perspective - wz)
        let c = Double(canvas) / 2
        return CGPoint(x: c + wx * s, y: c - wy * s)
    }

    /// `project` for a whole flat layer lying at `height` above the ring's plane,
    /// as one projective transform: layer point (view space, as if the ring were
    /// flat) → screen point. Lets the icons and names be laid out ONCE, flat, and
    /// moved by the GPU as one piece — so no glyph is snapped to the pixel grid on
    /// its own, and an icon and its name can never step at different moments.
    func planeTransform(height h: Double) -> ProjectionTransform {
        let r = rotation, P = Self.perspective, c = Double(canvas) / 2
        // (xv, yv, 1) → ring-local (x, y) = (xv − c, c − yv)
        // → world (wx, wy) and w = 1 − wz / P  (homogeneous)
        // → screen (X, Y, w) = (wx + c·w, −wy + c·w, w)
        func row(_ a: Double, _ b: Double, _ k: Double) -> (Double, Double, Double) {
            // coefficients of a·x + b·y + k in terms of xv, yv, 1
            (a, -b, -a * c + b * c + k)
        }
        let wx = row(r[0], r[1], r[2] * h)
        let wy = row(r[3], r[4], r[5] * h)
        let wz = row(r[6], r[7], r[8] * h)
        let w = (-wz.0 / P, -wz.1 / P, 1 - wz.2 / P)
        let X = (wx.0 + c * w.0, wx.1 + c * w.1, wx.2 + c * w.2)
        let Y = (-wy.0 + c * w.0, -wy.1 + c * w.1, -wy.2 + c * w.2)
        // ProjectionTransform multiplies ROW vectors: [xv yv 1] · M.
        return ProjectionTransform(CATransform3D(
            m11: CGFloat(X.0), m12: CGFloat(Y.0), m13: 0, m14: CGFloat(w.0),
            m21: CGFloat(X.1), m22: CGFloat(Y.1), m23: 0, m24: CGFloat(w.1),
            m31: 0, m32: 0, m33: 1, m34: 0,
            m41: CGFloat(X.2), m42: CGFloat(Y.2), m43: 0, m44: CGFloat(w.2)))
    }

    /// The inverse of `project` onto the plane at `height` above the ring's centre:
    /// where on the (tilted) ring a view-space point is. Returned in view space again
    /// — as the point the FLAT wheel would have under it — so every existing
    /// hit-test keeps working unchanged.
    ///
    /// Through the tilt the ring is SETTLING TO for this pointer, not the one it is
    /// passing through: that keeps the answer a pure function of where the pointer
    /// is, so a highlight near a divider cannot flip while the mouse is still and
    /// the wheel's settle / aim re-checks read a steady answer. Once settled it is
    /// exactly what is drawn; mid-flight it is off by at most a couple of points.
    func unproject(_ p: CGPoint, height: Double) -> CGPoint {
        guard canvas > 0 else { return p }   // not laid out yet: nothing is tilted
        let m = Self.rotation(goalTilt(for: p)), P = Self.perspective, c = Double(canvas) / 2
        let q = SIMD3(Double(p.x) - c, c - Double(p.y), -P)
        // local = Mᵀ · world
        func mt(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(m[0] * v.x + m[3] * v.y + m[6] * v.z,
                  m[1] * v.x + m[4] * v.y + m[7] * v.z,
                  m[2] * v.x + m[5] * v.y + m[8] * v.z)
        }
        let e = mt(SIMD3(0, 0, P)), d = mt(q)
        guard abs(d.z) > 1e-9 else { return p }
        let t = (height - e.z) / d.z
        return CGPoint(x: c + e.x + d.x * t, y: c - (e.y + d.y * t))
    }

    // MARK: Derived geometry

    var tubeRadius: Double { Double(layout.outerRadius - layout.innerRadius) / 2 }
    var tubeCentre: Double { Double(layout.midRadius) }
    /// Height of the main tube's crest above the ring's plane.
    var crest: Double { tubeRadius * Self.squash }

    /// The second ring at this instant: slides out from UNDER the main ring
    /// (`SubmenuRing.radii`), its run growing with it.
    struct Sub { var mid: Double; var span: Double; var centre: Double; var tube: Double }
    /// Drawn as a closed ring only once the run has actually grown to a full turn;
    /// until then it is an arc whose round ends are closing in on each other.
    var subIsClosedRing: Bool { targets.subFull && subSpan >= 359.9 && unfold >= 0.999 }
    var sub: Sub? {
        guard targets.subMidDegrees != nil, targets.subCount > 0, unfold > 0.002 else { return nil }
        let seam = Double(layout.submenuSeam), thick = Double(layout.submenuThickness)
        let tuck = (1 - unfold) * (seam + thick)
        let inner = Double(layout.outerRadius) + seam - tuck
        return Sub(mid: (subMid + 90) * .pi / 180,
                   span: min(subSpan, 360) * .pi / 180 * unfold,
                   centre: inner + thick / 2, tube: thick / 2)
    }

    /// Both rings' outlines as they appear on screen right now — tilted and in
    /// perspective — for cutting the glass blur to the solid. Traced at the tube's
    /// widest (the ring's own plane), which is the silhouette from above.
    ///
    /// Every loop runs the same way round, so with the non-zero fill the second ring
    /// sliding out from under the first stays solid where they overlap, while the
    /// inner circle (run the other way) keeps the hole open.
    func outlinePath() -> Path {
        let m = self
        guard m.canvas > 0 else { return Path() }
        func pt(_ a: Double, _ r: Double) -> CGPoint { m.project(x: sin(a) * r, y: cos(a) * r, z: 0) }
        var p = Path()
        let seg = 96
        func circle(_ r: Double, reversed: Bool) {
            for k in 0...seg {
                let a = 2 * .pi * Double(reversed ? seg - k : k) / Double(seg)
                k == 0 ? p.move(to: pt(a, r)) : p.addLine(to: pt(a, r))
            }
            p.closeSubpath()
        }
        circle(m.tubeCentre + m.tubeRadius, reversed: false)
        circle(max(m.tubeCentre - m.tubeRadius, 0), reversed: true)

        if let s = m.sub {
            if m.subIsClosedRing {
                circle(s.centre + s.tube, reversed: false)
                circle(max(s.centre - s.tube, 0), reversed: true)
            } else {
                // A thick arc with round ends: out along the far edge, round the end,
                // back along the near edge, round the other end.
                let hl = max(s.span / 2 - s.tube / max(s.centre, 1), 0)
                let a0 = s.mid - hl, a1 = s.mid + hl
                let steps = max(Int((a1 - a0) / (2 * .pi) * Double(seg)), 2)
                for k in 0...steps {
                    let a = a0 + (a1 - a0) * Double(k) / Double(steps)
                    k == 0 ? p.move(to: pt(a, s.centre + s.tube)) : p.addLine(to: pt(a, s.centre + s.tube))
                }
                func cap(_ a: Double, _ sign: Double) {
                    let cx = sin(a) * s.centre, cy = cos(a) * s.centre
                    let ux = sin(a), uy = cos(a), tx = cos(a), ty = -sin(a)
                    for k in 1..<16 {
                        let f = Double.pi * Double(k) / 16
                        let x = cx + s.tube * sign * (ux * cos(f) + tx * sin(f))
                        let y = cy + s.tube * sign * (uy * cos(f) + ty * sin(f))
                        p.addLine(to: m.project(x: x, y: y, z: 0))
                    }
                }
                cap(a1, 1)
                for k in 0...steps {
                    let a = a1 - (a1 - a0) * Double(k) / Double(steps)
                    p.addLine(to: pt(a, max(s.centre - s.tube, 0)))
                }
                cap(a0, -1)
                p.closeSubpath()
            }
        }
        return p
    }
}
