import SwiftUI

/// Two-state notch widget: a slim collapsed pill glued to the notch that
/// expands into a full session dashboard on hover, inspired by Dynamic
/// Island and NotchNook.
struct NotchView: View {
    @ObservedObject var watcher: ClaudeWatcher
    @State private var tick = 0
    @State private var isExpanded = false
    @State private var hoveredSessionID: ClaudeSession.ID?
    @State private var showUsageLimits = false

    // Re-render clock so relative times update every second.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Top inset so visible content starts below the physical notch cutout.
    private var notchInset: CGFloat { NotchPanel.currentNotchHeight }

    // MARK: - Dimensions

    private let collapsedWidth: CGFloat = 300
    private let collapsedContentHeight: CGFloat = 30
    private let expandedWidth: CGFloat = 560
    private let expandedContentHeight: CGFloat = 200

    private var currentWidth: CGFloat { isExpanded ? expandedWidth : collapsedWidth }
    private var currentHeight: CGFloat {
        (isExpanded ? expandedContentHeight : collapsedContentHeight) + notchInset
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Shape + content sized to the current state.
            ZStack(alignment: .top) {
                background
                content
                    .padding(.top, notchInset + (isExpanded ? 14 : 8))
                    .padding(.horizontal, isExpanded ? 18 : 16)
                    .padding(.bottom, isExpanded ? 14 : 8)
            }
            .frame(width: currentWidth, height: currentHeight)
            .contentShape(shape)
            .onHover { hovering in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                    isExpanded = hovering
                }
            }
        }
        .frame(
            width: NotchPanel.panelWidth,
            height: NotchPanel.visibleContentHeight + notchInset,
            alignment: .top
        )
        .onReceive(clock) { _ in tick &+= 1 }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            expandedContent
        } else {
            collapsedContent
        }
    }

    private var collapsedContent: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(watcher.sessions.prefix(4)) { session in
                    PixelAvatar(
                        seed: session.id.lastPathComponent.hashValue,
                        color: session.isWorking ? .blue : .green
                    )
                }
            }
            Spacer(minLength: 4)
            if watcher.sessions.isEmpty {
                Text("◆ CLAUDE NOTCH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.55))
            } else {
                Text("\(watcher.sessions.count)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
        }
        .transition(.opacity)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if watcher.sessions.isEmpty {
                Text("> no active sessions")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(watcher.sessions.prefix(3)) { session in
                        sessionRow(session)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showUsageLimits.toggle()
                }
            } label: {
                if showUsageLimits {
                    usageLimitView
                } else {
                    Text("Tap to view usage limits")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text("[\(watcher.sessions.count) ACTIVE]")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.cyan.opacity(0.7))
        }
    }

    // Placeholder usage-limit display. Real 5h / 7d figures require
    // Anthropic API response headers that Claude Code does not persist
    // locally; wire this up once we find a data source.
    private var usageLimitView: some View {
        HStack(spacing: 6) {
            Text("◆")
                .foregroundColor(.orange)
            Text("5h")
                .foregroundColor(.white.opacity(0.7))
            Text("—%")
                .foregroundColor(.green)
            Text("—")
                .foregroundColor(.white.opacity(0.45))
            Text("|")
                .foregroundColor(.white.opacity(0.25))
            Text("7d")
                .foregroundColor(.white.opacity(0.7))
            Text("—%")
                .foregroundColor(.green)
            Text("—")
                .foregroundColor(.white.opacity(0.45))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }

    // MARK: - Session row

    private func sessionRow(_ session: ClaudeSession) -> some View {
        let isHovered = hoveredSessionID == session.id
        return Button {
            SessionLauncher.open(session)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                PixelAvatar(
                    seed: session.id.lastPathComponent.hashValue,
                    color: session.isWorking ? .blue : .green
                )
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(sessionTitle(session))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        badge("Claude")
                        if let tokenText = formatTokens(session.usage?.contextTokens) {
                            badge(tokenText, tint: .cyan)
                        }
                        Text(relativeTime(session.lastModified))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    if let snippet = session.lastSnippet, !snippet.isEmpty {
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                            Text(snippet)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    if session.isWorking {
                        Text("Working...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.blue.opacity(0.85))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSessionID = hovering ? session.id : nil
        }
    }

    /// Compose "ProjectName · session-slug" using the jsonl's slug field when
    /// available, otherwise fall back to just the project name.
    private func sessionTitle(_ session: ClaudeSession) -> String {
        // Drop the "~/" prefix from the decoded project name for compactness.
        let name = session.projectName.hasPrefix("~/")
            ? String(session.projectName.dropFirst(2))
            : session.projectName
        // Keep just the trailing path component as the project label.
        let label = name.split(separator: "/").last.map(String.init) ?? name
        return label
    }

    private func badge(_ text: String, tint: Color = .white) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(tint.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.white.opacity(0.08))
            )
    }

    // MARK: - Background shape

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: isExpanded ? 26 : 18,
            bottomTrailingRadius: isExpanded ? 26 : 18,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var background: some View {
        shape
            .fill(Color.black)
            .overlay(
                shape.stroke(Color.cyan.opacity(isExpanded ? 0.35 : 0.2), lineWidth: 1)
            )
            .shadow(color: .cyan.opacity(isExpanded ? 0.18 : 0.1), radius: isExpanded ? 24 : 12, y: 6)
    }

    // MARK: - Formatting helpers

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    /// Format a token count compactly: "500", "1.2k", "52k", "158k".
    private func formatTokens(_ n: Int?) -> String? {
        guard let n, n > 0 else { return nil }
        if n < 1_000 { return "\(n)" }
        if n < 10_000 {
            return String(format: "%.1fk", Double(n) / 1_000.0)
        }
        return "\(n / 1_000)k"
    }
}

// MARK: - PixelAvatar

/// A tiny 5x5 symmetric pixel-art sprite. The pattern is deterministic per
/// `seed`, so every session gets a stable but unique avatar. Inspired by
/// classic space-invader glyphs.
struct PixelAvatar: View {
    let seed: Int
    let color: Color

    private let gridSize = 5
    private let pixelSize: CGFloat = 3
    private let pixelSpacing: CGFloat = 1

    var body: some View {
        let bits = Self.generatePattern(seed: seed, size: gridSize)
        return VStack(spacing: pixelSpacing) {
            ForEach(0..<gridSize, id: \.self) { row in
                HStack(spacing: pixelSpacing) {
                    ForEach(0..<gridSize, id: \.self) { col in
                        Rectangle()
                            .fill(bits[row][col] ? color : Color.clear)
                            .frame(width: pixelSize, height: pixelSize)
                    }
                }
            }
        }
        .shadow(color: color.opacity(0.5), radius: 2)
    }

    /// Build a horizontally symmetric bit pattern seeded by `seed`.
    /// Only half the grid is randomized; the other half mirrors it.
    private static func generatePattern(seed: Int, size: Int) -> [[Bool]] {
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
        var grid = Array(repeating: Array(repeating: false, count: size), count: size)
        let halfCols = size / 2 + size % 2
        for row in 0..<size {
            for col in 0..<halfCols {
                let bit = rng.nextBool(probability: 0.55)
                grid[row][col] = bit
                grid[row][size - 1 - col] = bit
            }
        }
        return grid
    }
}

/// Tiny deterministic PRNG for reproducible avatar patterns.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextBool(probability p: Double) -> Bool {
        let n = next()
        return Double(n) / Double(UInt64.max) < p
    }
}
