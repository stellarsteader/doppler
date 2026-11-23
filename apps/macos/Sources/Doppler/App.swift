import AppKit
import SwiftUI

struct DopplerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(controller)
                .environmentObject(settings)
        } label: {
            Image(nsImage: MenuBarIcon.glyph)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.setup()
    }
}

enum MenuBarIcon {
    static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            let edges: [(x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat, angle: CGFloat)] = [
                (10.00, 8.00, 9.84, 6.06, 16.3),
                (10.96, 9.28, 6.87, 4.15, 14.9),
                (11.83, 10.24, 4.23, 2.51, 13.7),
                (12.53, 10.88, 2.16, 1.27, 12.9),
            ]
            let rings = NSBezierPath()
            rings.windingRule = .evenOdd
            for edge in edges {
                let oval = NSBezierPath(ovalIn: NSRect(x: -edge.rx, y: -edge.ry, width: edge.rx * 2, height: edge.ry * 2))
                let radians = edge.angle * .pi / 180
                oval.transform(using: AffineTransform(m11: cos(radians), m12: sin(radians),
                                                      m21: -sin(radians), m22: cos(radians),
                                                      tX: edge.x, tY: edge.y))
                rings.append(oval)
            }
            rings.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct MenuContent: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: AppSettings
    @State private var copiedIndex: Int?
    @State private var clearCopied: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let error = controller.lastError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(Mono.error)
                .padding(.horizontal, 8)
            }

            if !controller.recent.isEmpty {
                panelDivider
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Mono.secondary)
                    .padding(.horizontal, 8)
                VStack(spacing: 0) {
                    ForEach(Array(controller.recent.prefix(5).enumerated()), id: \.offset) { index, text in
                        Button { copy(text, at: index) } label: {
                            HStack(spacing: 6) {
                                Text(text).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                if copiedIndex == index {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Mono.secondary)
                                }
                            }
                        }
                        .buttonStyle(PanelRowStyle())
                        .help("Copy")
                    }
                }
            }

            panelDivider
            VStack(spacing: 0) {
                SettingsLink { actionLabel("Settings…", shortcut: "⌘,") }
                    .keyboardShortcut(",")
                    .buttonStyle(PanelRowStyle())
                Button { NSApp.terminate(nil) } label: { actionLabel("Quit Doppler", shortcut: "⌘Q") }
                    .keyboardShortcut("q")
                    .buttonStyle(PanelRowStyle())
            }
        }
        .padding(8)
        .frame(width: 300)
        .background(Mono.background)
        .background(MenuPanelWindow())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(nsImage: MenuBarIcon.glyph)
                Text("Doppler").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Circle().fill(Mono.text).frame(width: 6, height: 6)
                Text(status).font(.system(size: 12)).foregroundStyle(Mono.secondary)
            }
            if controller.state == .idle {
                Text("\(settings.mode == .hold ? "Hold" : "Press") \(settings.hotkey.parts.joined(separator: " ")) to talk")
                    .font(.system(size: 12))
                    .foregroundStyle(Mono.secondary)
            }
        }
        .foregroundStyle(Mono.text)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func copy(_ text: String, at index: Int) {
        controller.copyRecent(text)
        copiedIndex = index
        clearCopied?.cancel()
        clearCopied = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { copiedIndex = nil }
        }
    }

    private var panelDivider: some View {
        Rectangle().fill(Mono.line).frame(height: 1).padding(.horizontal, 8)
    }

    private func actionLabel(_ title: String, shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 0)
            Text(shortcut).font(.system(size: 12)).foregroundStyle(Mono.secondary)
        }
    }

    private var status: String {
        switch controller.state {
        case .idle: "Ready"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }
}
