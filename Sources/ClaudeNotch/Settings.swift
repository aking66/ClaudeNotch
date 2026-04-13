import Foundation
import Combine

/// Central settings store backed by UserDefaults. Observable so SwiftUI
/// views react immediately when a setting changes. Each setting has a
/// sensible default so the app works out of the box.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Sound

    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: "soundEnabled"); syncSound() }
    }

    @Published var soundOnPermission: Bool {
        didSet { defaults.set(soundOnPermission, forKey: "soundOnPermission") }
    }

    @Published var soundOnCompletion: Bool {
        didSet { defaults.set(soundOnCompletion, forKey: "soundOnCompletion") }
    }

    @Published var soundOnStart: Bool {
        didSet { defaults.set(soundOnStart, forKey: "soundOnStart") }
    }

    // MARK: - Display

    @Published var showSubagents: Bool {
        didSet { defaults.set(showSubagents, forKey: "showSubagents") }
    }

    @Published var showTasks: Bool {
        didSet { defaults.set(showTasks, forKey: "showTasks") }
    }

    @Published var showToolBadge: Bool {
        didSet { defaults.set(showToolBadge, forKey: "showToolBadge") }
    }

    @Published var showConversationCard: Bool {
        didSet { defaults.set(showConversationCard, forKey: "showConversationCard") }
    }

    // MARK: - Behavior

    @Published var autoExpandOnPermission: Bool {
        didSet { defaults.set(autoExpandOnPermission, forKey: "autoExpandOnPermission") }
    }

    @Published var autoExpandOnCompletion: Bool {
        didSet { defaults.set(autoExpandOnCompletion, forKey: "autoExpandOnCompletion") }
    }

    @Published var suppressWhenTerminalFocused: Bool {
        didSet { defaults.set(suppressWhenTerminalFocused, forKey: "suppressWhenTerminalFocused") }
    }

    @Published var autoCollapseDelay: Double {
        didSet { defaults.set(autoCollapseDelay, forKey: "autoCollapseDelay") }
    }

    // MARK: - Copilot / Auto-Approve

    /// Global copilot: auto-approve ALL tools for ALL sessions.
    @Published var copilotEnabled: Bool {
        didSet { defaults.set(copilotEnabled, forKey: "copilotEnabled") }
    }

    /// Per-tool auto-approve (when copilot is off). Stored as comma-separated.
    @Published var autoApproveTools: Set<String> {
        didSet { defaults.set(Array(autoApproveTools), forKey: "autoApproveTools") }
    }

    /// What decision to send: "allow" (once) or "always_allow" (remembered).
    @Published var autoApproveDecision: String {
        didSet { defaults.set(autoApproveDecision, forKey: "autoApproveDecision") }
    }

    // MARK: - Init

    private init() {
        // Register defaults so first launch has sane values.
        defaults.register(defaults: [
            "soundEnabled": true,
            "soundOnPermission": true,
            "soundOnCompletion": true,
            "soundOnStart": true,
            "showSubagents": true,
            "showTasks": true,
            "showToolBadge": true,
            "showConversationCard": true,
            "autoExpandOnPermission": true,
            "autoExpandOnCompletion": true,
            "suppressWhenTerminalFocused": true,
            "autoCollapseDelay": 10.0,
            "copilotEnabled": false,
            "autoApproveTools": [String](),
            "autoApproveDecision": "allow",
        ])

        soundEnabled = defaults.bool(forKey: "soundEnabled")
        soundOnPermission = defaults.bool(forKey: "soundOnPermission")
        soundOnCompletion = defaults.bool(forKey: "soundOnCompletion")
        soundOnStart = defaults.bool(forKey: "soundOnStart")
        showSubagents = defaults.bool(forKey: "showSubagents")
        showTasks = defaults.bool(forKey: "showTasks")
        showToolBadge = defaults.bool(forKey: "showToolBadge")
        showConversationCard = defaults.bool(forKey: "showConversationCard")
        autoExpandOnPermission = defaults.bool(forKey: "autoExpandOnPermission")
        autoExpandOnCompletion = defaults.bool(forKey: "autoExpandOnCompletion")
        suppressWhenTerminalFocused = defaults.bool(forKey: "suppressWhenTerminalFocused")
        autoCollapseDelay = defaults.double(forKey: "autoCollapseDelay")
        copilotEnabled = defaults.bool(forKey: "copilotEnabled")
        autoApproveTools = Set(defaults.stringArray(forKey: "autoApproveTools") ?? [])
        autoApproveDecision = defaults.string(forKey: "autoApproveDecision") ?? "allow"

        syncSound()
    }

    private func syncSound() {
        if soundEnabled && SoundManager.shared.isMuted { SoundManager.shared.toggle() }
        if !soundEnabled && !SoundManager.shared.isMuted { SoundManager.shared.toggle() }
    }
}
