import AppKit
import Testing

@testable import Muxy

@Suite("AppTransparencyPreferences")
@MainActor
struct AppTransparencyPreferencesTests {
    @Test
    func backgroundOpacityOnlyAppliesWhenEnabled() {
        let color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)

        let disabled = AppTransparencyPreferences.nsBackgroundColor(color, enabled: false, opacity: 0.5)
        let enabled = AppTransparencyPreferences.nsBackgroundColor(color, enabled: true, opacity: 0.5)

        #expect(disabled.alphaComponent == 1)
        #expect(enabled.alphaComponent == 0.5)
    }

    @Test
    func appBackgroundBecomesClearWhenTransparencyIsEnabled() {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: AppTransparencyPreferences.enabledKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: AppTransparencyPreferences.enabledKey)
            } else {
                defaults.removeObject(forKey: AppTransparencyPreferences.enabledKey)
            }
        }

        let color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)

        defaults.set(false, forKey: AppTransparencyPreferences.enabledKey)
        #expect(AppTransparencyPreferences.nsBackgroundColor(color).alphaComponent == 1)

        defaults.set(true, forKey: AppTransparencyPreferences.enabledKey)
        #expect(AppTransparencyPreferences.nsBackgroundColor(color).alphaComponent == 0)
    }

    @Test
    func paletteIsForcedUnlessThemeModeIsSelected() {
        let defaults = UserDefaults.standard
        let originalEnabled = defaults.object(forKey: AppTransparencyPreferences.enabledKey)
        let originalMode = defaults.object(forKey: AppTransparencyPreferences.appearanceModeKey)
        defer {
            restore(originalEnabled, key: AppTransparencyPreferences.enabledKey)
            restore(originalMode, key: AppTransparencyPreferences.appearanceModeKey)
        }

        defaults.set(true, forKey: AppTransparencyPreferences.enabledKey)
        defaults.set(AppTransparencyPreferences.AppearanceMode.light.rawValue, forKey: AppTransparencyPreferences.appearanceModeKey)
        #expect(AppTransparencyPreferences.paletteIfNeeded() != nil)
        #expect(AppTransparencyPreferences.preferredColorScheme() == .light)

        defaults.set(AppTransparencyPreferences.AppearanceMode.dark.rawValue, forKey: AppTransparencyPreferences.appearanceModeKey)
        #expect(AppTransparencyPreferences.paletteIfNeeded() != nil)
        #expect(AppTransparencyPreferences.preferredColorScheme() == .dark)

        defaults.set(AppTransparencyPreferences.AppearanceMode.theme.rawValue, forKey: AppTransparencyPreferences.appearanceModeKey)
        #expect(AppTransparencyPreferences.paletteIfNeeded() == nil)
    }

    @Test
    func vibrancyMaterialFollowsAppearance() {
        #expect(AppTransparencyPreferences.visualEffectMaterial(isDark: true) == .hudWindow)
        #expect(AppTransparencyPreferences.visualEffectMaterial(isDark: false) == .sidebar)
    }

    @Test
    func terminalConfigMatchesMode() {
        let transparent = AppTransparencyPreferences.terminalConfig(enabled: true)
        let opaque = AppTransparencyPreferences.terminalConfig(enabled: false)

        #expect(transparent["background-opacity"] == "0.78")
        #expect(transparent["background-opacity-cells"] == "true")
        #expect(transparent["background-blur"] == "macos-glass-regular")
        #expect(opaque["background-opacity"] == "1")
        #expect(opaque["background-opacity-cells"] == "false")
        #expect(opaque["background-blur"] == "false")
    }

    @Test
    func terminalConfigFollowsCurrentIntensity() {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: AppTransparencyPreferences.intensityKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: AppTransparencyPreferences.intensityKey)
            } else {
                defaults.removeObject(forKey: AppTransparencyPreferences.intensityKey)
            }
        }

        defaults.set(1.0, forKey: AppTransparencyPreferences.intensityKey)
        #expect(AppTransparencyPreferences.terminalConfigForCurrentIntensity(enabled: true)["background-opacity"] == "0.60")

        defaults.set(0.0, forKey: AppTransparencyPreferences.intensityKey)
        #expect(AppTransparencyPreferences.terminalConfigForCurrentIntensity(enabled: true)["background-opacity"] == "0.96")
    }

    @Test
    func intensityClampsToSupportedRange() {
        #expect(AppTransparencyPreferences.clampedIntensity(-0.5) == AppTransparencyPreferences.minIntensity)
        #expect(AppTransparencyPreferences.clampedIntensity(1.5) == AppTransparencyPreferences.maxIntensity)
        #expect(AppTransparencyPreferences.clampedIntensity(0.4) == 0.4)
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
