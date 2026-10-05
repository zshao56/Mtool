import AppKit
import MetalKit
import SwiftUI
import QuartzCore

/// Slots in the flat uniform array `donutFragment` reads (DonutShaders.metal). A
/// flat `[Float]` rather than a struct, so Swift and Metal can never disagree about
/// padding.
private enum DonutUniform {
    static let cx = 0, cy = 1, scale = 2, R = 3, r = 4, K = 5, M = 6, P = 15
    static let unused16 = 16, dark = 17, groove = 18, base = 19, baseA = 22, accent = 23
    static let ground = 26, subOn = 27, subMid = 28, subSpan = 29, subR = 30, subr = 31
    static let subN = 32, subFull = 33, n = 34, shadow = 35, reach = 36, lift = 37, tint = 38
    static let count = 39
}

/// The donut's surface colours, per appearance (sRGB). Tuned in the
/// prototype.
private struct DonutPalette {
    var base: (Float, Float, Float)
    var baseAlpha: Float
    var accent: (Float, Float, Float)
    var tint: Float
    var shadow: Float

    init(dark: Bool, pageDark: Bool) {
        // Barely any body colour of our own: the system glass underneath does the
        // work, and a tint of ours made the ring grey (the user tried it).
        base = dark ? Self.rgb(0x12, 0x15, 0x1C) : (1, 1, 1)
        baseAlpha = 0.05
        // The hovered slice takes the app icon's blue (#2563EB, #60A5FA in dark mode).
        accent = dark ? Self.rgb(0x60, 0xA5, 0xFA) : Self.rgb(0x25, 0x63, 0xEB)
        tint = 1
        // A shadow has to be darker to read on a dark page; glass casts a light one.
        shadow = (pageDark ? 0.5 : 0.24) * 0.55
    }

    /// An 8-bit colour as 0…1 floats. Spelled as a function, not inline literal
    /// division: the CI compiler (Xcode 26.6) timed out type-checking the tuple
    /// ternary of literals.
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> (Float, Float, Float) {
        (Float(r) / 255, Float(g) / 255, Float(b) / 255)
    }
}

/// Whether this Mac can draw the donut at all. Every Mac that runs macOS 13 has a
/// Metal GPU, but a failed device or library must degrade to a flat skin rather
/// than to an invisible wheel.
enum DonutSupport {
    static var isAvailable: Bool { DonutRenderer.shared != nil }
}

/// An MTKView that never takes part in hit-testing: every click and hover belongs to
/// the wheel's SwiftUI surface, which sits in the same hosting view.
final class DonutMetalView: MTKView {
    /// Called once the view is in a window: a display link can only be made for a
    /// view that is on a screen.
    var onWindowChange: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let s = window?.backingScaleFactor { layer?.contentsScale = s }
    }
}

/// The ray-marched ring, as a SwiftUI view. Draws only while something moves; the
/// display link pauses itself once every spring has settled.
struct DonutRingView: NSViewRepresentable {
    let motion: DonutMotion
    let targets: DonutTargets
    /// The ring's own surface is dark (dark glass). Ceramic is always light.
    let surfaceDark: Bool
    /// The system is in dark mode — what the ring's shadow falls on.
    let pageDark: Bool
    /// Carve a groove between neighbouring slices (and children).
    let dividers: Bool
    let canvas: CGFloat
    let layout: WheelLayout
    let sliceCount: Int

    func makeCoordinator() -> DonutRenderer { DonutRenderer(motion: motion) }

    func makeNSView(context: Context) -> DonutMetalView {
        let r = context.coordinator
        let v = DonutMetalView(frame: .zero, device: r.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // Never self-driven: MTKView's own loop calls the delegate on a BACKGROUND
        // thread (measured), while `DonutMotion` is read and written by SwiftUI on the
        // main one. The renderer's main-thread ticker calls `draw()` instead.
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        v.autoResizeDrawable = true
        v.wantsLayer = true
        v.layer?.isOpaque = false
        if let ml = v.layer as? CAMetalLayer {
            ml.isOpaque = false
            // The shader writes sRGB-encoded values; say so, or the compositor
            // re-interprets them and every colour shifts.
            ml.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        v.delegate = r
        r.view = v
        v.onWindowChange = { [weak r] in r?.stop(); r?.wake() }
        if let ml = v.layer as? CAMetalLayer {
            // Present in step with Core Animation, so the ring and the SwiftUI labels
            // laid over it land on screen in the SAME frame instead of one trailing
            // the other.
            ml.presentsWithTransaction = true
        }
        motion.onNeedsFrame = { [weak r] in r?.wake() }
        applyGeometry()
        return v
    }

    func updateNSView(_ v: DonutMetalView, context: Context) {
        let r = context.coordinator
        r.surfaceDark = surfaceDark
        r.pageDark = pageDark
        r.dividers = dividers
        applyGeometry()
        motion.setTargets(targets)
        r.wake()
    }

    private func applyGeometry() {
        motion.canvas = canvas
        motion.layout = layout
        motion.sliceCount = sliceCount
    }

    static func dismantleNSView(_ v: DonutMetalView, coordinator: DonutRenderer) {
        coordinator.stop()
        v.delegate = nil
    }
}

final class DonutRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let motion: DonutMotion
    weak var view: DonutMetalView?
    var surfaceDark = false
    var pageDark = false
    var dividers = true
    private var lastTime: CFTimeInterval = 0
    /// Drives frames on the MAIN thread while anything moves; nil while idle.
    private var ticker: AnyObject?
    private var cvLink: CVDisplayLink?

    init(motion: DonutMotion) {
        self.motion = motion
        let built = Self.shared
        device = built?.device
        pipeline = built?.pipeline
        queue = built?.device.makeCommandQueue()
        super.init()
    }

    /// Built once per launch: compiling a pipeline costs tens of milliseconds, and a
    /// popup's first frame is the whole of its first impression.
    static let shared: (device: MTLDevice, pipeline: MTLRenderPipelineState)? = makePipeline()

    private static func makePipeline() -> (device: MTLDevice, pipeline: MTLRenderPipelineState)? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let lib = device.makeDefaultLibrary(),
              let vf = lib.makeFunction(name: "donutVertex"),
              let ff = lib.makeFunction(name: "donutFragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        return (device, p)
    }

    /// Start drawing again (a target changed). The first frame after a pause gets a
    /// nominal step instead of the whole idle gap.
    func wake() {
        guard ticker == nil, cvLink == nil, let v = view, v.window != nil else { return }
        lastTime = 0
        if #available(macOS 14.0, *) {
            // Vsync-aligned and delivered on the main run loop.
            let link = v.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            // macOS 13 has no main-thread display link; CVDisplayLink fires on its own
            // thread, so it only ever hops to the main queue and does nothing else.
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else { return }
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                DispatchQueue.main.async { self?.tick() }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            cvLink = link
        }
        tick()   // the first frame now, not a vsync later
    }

    func stop() {
        if #available(macOS 14.0, *) { (ticker as? CADisplayLink)?.invalidate() }
        ticker = nil
        if let link = cvLink { CVDisplayLinkStop(link) }
        cvLink = nil
    }

    /// One frame, on the main thread: advance the springs, draw, and stop once
    /// everything has settled.
    @objc private func tick() {
        guard let v = view else { stop(); return }
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 || now - lastTime > 0.1 ? 1.0 / 60 : now - lastTime
        lastTime = now
        let moving = motion.step(dt)
        v.draw()
        if !moving { stop() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if let pipeline, let queue, view.drawableSize.width > 0, view.drawableSize.height > 0,
           let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
           let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            var u = uniforms(drawableSize: view.drawableSize)
            var sel = motion.sel.isEmpty ? [Float(0)] : motion.sel
            var subSel = motion.subSel.isEmpty ? [Float(0)] : motion.subSel
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Float>.stride * u.count, index: 0)
            enc.setFragmentBytes(&sel, length: MemoryLayout<Float>.stride * sel.count, index: 1)
            enc.setFragmentBytes(&subSel, length: MemoryLayout<Float>.stride * subSel.count, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            // presentsWithTransaction: present from here, once the GPU has the work.
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        }
    }

    private func uniforms(drawableSize: CGSize) -> [Float] {
        typealias U = DonutUniform
        var u = [Float](repeating: 0, count: U.count)
        let m = motion
        let canvas = max(Double(m.canvas), 1)
        u[U.cx] = Float(drawableSize.width / 2)
        u[U.cy] = Float(drawableSize.height / 2)
        u[U.scale] = Float(Double(drawableSize.width) / canvas)
        u[U.R] = Float(m.tubeCentre)
        u[U.r] = Float(m.tubeRadius)
        u[U.K] = Float(DonutMotion.squash)
        for (i, v) in m.rotation.enumerated() { u[U.M + i] = Float(v) }
        u[U.P] = Float(DonutMotion.perspective)
        u[U.dark] = surfaceDark ? 1 : 0
        u[U.groove] = dividers ? 1 : 0
        let pal = DonutPalette(dark: surfaceDark, pageDark: pageDark)
        let lin: (Float) -> Float = { powf($0, 2.2) }
        u[U.base] = lin(pal.base.0); u[U.base + 1] = lin(pal.base.1); u[U.base + 2] = lin(pal.base.2)
        u[U.baseA] = pal.baseAlpha
        u[U.accent] = lin(pal.accent.0); u[U.accent + 1] = lin(pal.accent.1); u[U.accent + 2] = lin(pal.accent.2)
        // The page sits a little below the tube's underside.
        u[U.ground] = Float(m.crest + 16)
        u[U.shadow] = pal.shadow
        // How far past the solid the shadow may reach before it fades to nothing —
        // never past the canvas edge, or it ends in a hard line there (a wheel with
        // no submenus has only `pad` = 10pt around the ring).
        let solid = max(m.tubeCentre + m.tubeRadius, m.sub.map { $0.centre + $0.tube } ?? 0)
        u[U.reach] = Float(max(4, min(40, canvas / 2 - solid - 2)))
        // The hovered slice (and child) is pressed in a little, like a button — it
        // must not grow, which a raised slice would (it comes toward the eye).
        u[U.lift] = -3.5
        u[U.tint] = pal.tint
        u[U.n] = Float(max(m.sliceCount, 1))
        if let s = m.sub {
            u[U.subOn] = 1
            u[U.subMid] = Float(s.mid)
            u[U.subSpan] = Float(s.span)
            u[U.subR] = Float(s.centre)
            u[U.subr] = Float(s.tube)
            u[U.subN] = Float(max(m.targets.subCount, 1))
            u[U.subFull] = m.subIsClosedRing ? 1 : 0
        } else {
            u[U.subN] = 1
        }
        return u
    }
}

/// Re-renders `content` on every donut frame. The only thing that observes the
/// motion, so the (large) wheel view itself does not re-render at display rate.
struct DonutMotionReader<Content: View>: View {
    @ObservedObject var motion: DonutMotion
    let content: (DonutMotion) -> Content
    var body: some View { content(motion) }
}
