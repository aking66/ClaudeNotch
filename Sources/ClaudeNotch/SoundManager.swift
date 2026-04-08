import AVFoundation
import AppKit

/// Plays event-driven sounds from the bundled Clean Chimes sound pack.
/// Maps Claude Code hook events to 7 sound categories matching Vibe Island.
@MainActor
final class SoundManager {
    static let shared = SoundManager()

    private var player: AVAudioPlayer?
    private var enabled = true

    /// Spam detection: track rapid prompts.
    private var recentPrompts: [Date] = []
    private let spamThreshold = 3     // prompts
    private let spamWindow: TimeInterval = 10  // seconds

    // MARK: - Sound categories → file mapping

    private enum Sound: String {
        case sessionStart   = "CC_Start"
        case taskAcknowledge = "CC_Acknowledge"
        case taskComplete   = "CC_Complete"
        case taskError      = "CC_Error"
        case inputRequired  = "CC_InputNeeded"
        case resourceLimit  = "CC_Warning"
        case userSpam       = "CC_Spam"
    }

    // MARK: - Public API

    func toggle() { enabled.toggle() }
    var isMuted: Bool { !enabled }

    /// Called from applyHookEvent — maps hook events to sounds.
    func playForEvent(_ hookEventName: String, toolName: String? = nil) {
        guard enabled else { return }

        switch hookEventName {
        case "SessionStart":
            play(.sessionStart)

        case "UserPromptSubmit":
            // Spam detection: 3+ prompts in 10 seconds
            let now = Date()
            recentPrompts.append(now)
            recentPrompts = recentPrompts.filter { now.timeIntervalSince($0) < spamWindow }
            if recentPrompts.count >= spamThreshold {
                play(.userSpam)
                recentPrompts.removeAll()
            } else {
                play(.taskAcknowledge)
            }

        case "Stop":
            play(.taskComplete)

        case "PermissionRequest":
            play(.inputRequired)

        case "PreCompact":
            play(.resourceLimit)

        default:
            break
        }
    }

    /// Play error sound for failed tools (called from PostToolUse with error).
    func playError() {
        guard enabled else { return }
        play(.taskError)
    }

    // MARK: - Playback

    private func play(_ sound: Sound) {
        // Look for the sound file in the app bundle Resources/Sounds/sounds/
        guard let url = soundURL(sound) else {
            NSLog("ClaudeNotch: sound file not found: \(sound.rawValue)")
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.volume = 0.6
            player?.play()
        } catch {
            NSLog("ClaudeNotch: failed to play \(sound.rawValue): \(error)")
        }
    }

    private func soundURL(_ sound: Sound) -> URL? {
        // Check app bundle first
        if let bundled = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav", subdirectory: "Sounds/sounds") {
            return bundled
        }
        // Dev fallback: check the repo Resources directory
        let devPath = "/Users/ahmed/ClaudeNotch/Resources/Sounds/sounds/\(sound.rawValue).wav"
        if FileManager.default.fileExists(atPath: devPath) {
            return URL(fileURLWithPath: devPath)
        }
        return nil
    }
}
