import AppKit
import SwiftUI

enum Mono {
    static let background = Color.black
    static let surface = Color(white: 0x11 / 255)
    static let control = Color(white: 0x26 / 255)
    static let line = Color(white: 0x26 / 255)
    static let text = Color.white
    static let secondary = Color(white: 0x8A / 255)
    static let error = Color(red: 1, green: 0.27, blue: 0.23)
    static let rowHeight: CGFloat = 40
    static let pickerWidth: CGFloat = 180
    static let pageMargin: CGFloat = 18
    static let windowWidth: CGFloat = 500 + pageMargin * 2
    static let minWindowWidth: CGFloat = 400
    /// 340 pt tall including the 32 pt title bar.
    static let minContentHeight: CGFloat = 308
    static let tabBarHeight: CGFloat = 60
    /// 4 pt of visible space, plus the 5 pt that AppKit shifts a popped-up menu upward.
    static let menuGap: CGFloat = 9
}

private struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FocusView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
        }
    }
}

struct SettingsWindowChrome: NSViewRepresentable {
    let sizer: SettingsWindowSizer

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        view.sizer = sizer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        var sizer: SettingsWindowSizer?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            sizer?.window = window
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(white: 0x11 / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
        }
    }
}

/// Fits the window's height to the tab's content, keeping its top edge in place. A height the
/// user dragged smaller is kept until they switch tabs.
final class SettingsWindowSizer {
    weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }
            // The Settings scene keeps turning resizing off, whenever a tab's height is fixed too.
            styleObservation = window.observe(\.styleMask, options: [.initial]) { window, _ in
                guard !window.styleMask.contains(.resizable) else { return }
                DispatchQueue.main.async { window.styleMask.insert(.resizable) }
            }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.apply(self.fittedHeight, to: window)
            }
        }
    }
    private var styleObservation: NSKeyValueObservation?
    private var fittedHeight: CGFloat = 0

    func fit(to height: CGFloat, newTab: Bool) {
        let previous = fittedHeight
        fittedHeight = height
        guard let window, !window.inLiveResize else { return }
        let wasFull = window.contentLayoutRect.height >= previous - 0.5
        guard newTab || wasFull else { return }
        // On the next pass, once SwiftUI has applied the new tab's size limits.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.apply(height, to: window)
        }
    }

    private func apply(_ height: CGFloat, to window: NSWindow) {
        guard height > 0 else { return }
        var frame = window.frame
        let titleBar = frame.height - window.contentLayoutRect.height  // content runs under the title bar
        let visible = window.screen?.visibleFrame ?? frame
        let target = min(height + titleBar, visible.height)
        guard abs(target - frame.height) >= 0.5 else { return }
        let top = frame.maxY
        frame.size.height = target
        frame.origin.y = max(top - target, visible.minY)
        window.setFrame(frame, display: true)
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// A black menu bar panel, raised 1 pt because SwiftUI opens it 2 pt below the menu bar
/// while the system's own menu bar popups sit 1 pt below it.
struct MenuPanelWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PanelView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PanelView: NSView {
        private var observer: NSObjectProtocol?
        private var raisedTop: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.raise() }
            if window.isKeyWindow { raise() }
        }

        /// SwiftUI may or may not re-place the panel each time it opens, so never raise it twice.
        private func raise() {
            guard let window, window.frame.maxY != raisedTop else { return }
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: window.frame.minY + 1))
            raisedTop = window.frame.maxY
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.horizontal, Mono.pageMargin)
            .padding(.top, 14)
            .padding(.bottom, Mono.pageMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Mono.background)
            .background(NoInitialFocus())
    }
}

struct SettingsCard<Content: View, Footer: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Mono.secondary)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(Mono.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Mono.line))
            footer
                .font(.system(size: 11))
                .foregroundStyle(Mono.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }
}

extension SettingsCard where Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.footer = EmptyView()
    }
}

extension SettingsCard {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Mono.line).frame(height: 1).padding(.leading, 14)
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var inset: CGFloat = 0
    @ViewBuilder let trailing: Trailing
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, inset: CGFloat = 0, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.inset = inset
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Mono.text)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 14 + inset)
        .padding(.trailing, 12)
        .frame(height: Mono.rowHeight)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

struct ToggleRow: View {
    let title: String
    var inset: CGFloat = 0
    @Binding var isOn: Bool

    init(_ title: String, inset: CGFloat = 0, isOn: Binding<Bool>) {
        self.title = title
        self.inset = inset
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, inset: inset) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(MonoSwitchStyle())
        }
    }
}

struct MonoSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Mono.text : Mono.control)
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.black : Mono.secondary)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct MonoSegmented<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.black : Mono.text)
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(selected ? Mono.text : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Mono.control, in: RoundedRectangle(cornerRadius: 7))
    }
}

enum MonoMenuEntry<Value: Hashable> {
    case option(String, Value)
    case divider
}

struct MonoPicker<Value: Hashable>: View {
    let title: String
    let value: String
    @Binding var selection: Value
    let entries: [MonoMenuEntry<Value>]
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(Mono.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Mono.secondary)
            }
            .frame(width: Mono.pickerWidth, height: 24, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        for entry in entries {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case let .option(name, option):
                let item = ActionMenuItem(title: name) { selection = option }
                item.state = option == selection ? .on : .off
                menu.addItem(item)
            }
        }
        let y = view.isFlipped ? view.bounds.maxY + Mono.menuGap : view.bounds.minY - Mono.menuGap
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - menu.size.width, y: y), in: view)
    }
}

private final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: clamped, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .multilineTextAlignment(.center)
                .labelsHidden()
                .frame(width: 34, height: 22)
                .background(Mono.control, in: RoundedRectangle(cornerRadius: 5))
            Text(unit).font(.system(size: 12)).foregroundStyle(Mono.secondary)
            Stepper("", value: clamped, in: range)
                .labelsHidden()
        }
    }
}

struct MonoButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.black : Mono.text)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(prominent ? Mono.text : Mono.control, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Mono.secondary)
            .frame(width: 22, height: 22)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelRowBody(configuration: configuration)
    }

    private struct PanelRowBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(Mono.text)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    Color.white.opacity(configuration.isPressed ? 0.18 : hovering ? 0.1 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
