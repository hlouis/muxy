import AppKit
import Foundation
import SwiftUI

@MainActor
enum AppTransparencyPreferences {
    nonisolated static let enabledKey = "muxy.interface.transparencyEnabled"
    nonisolated static let intensityKey = "muxy.interface.transparencyIntensity"
    nonisolated static let appearanceModeKey = "muxy.interface.transparencyAppearanceMode"
    nonisolated static let defaultEnabled = false
    nonisolated static let defaultIntensity = 0.5
    nonisolated static let defaultAppearanceMode = AppearanceMode.system
    nonisolated static let minIntensity = 0.0
    nonisolated static let maxIntensity = 1.0

    nonisolated static let terminalConfigKeys = [
        "background-opacity",
        "background-opacity-cells",
        "background-blur",
    ]

    nonisolated private static let terminalOpaqueConfig = [
        "background-opacity": "1",
        "background-opacity-cells": "false",
        "background-blur": "false",
    ]

    nonisolated private static let backupActiveKey = "muxy.interface.transparency.terminalBackupActive"
    nonisolated private static let missingValue = "__muxy_missing__"

    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark
        case theme

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            case .theme: "Theme"
            }
        }
    }

    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var intensity: Double {
        guard UserDefaults.standard.object(forKey: intensityKey) != nil else { return defaultIntensity }
        return clampedIntensity(UserDefaults.standard.double(forKey: intensityKey))
    }

    static var appearanceMode: AppearanceMode {
        guard let rawValue = UserDefaults.standard.string(forKey: appearanceModeKey),
              let mode = AppearanceMode(rawValue: rawValue)
        else { return defaultAppearanceMode }
        return mode
    }

    static var editorBackgroundOpacity: CGFloat {
        CGFloat(interpolatedOpacity(subtle: 0.96, strong: 0.76))
    }

    static var windowVibrancyAlpha: CGFloat {
        CGFloat(0.65 + intensity * 0.35)
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: defaultEnabled,
            intensityKey: defaultIntensity,
            appearanceModeKey: defaultAppearanceMode.rawValue,
        ])
    }

    static func setEnabled(_ enabled: Bool) {
        let changed = isEnabled != enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if changed || enabled {
            applyTerminalConfiguration(enabled: enabled, restoresOpaqueState: true)
        }
        SettingsJSONStore.syncUserSettingsFileWithCurrentSettings()
        if changed {
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }

    static func setIntensity(_ intensity: Double) {
        let clamped = clampedIntensity(intensity)
        let changed = abs(Self.intensity - clamped) > 0.001
        UserDefaults.standard.set(clamped, forKey: intensityKey)
        if isEnabled {
            applyTerminalConfiguration(enabled: true, restoresOpaqueState: false)
        }
        SettingsJSONStore.syncUserSettingsFileWithCurrentSettings()
        if changed {
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }

    static func setAppearanceMode(_ mode: AppearanceMode) {
        let changed = appearanceMode != mode
        UserDefaults.standard.set(mode.rawValue, forKey: appearanceModeKey)
        SettingsJSONStore.syncUserSettingsFileWithCurrentSettings()
        if changed {
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }

    static func applyCurrentModeToTerminal() {
        guard isEnabled else { return }
        applyTerminalConfiguration(enabled: true, restoresOpaqueState: false)
    }

    static func color(_ color: Color) -> Color {
        isEnabled ? .clear : color
    }

    static func nsBackgroundColor(_ color: NSColor) -> NSColor {
        isEnabled ? .clear : color
    }

    static func nsEditorBackgroundColor(_ color: NSColor) -> NSColor {
        nsBackgroundColor(color, enabled: isEnabled, opacity: editorBackgroundOpacity)
    }

    nonisolated static func nsBackgroundColor(_ color: NSColor, enabled: Bool, opacity: CGFloat) -> NSColor {
        enabled ? color.withAlphaComponent(opacity) : color
    }

    nonisolated static func visualEffectMaterial(isDark: Bool) -> NSVisualEffectView.Material {
        isDark ? .hudWindow : .sidebar
    }

    static func resolvedAppearance() -> ThemeAppearance {
        switch appearanceMode {
        case .system,
             .theme:
            ThemeService.isCurrentAppearanceDark() ? .dark : .light
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    static func preferredColorScheme() -> ColorScheme {
        guard isEnabled else { return MuxyTheme.colorScheme }
        switch resolvedAppearance() {
        case .light:
            return ColorScheme.light
        case .dark:
            return ColorScheme.dark
        }
    }

    static func paletteIfNeeded() -> EditorThemePalette? {
        guard isEnabled, appearanceMode != .theme else { return nil }
        return transparencyPalette(for: resolvedAppearance())
    }

    nonisolated static func terminalConfig(enabled: Bool) -> [String: String] {
        enabled ? terminalTransparentConfig(intensity: defaultIntensity) : terminalOpaqueConfig
    }

    static func terminalConfigForCurrentIntensity(enabled: Bool) -> [String: String] {
        enabled ? terminalTransparentConfig(intensity: intensity) : terminalOpaqueConfig
    }

    static func configureWindow(_ window: NSWindow, enabled: Bool) {
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : MuxyTheme.nsBg
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.isOpaque = false
        window.contentView?.layer?.backgroundColor = enabled ? CGColor.clear : MuxyTheme.nsBg.cgColor
    }

    private static func applyTerminalConfiguration(enabled: Bool, restoresOpaqueState: Bool) {
        let config = MuxyConfig.shared
        if enabled {
            saveOriginalTerminalConfigurationIfNeeded(config: config)
            for (key, value) in terminalConfigForCurrentIntensity(enabled: true) {
                config.updateConfigValue(key, value: value)
            }
        } else if restoresOpaqueState {
            restoreTerminalConfiguration(config: config)
        }
        GhosttyService.shared.reloadConfig()
    }

    private static func saveOriginalTerminalConfigurationIfNeeded(config: MuxyConfig) {
        guard !UserDefaults.standard.bool(forKey: backupActiveKey) else { return }
        for key in terminalConfigKeys {
            UserDefaults.standard.set(config.configValue(for: key) ?? missingValue, forKey: backupKey(for: key))
        }
        UserDefaults.standard.set(true, forKey: backupActiveKey)
    }

    private static func restoreTerminalConfiguration(config: MuxyConfig) {
        guard UserDefaults.standard.bool(forKey: backupActiveKey) else {
            for (key, value) in terminalOpaqueConfig {
                config.updateConfigValue(key, value: value)
            }
            return
        }
        for key in terminalConfigKeys {
            let stored = UserDefaults.standard.string(forKey: backupKey(for: key)) ?? missingValue
            if stored == missingValue {
                config.removeConfigValue(key)
            } else {
                config.updateConfigValue(key, value: stored)
            }
            UserDefaults.standard.removeObject(forKey: backupKey(for: key))
        }
        UserDefaults.standard.removeObject(forKey: backupActiveKey)
    }

    private static func backupKey(for key: String) -> String {
        "muxy.interface.transparency.terminalBackup.\(key)"
    }

    nonisolated private static func terminalTransparentConfig(intensity: Double) -> [String: String] {
        [
            "background-opacity": String(format: "%.2f", interpolatedOpacity(intensity: intensity, subtle: 0.96, strong: 0.60)),
            "background-opacity-cells": "true",
            "background-blur": "macos-glass-regular",
        ]
    }

    nonisolated private static func interpolatedOpacity(intensity: Double, subtle: Double, strong: Double) -> Double {
        subtle - (subtle - strong) * clampedIntensity(intensity)
    }

    private static func interpolatedOpacity(subtle: Double, strong: Double) -> Double {
        interpolatedOpacity(intensity: intensity, subtle: subtle, strong: strong)
    }

    nonisolated static func clampedIntensity(_ value: Double) -> Double {
        min(maxIntensity, max(minIntensity, value))
    }

    nonisolated private static func transparencyPalette(for appearance: ThemeAppearance) -> EditorThemePalette {
        switch appearance {
        case .dark:
            EditorThemePalette(
                background: NSColor(srgbRed: 0.071, green: 0.078, blue: 0.092, alpha: 1),
                foreground: NSColor(srgbRed: 0.91, green: 0.94, blue: 0.96, alpha: 1),
                accent: NSColor(srgbRed: 0.29, green: 0.72, blue: 0.93, alpha: 1),
                paletteColors: darkPalette
            )
        case .light:
            EditorThemePalette(
                background: NSColor(srgbRed: 0.94, green: 0.955, blue: 0.97, alpha: 1),
                foreground: NSColor(srgbRed: 0.12, green: 0.145, blue: 0.18, alpha: 1),
                accent: NSColor(srgbRed: 0.0, green: 0.44, blue: 0.72, alpha: 1),
                paletteColors: lightPalette
            )
        }
    }

    nonisolated private static let darkPalette: [Int: NSColor] = [
        0: NSColor(srgbRed: 0.071, green: 0.078, blue: 0.092, alpha: 1),
        1: NSColor(srgbRed: 0.95, green: 0.35, blue: 0.42, alpha: 1),
        2: NSColor(srgbRed: 0.35, green: 0.82, blue: 0.53, alpha: 1),
        3: NSColor(srgbRed: 0.95, green: 0.76, blue: 0.36, alpha: 1),
        4: NSColor(srgbRed: 0.29, green: 0.72, blue: 0.93, alpha: 1),
        5: NSColor(srgbRed: 0.76, green: 0.57, blue: 0.96, alpha: 1),
        6: NSColor(srgbRed: 0.39, green: 0.86, blue: 0.83, alpha: 1),
        8: NSColor(srgbRed: 0.52, green: 0.58, blue: 0.66, alpha: 1),
    ]

    nonisolated private static let lightPalette: [Int: NSColor] = [
        0: NSColor(srgbRed: 0.94, green: 0.955, blue: 0.97, alpha: 1),
        1: NSColor(srgbRed: 0.78, green: 0.16, blue: 0.26, alpha: 1),
        2: NSColor(srgbRed: 0.11, green: 0.58, blue: 0.28, alpha: 1),
        3: NSColor(srgbRed: 0.72, green: 0.46, blue: 0.05, alpha: 1),
        4: NSColor(srgbRed: 0.0, green: 0.44, blue: 0.72, alpha: 1),
        5: NSColor(srgbRed: 0.46, green: 0.25, blue: 0.72, alpha: 1),
        6: NSColor(srgbRed: 0.0, green: 0.53, blue: 0.58, alpha: 1),
        8: NSColor(srgbRed: 0.48, green: 0.53, blue: 0.6, alpha: 1),
    ]
}
