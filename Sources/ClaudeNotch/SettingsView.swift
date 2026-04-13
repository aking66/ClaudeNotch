import SwiftUI

/// In-panel settings view, shown when the user taps the gear icon.
/// Styled to match the dark notch aesthetic with toggle rows.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // Sound section
                    settingsSection("Sound") {
                        settingsToggle("Sounds", isOn: $settings.soundEnabled,
                                       icon: settings.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        if settings.soundEnabled {
                            settingsToggle("Permission prompt", isOn: $settings.soundOnPermission, indent: true)
                            settingsToggle("Task complete", isOn: $settings.soundOnCompletion, indent: true)
                            settingsToggle("Session start", isOn: $settings.soundOnStart, indent: true)
                        }
                    }

                    // Display section
                    settingsSection("Display") {
                        settingsToggle("Subagents", isOn: $settings.showSubagents,
                                       icon: "arrow.triangle.branch")
                        settingsToggle("Tasks / Todos", isOn: $settings.showTasks,
                                       icon: "checklist")
                        settingsToggle("Tool badge", isOn: $settings.showToolBadge,
                                       icon: "wrench.fill")
                        settingsToggle("Conversation card", isOn: $settings.showConversationCard,
                                       icon: "text.bubble.fill")
                    }

                    // Auto-Approve section
                    settingsSection("Auto-Approve") {
                        settingsToggle("Copilot mode (approve all)", isOn: $settings.copilotEnabled,
                                       icon: "bolt.shield.fill")
                        if !settings.copilotEnabled {
                            Text("Per-tool auto-approve:")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.leading, 22)
                            ForEach(["Read", "Grep", "Glob", "Edit", "Write", "Bash", "Agent", "WebSearch", "WebFetch"], id: \.self) { tool in
                                toolToggle(tool)
                            }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .frame(width: 14)
                            Text("Decision")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Picker("", selection: $settings.autoApproveDecision) {
                                Text("Allow Once").tag("allow")
                                Text("Always Allow").tag("always_allow")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                            .scaleEffect(0.8)
                        }
                    }

                    // Behavior section
                    settingsSection("Behavior") {
                        settingsToggle("Auto-expand on permission", isOn: $settings.autoExpandOnPermission,
                                       icon: "exclamationmark.shield.fill")
                        settingsToggle("Auto-expand on completion", isOn: $settings.autoExpandOnCompletion,
                                       icon: "checkmark.circle.fill")
                        settingsToggle("Suppress when terminal focused", isOn: $settings.suppressWhenTerminalFocused,
                                       icon: "terminal.fill")

                        // Auto-collapse delay
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .frame(width: 14)
                            Text("Auto-collapse")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text("\(Int(settings.autoCollapseDelay))s")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.cyan)
                            Slider(value: $settings.autoCollapseDelay, in: 3...30, step: 1)
                                .frame(width: 80)
                                .tint(.cyan)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Components

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }

    private func settingsToggle(_ label: String, isOn: Binding<Bool>,
                                 icon: String? = nil, indent: Bool = false) -> some View {
        HStack(spacing: 8) {
            if indent {
                Spacer().frame(width: 14)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(isOn.wrappedValue ? .cyan : .white.opacity(0.3))
                    .frame(width: 14)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.65)
                .frame(width: 36)
        }
    }

    private func toolToggle(_ tool: String) -> some View {
        let isOn = Binding<Bool>(
            get: { settings.autoApproveTools.contains(tool) },
            set: { enabled in
                if enabled { settings.autoApproveTools.insert(tool) }
                else { settings.autoApproveTools.remove(tool) }
            }
        )
        return settingsToggle(tool, isOn: isOn, indent: true)
    }
}
