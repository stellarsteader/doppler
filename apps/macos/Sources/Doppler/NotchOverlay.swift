import AppKit
import SwiftUI

enum OverlayPhase: Equatable {
    case hidden, listening, processing, done, error(String)
}

enum NotchStyle: String, CaseIterable, Identifiable {
    case rings, waveform, waveLine

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rings: "Doppler rings"
        case .waveform: "Waveform"
        case .waveLine: "Wave line"
        }
    }
    var indicatorWidth: CGFloat {
        switch self {
        case .rings: 34
        case .waveform: 39
        case .waveLine: 48
        }
    }
    var margins: (leading: CGFloat, trailing: CGFloat, withText: CGFloat) {
        switch self {
        case .rings: (7, 3, 10)
        case .waveform: (8, 3, 11)
        case .waveLine: (4, 0, 6)
        }
    }
}

final class OverlayModel: ObservableObject {
    @Published var style: NotchStyle = .rings
    @Published var phase: OverlayPhase = .hidden
    @Published var liveText = ""
    @Published var resultText = ""
    @Published var resultLabel = ""
    @Published var showLiveText = true
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = true
    /// The notch's centre relative to the screen's, which can differ by half a point.
    @Published var notchCenterOffset: CGFloat = 0

    var iconHeight: CGFloat { hasNotch ? min(22, notchHeight - 12) : 18 }

    private var targetLevel: CGFloat = 0
    private var barHistory = [CGFloat](repeating: 0, count: 7)
    private var barPeak: CGFloat = 0
    private var barClock: TimeInterval = 0
    private static let barStep: TimeInterval = 0.085
    private(set) var displayLevel: CGFloat = 0
    /// Wave line's own, softer level, so its swell doesn't snap up and down with each syllable.
    private(set) var waveLevel: CGFloat = 0
    private(set) var displayBars = [CGFloat](repeating: 0, count: 7)
    private(set) var wavePhase: Double = 0
    private(set) var ringPhase: Double = 0
    private var lastFrame: TimeInterval = 0

    func push(level: Float) {
        let voiced = max(0, (CGFloat(level) - 0.06) / 0.94)  // ignores quiet room noise
        targetLevel = pow(voiced, 0.75)
    }

    func resetLevels() {
        targetLevel = 0
        displayLevel = 0
        waveLevel = 0
        barPeak = 0
        barClock = 0
        barHistory = [CGFloat](repeating: 0, count: barHistory.count)
        displayBars = barHistory
    }

    func advance(to time: TimeInterval) {
        let dt = min(max(time - lastFrame, 0), 0.05)
        lastFrame = time
        guard dt > 0 else { return }
        displayLevel = ease(displayLevel, toward: targetLevel, dt)
        waveLevel = ease(waveLevel, toward: targetLevel, dt, rise: 0.03, fall: 0.12)

        barPeak = max(barPeak, targetLevel)
        barHistory[barHistory.count - 1] = barPeak
        barClock += dt
        while barClock >= Self.barStep {
            barClock -= Self.barStep
            barHistory.removeFirst()
            barHistory.append(targetLevel)
            barPeak = targetLevel
        }
        for i in displayBars.indices { displayBars[i] = ease(displayBars[i], toward: barHistory[i], dt) }
        wavePhase += dt * (4 + 12.2 * Double(waveLevel))
        // One trip takes 6 s in silence and 1 s from normal speech upward.
        let ringRate = 1 / 6 + (1 - 1 / 6) * min(1, Double(displayLevel) / 0.7)
        ringPhase = (ringPhase + dt * ringRate).truncatingRemainder(dividingBy: 1)
    }

    private func ease(_ value: CGFloat, toward target: CGFloat, _ dt: TimeInterval,
                      rise: CGFloat = 0.008, fall: CGFloat = 0.04) -> CGFloat {
        let timeConstant = target > value ? rise : fall
        return value + (target - value) * (1 - exp(-CGFloat(dt) / timeConstant))
    }
}

/// Black island that grows out of the notch, to the left only: its right edge stays on the
/// notch's right edge, so nothing ever appears right of the notch. On Macs without a notch it's
/// a small pill hanging from the top centre of the screen.
struct NotchView: View {
    @ObservedObject var model: OverlayModel

    private let flare: CGFloat = 6
    private let textInset: CGFloat = 11

    private var showsIndicator: Bool { model.phase == .listening || model.phase == .processing }
    private var isError: Bool {
        if case .error = model.phase { return true }
        return false
    }
    private var contentLeading: CGFloat {
        guard model.hasNotch else { return 14 }
        guard showsIndicator else { return textInset }
        return detail == nil ? model.style.margins.leading : model.style.margins.withText
    }
    private var contentTrailing: CGFloat {
        guard model.hasNotch else { return 14 }
        if showsIndicator { return model.style.margins.trailing }
        return isError ? textInset : 3
    }
    private var islandShape: NotchShape {
        NotchShape(leftFlare: leftFlare, rightFlare: rightFlare, bottomRadius: detail == nil ? 14 : 16)
    }
    private var contentTiming: Animation {
        isVisible ? .easeOut(duration: 0.16).delay(0.14) : .easeIn(duration: 0.08)
    }

    private var wing: CGFloat {
        let content: CGFloat
        switch model.phase {
        case .listening, .processing: content = model.style.indicatorWidth
        case .error: content = 16
        default: content = 57
        }
        let width = content + contentLeading + contentTrailing
        // Without a notch the pill is centred, so an even width keeps it on whole pixels on 1x displays.
        return model.hasNotch ? width : (width / 2).rounded(.up) * 2
    }

    private var isVisible: Bool { model.phase != .hidden }
    private var topHeight: CGFloat { model.hasNotch ? model.notchHeight : 28 }
    private var gap: CGFloat { model.hasNotch ? model.notchWidth : 0 }

    private var detail: String? {
        switch model.phase {
        case .listening, .processing:
            return model.showLiveText && !model.liveText.isEmpty ? model.liveText : nil
        case .done:
            return model.resultText.isEmpty ? nil : model.resultText
        case .error(let message):
            return message
        case .hidden:
            return nil
        }
    }

    private var bodyWidth: CGFloat {
        guard isVisible else { return gap }
        // With a notch, text wraps inside the island instead of pushing it further left.
        return model.hasNotch || detail == nil ? wing + gap : 320
    }

    private var leftFlare: CGFloat { isVisible ? flare : 0 }
    private var rightFlare: CGFloat { isVisible && !model.hasNotch ? flare : 0 }

    private var offsetX: CGFloat {
        guard model.hasNotch else { return 0 }
        return model.notchCenterOffset + gap / 2 - (bodyWidth + leftFlare + rightFlare) / 2
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                status
                accessory
            }
            .frame(maxWidth: .infinity, alignment: model.hasNotch ? .leading : .center)
            .padding(.leading, contentLeading)
            .padding(.trailing, model.hasNotch ? gap + contentTrailing : 14)  // keep content out from under the notch
            .frame(height: topHeight)

            if let detail {
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(model.phase == .done ? .tail : .head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, model.hasNotch ? textInset : 18)
                    .padding(.top, 2)
                    .padding(.bottom, 13)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.14)),
                                            removal: .opacity.animation(.easeIn(duration: 0.08))))
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(contentTiming, value: isVisible)
        .frame(width: bodyWidth)
        .padding(.leading, leftFlare)
        .padding(.trailing, rightFlare)
        .background(islandShape.fill(.black))
        .clipShape(islandShape)
        .opacity(isVisible || model.hasNotch ? 1 : 0)
        .offset(x: offsetX)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.phase)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: detail)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .listening: NotchIndicator(model: model, processing: false)
        case .processing: NotchIndicator(model: model, processing: true)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .transition(.scale.combined(with: .opacity))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        case .hidden: EmptyView()
        }
    }

    @ViewBuilder private var accessory: some View {
        if model.phase == .done {
            Text(model.resultLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A flare of 0 gives a straight edge (used on the side that merges into the real notch).
struct NotchShape: Shape {
    var leftFlare: CGFloat
    var rightFlare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(bottomRadius, AnimatablePair(leftFlare, rightFlare)) }
        set {
            bottomRadius = newValue.first
            leftFlare = newValue.second.first
            rightFlare = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let l = leftFlare, rf = rightFlare
        let r = max(0, min(bottomRadius, h / 2, (w - l - rf) / 2))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: l, y: l), control: CGPoint(x: l, y: 0))
        p.addLine(to: CGPoint(x: l, y: h - r))
        p.addQuadCurve(to: CGPoint(x: l + r, y: h), control: CGPoint(x: l, y: h))
        p.addLine(to: CGPoint(x: w - rf - r, y: h))
        p.addQuadCurve(to: CGPoint(x: w - rf, y: h - r), control: CGPoint(x: w - rf, y: h))
        p.addLine(to: CGPoint(x: w - rf, y: rf))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - rf, y: 0))
        p.closeSubpath()
        return p
    }
}

private struct NotchIndicator: View {
    @ObservedObject var model: OverlayModel
    let processing: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let _ = model.advance(to: t)
            Canvas { g, size in
                switch model.style {
                case .rings:
                    drawRings(in: &g, size, t)
                case .waveform:
                    drawBars(in: &g, size, t)
                case .waveLine:
                    drawWaveLine(in: &g, size, t)
                }
            }
        }
        .frame(width: model.style.indicatorWidth, height: 28)
    }

    private func tilted(_ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            .applying(CGAffineTransform(rotationAngle: -.pi / 15)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    }

    private func drawRings(in g: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        // Inner rings sit toward the upper right, the Doppler shift.
        func center(_ r: CGFloat) -> CGPoint {
            CGPoint(x: size.width / 2 + 0.22 * (14 - r), y: size.height / 2 - 0.06 * (14 - r))
        }
        if processing {
            let brightness: [Double] = [1, 0.68, 0.46, 0.3]
            let rings: [CGFloat] = [3.2, 6.5, 10.1, 14]
            let pulseSize: [CGFloat] = [2.4, 2, 1.4, 0]
            for i in rings.indices {
                let r = rings[i] + pulseSize[i] * CGFloat(sin(t * 4 - Double(i) * 0.9) + 1) / 2
                g.stroke(tilted(center(r), r, r * 0.58), with: .color(.white.opacity(brightness[i])),
                         lineWidth: i == 0 ? 1.8 : 1.2)
            }
            return
        }

        let flow = model.ringPhase
        let amp = min(1, model.displayLevel * 1.15)
        let silent = 1 - amp
        let swell = 0.35 * CGFloat(sin(t * 1.3)) * (1 - amp)
        let outer = 16.2 + 1.1 * amp + swell
        func flowCenter(_ r: CGFloat) -> CGPoint {
            CGPoint(x: size.width / 2 + 0.22 * (outer - r), y: size.height / 2 - 0.06 * (outer - r))
        }
        let breath = 0.4 * CGFloat(sin(flow * 2 * .pi) + 1) / 2
        let beat = CGFloat((flow * 3).truncatingRemainder(dividingBy: 1))
        let kick: CGFloat = beat < 0.5 ? pow(sin(beat / 0.5 * .pi), 2) : 0
        let core = 3.1 + 1.3 * amp + breath + 0.75 * kick * silent
        let coreCenter = flowCenter(core)
        let coreX = core
        let coreY = core * 0.58
        g.stroke(tilted(coreCenter, coreX, coreY), with: .color(.white), lineWidth: 1.8)
        let start = core + 1.9
        for i in 0..<3 {
            let p = CGFloat((flow + Double(i) / 3).truncatingRemainder(dividingBy: 1))
            let r = start + pow(p, 1.25) * (outer - start)
            let fadeIn = min(1, p / 0.2)
            let fadeOut = 1 - pow(p, 2.6)
            let opacity = fadeIn * fadeIn * (3 - 2 * fadeIn) * fadeOut * 0.9
            g.stroke(tilted(flowCenter(r), r, r * 0.58), with: .color(.white.opacity(opacity)), lineWidth: 1.25)
        }
    }

    /// Heights snap to whole pixels so the edges stay crisp.
    private func drawBars(in g: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let x0 = (size.width - 39) / 2
        let scale = max(g.environment.displayScale, 1)
        for i in model.displayBars.indices {
            let height: CGFloat
            if processing {
                height = 3 + 9 * CGFloat(sin(t * 5 - Double(i) * 0.8) + 1) / 2
            } else {
                let voice = model.displayBars[i]
                let ripple = 2.4 * CGFloat(sin(t * 2.6 + Double(i) * 0.9) + 1) / 2
                height = 3 + ripple * (1 - voice) + (model.iconHeight - 3) * voice
            }
            let snapped = max(2, (height * scale / 2).rounded() * 2) / scale
            let bar = CGRect(x: x0 + CGFloat(i) * 6, y: (size.height - snapped) / 2, width: 3, height: snapped)
            g.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(.white))
        }
    }

    private func drawWaveLine(in g: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        if processing {
            drawScanLine(in: &g, size, t)
            return
        }
        let voice = model.waveLevel
        let swell = 0.45 * CGFloat(sin(t * 1.9)) * (1 - voice)
        let amp = 1.15 + swell + (model.iconHeight / 2 - 2.1) * pow(voice, 0.7)
        let travel = model.wavePhase
        let inset: CGFloat = 2  // room for the line's round caps inside the canvas
        let length = size.width - inset * 2
        for layer in 0..<2 {
            var path = Path()
            for step in 0...60 {
                let u = CGFloat(step) / 60
                let compressed = Double(u + 0.75 * u * u)
                let envelope = pow(max(0, sin(.pi * u)), 1.4)
                let drift = 0.22 * Double(1 - voice) * sin(compressed * 5.2 + t * 1.4)
                let wave = sin(compressed * 11.5 - travel + Double(layer) * 1.1) + drift
                let point = CGPoint(x: inset + u * length, y: size.height / 2 + amp * envelope * CGFloat(wave))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let color = Color.white.opacity(layer == 0 ? 1 : 0.32)
            let fade = Gradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color, location: 0.18),
                                        .init(color: color, location: 0.82), .init(color: color.opacity(0), location: 1)])
            g.stroke(path, with: .linearGradient(fade, startPoint: CGPoint(x: inset, y: 0),
                                                 endPoint: CGPoint(x: inset + length, y: 0)),
                     style: StrokeStyle(lineWidth: layer == 0 ? 1.8 : 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawScanLine(in g: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let start = CGPoint(x: 2, y: size.height / 2)
        let end = CGPoint(x: size.width - 2, y: size.height / 2)
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)

        let dim = Color.white.opacity(0.24)
        let track = Gradient(stops: [.init(color: dim.opacity(0), location: 0), .init(color: dim, location: 0.18),
                                     .init(color: dim, location: 0.82), .init(color: dim.opacity(0), location: 1)])
        g.stroke(line, with: .linearGradient(track, startPoint: start, endPoint: end),
                 style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        let center = 0.5 + 0.34 * CGFloat(sin(t * 3.6))
        let reach: CGFloat = 0.16
        let light = Gradient(stops: [.init(color: .white.opacity(0), location: center - reach),
                                     .init(color: .white, location: center),
                                     .init(color: .white.opacity(0), location: center + reach)])
        g.stroke(line, with: .linearGradient(light, startPoint: start, endPoint: end),
                 style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }
}

final class NotchPanel: NSPanel {
    static let size = NSSize(width: 640, height: 180)
    private let model: OverlayModel
    private var hideWork: DispatchWorkItem?

    init(model: OverlayModel) {
        self.model = model
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchView(model: model))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func show() {
        hideWork?.cancel()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            model.hasNotch = true
            model.notchWidth = screen.frame.width - left.width - right.width
            model.notchHeight = screen.safeAreaInsets.top
            model.notchCenterOffset = left.width + model.notchWidth / 2 - screen.frame.width / 2
        } else {
            model.hasNotch = false
        }
        setFrame(NSRect(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY - Self.size.height,
                        width: Self.size.width, height: Self.size.height), display: true)
        orderFrontRegardless()
    }

    /// Shows the panel, then switches phase on the next pass, so the island visibly grows out of
    /// the notch instead of appearing already open.
    func present(_ phase: OverlayPhase) {
        hideWork?.cancel()  // the last result's pending hide would close this one
        guard !isVisible || model.phase == .hidden else { model.phase = phase; return }
        show()
        // After the panel's first frame is on screen, so there is a "before" to animate from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [model] in
            if model.phase == .hidden { model.phase = phase }
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.phase = .hidden
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if self?.model.phase == .hidden { self?.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
