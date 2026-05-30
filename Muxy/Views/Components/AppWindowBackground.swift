import AppKit
import SwiftUI

@MainActor
struct AppWindowVibrancyBackground: NSViewRepresentable {
    let enabled: Bool
    let intensity: Double

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.isHidden = !enabled
        view.state = enabled ? .active : .inactive
        view.material = AppTransparencyPreferences.visualEffectMaterial(isDark: MuxyTheme.colorScheme == .dark)
        view.alphaValue = enabled ? CGFloat(0.65 + AppTransparencyPreferences.clampedIntensity(intensity) * 0.35) : 0
    }
}

@MainActor
struct AppWindowBackgroundConfigurator: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Self.apply(to: window, enabled: enabled)
        }
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        guard let window = view.window else { return }
        Self.apply(to: window, enabled: enabled)
    }

    static func apply(to window: NSWindow, enabled: Bool) {
        AppTransparencyPreferences.configureWindow(window, enabled: enabled)
    }
}
