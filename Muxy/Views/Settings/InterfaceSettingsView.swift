import SwiftUI

struct InterfaceSettingsView: View {
    @State private var uiScale = UIScale.shared
    @AppStorage(GeneralSettingsKeys.autoExpandWorktreesOnProjectSwitch)
    private var autoExpandWorktrees = false
    @AppStorage("muxy.vcsDisplayMode") private var vcsDisplayMode = VCSDisplayMode.attached.rawValue
    @AppStorage(SidebarCollapsedStyle.storageKey) private var sidebarCollapsedStyle = SidebarCollapsedStyle.defaultValue.rawValue
    @AppStorage(SidebarExpandedStyle.storageKey) private var sidebarExpandedStyle = SidebarExpandedStyle.defaultValue.rawValue
    @AppStorage("muxy.showStatusBar") private var showStatusBar = true
    @AppStorage(AppTransparencyPreferences.enabledKey)
    private var transparencyEnabled = AppTransparencyPreferences.defaultEnabled
    @AppStorage(AppTransparencyPreferences.intensityKey)
    private var transparencyIntensity = AppTransparencyPreferences.defaultIntensity
    @AppStorage(AppTransparencyPreferences.appearanceModeKey)
    private var transparencyAppearanceMode = AppTransparencyPreferences.defaultAppearanceMode.rawValue

    var body: some View {
        SettingsContainer {
            SettingsSection("Interface") {
                SettingsRow("Size") {
                    Picker("", selection: $uiScale.preset) {
                        ForEach(UIScale.Preset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: SettingsMetrics.controlWidth)
                }

                SettingsToggleRow(label: "Show Status Bar", isOn: $showStatusBar)

                SettingsToggleRow(
                    label: "Transparency Mode",
                    isOn: Binding(
                        get: { transparencyEnabled },
                        set: { enabled in
                            AppTransparencyPreferences.setEnabled(enabled)
                        }
                    )
                )

                SettingsRow("Transparency Colors") {
                    Picker("", selection: Binding(
                        get: { transparencyAppearanceMode },
                        set: { rawValue in
                            guard let mode = AppTransparencyPreferences.AppearanceMode(rawValue: rawValue) else { return }
                            AppTransparencyPreferences.setAppearanceMode(mode)
                        }
                    )) {
                        ForEach(AppTransparencyPreferences.AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: SettingsMetrics.controlWidth)
                    .disabled(!transparencyEnabled)
                }

                SettingsRow("Transparency Intensity") {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { transparencyIntensity },
                                set: { value in AppTransparencyPreferences.setIntensity(value) }
                            ),
                            in: AppTransparencyPreferences.minIntensity ... AppTransparencyPreferences.maxIntensity
                        )
                        .frame(width: SettingsMetrics.controlWidth - 50)
                        .disabled(!transparencyEnabled)

                        Text("\(Int((transparencyIntensity * 100).rounded()))%")
                            .font(.system(size: SettingsMetrics.labelFontSize, design: .monospaced))
                            .foregroundStyle(transparencyEnabled ? SettingsStyle.foreground : SettingsStyle.dimForeground)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            SettingsSection("Sidebar") {
                SettingsToggleRow(
                    label: "Auto-expand worktrees on project switch",
                    isOn: $autoExpandWorktrees
                )

                SettingsRow("Collapsed Style") {
                    HStack {
                        Spacer()
                        Picker("", selection: $sidebarCollapsedStyle) {
                            ForEach(SidebarCollapsedStyle.allCases) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    .frame(width: SettingsMetrics.controlWidth)
                }

                SettingsRow("Expanded Style") {
                    HStack {
                        Spacer()
                        Picker("", selection: $sidebarExpandedStyle) {
                            ForEach(SidebarExpandedStyle.allCases) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    .frame(width: SettingsMetrics.controlWidth)
                }
            }

            SettingsSection("Source Control", showsDivider: false) {
                SettingsRow("Display Mode") {
                    Picker("", selection: $vcsDisplayMode) {
                        ForEach(VCSDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: SettingsMetrics.controlWidth)
                }
            }
        }
    }
}
