import SwiftUI

/// Two-state notch widget: a slim collapsed pill glued to the notch that
/// expands into a full session dashboard on hover, inspired by Dynamic
/// Island and NotchNook.
struct NotchView: View {
    @ObservedObject var watcher: ClaudeWatcher
    @ObservedObject var usage: UsageFetcher
    @State private var tick = 0
    @State private var isExpanded = false
    @State private var hoveredSessionID: ClaudeSession.ID?
    @State private var showUsageLimits = false
    @State private var showAllSessions = false

    /// Rows visible before the user taps "Show all N sessions".
    private let defaultRowLimit = 3

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
                // Opportunistically refresh the usage limits when the panel
                // opens, so the numbers match Anthropic's live state while
                // the user is actively looking at them.
                if hovering {
                    usage.refreshIfStale(maxAge: 20)
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
                    PixelAvatar(status: session.status)
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
        VStack(alignment: .leading, spacing: 8) {
            header
            if watcher.sessions.isEmpty {
                Text("> no active sessions")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)
            } else {
                let visible = showAllSessions
                    ? Array(watcher.sessions)
                    : Array(watcher.sessions.prefix(defaultRowLimit))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visible) { session in
                        sessionRow(session)
                    }
                }
                if watcher.sessions.count > defaultRowLimit {
                    showAllButton
                }
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    private var showAllButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showAllSessions.toggle()
            }
        } label: {
            Text(showAllSessions
                 ? "Show fewer"
                 : "Show all \(watcher.sessions.count) sessions")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
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

            Spacer(minLength: 8)

            // Volume / sound indicator (placeholder — reserved for future mute
            // of "Working..." beeps or notifications).
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))

            // Settings cog — opens the menu bar item's menu in future iterations.
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    // Usage limit chip: `✦ 5h 64% 2h12m | 7d 25% 4d`
    // Data comes from GET https://api.anthropic.com/api/oauth/usage using
    // the OAuth token Claude Code stores in the login keychain. Falls back
    // to a muted "—%" / "—" when the fetcher hasn't produced a value yet
    // (expired token, offline, first tick, etc).
    private var usageLimitView: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.orange)

            limitSegment(
                label: "5h",
                limit: usage.utilization?.five_hour
            )

            Text("|")
                .foregroundColor(.white.opacity(0.2))
                .padding(.horizontal, 2)

            limitSegment(
                label: "7d",
                limit: usage.utilization?.seven_day
            )
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
    }

    /// One "5h 64% 2h12m" block inside the usage header.
    @ViewBuilder
    private func limitSegment(label: String, limit: Utilization.Limit?) -> some View {
        Text(label)
            .foregroundColor(.white)

        if let limit {
            Text(Self.formatPercent(limit.utilization))
                .foregroundColor(Self.colorForUtilization(limit.utilization))
            Text(Self.formatResetCountdown(limit.resets_at))
                .foregroundColor(.white.opacity(0.45))
        } else {
            Text("—%")
                .foregroundColor(.white.opacity(0.35))
            Text("—")
                .foregroundColor(.white.opacity(0.25))
        }
    }

    // MARK: - Formatting

    private static func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Green under 50%, amber under 80%, red past 80%.
    private static func colorForUtilization(_ value: Double) -> Color {
        switch value {
        case ..<50:  return .green
        case ..<80:  return .orange
        default:     return .red
        }
    }

    /// Compact countdown to the reset timestamp:
    /// < 1m → "now", < 1h → "32m", < 24h → "2h12m", else "5d".
    private static func formatResetCountdown(_ isoString: String?) -> String {
        guard let isoString,
              let resetDate = Self.parseISO8601(isoString)
        else { return "—" }

        let remaining = resetDate.timeIntervalSinceNow
        if remaining <= 60 { return "now" }

        let mins = Int(remaining / 60)
        if mins < 60 { return "\(mins)m" }

        let hours = mins / 60
        let minsInHour = mins % 60
        if hours < 24 {
            return minsInHour == 0 ? "\(hours)h" : "\(hours)h\(minsInHour)m"
        }

        let days = hours / 24
        return "\(days)d"
    }

    /// The Anthropic API returns timestamps with fractional seconds like
    /// "2026-04-05T16:00:01.170352+00:00". The default ISO8601DateFormatter
    /// needs `.withFractionalSeconds` to parse that reliably.
    private static func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    // MARK: - Session row

    private func sessionRow(_ session: ClaudeSession) -> some View {
        let isHovered = hoveredSessionID == session.id
        return Button {
            SessionLauncher.open(session)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                PixelAvatar(status: session.status)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sessionTitle(session))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let branch = session.gitBranch, !branch.isEmpty {
                            branchBadge(branch)
                        }

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

                    if let tool = session.currentTool {
                        toolBadge(tool)
                    }

                    statusLabel(for: session)
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

    /// Inline tool badge like "Bash git show 3864d21 …" shown while Claude
    /// is running (or just ran) a tool. Colour-codes the tool name so Bash
    /// and risky tools stand out from plain Read/Grep.
    private func toolBadge(_ tool: CurrentTool) -> some View {
        HStack(spacing: 4) {
            Text(tool.name)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Self.tintForTool(tool.name))
            if let detail = tool.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private static func tintForTool(_ name: String) -> Color {
        switch name {
        case "Bash":                       return .orange
        case "Edit", "Write", "NotebookEdit": return .cyan
        case "Read":                       return .green.opacity(0.85)
        case "Grep", "Glob":               return .purple
        case "Task", "Agent":              return .pink
        case "WebFetch", "WebSearch":      return .blue
        default:                           return .white.opacity(0.8)
        }
    }

    /// Branch indicator — mimics the "^G main ↗" style from the reference UI.
    private func branchBadge(_ branch: String) -> some View {
        HStack(spacing: 2) {
            Text("^G")
                .foregroundColor(.white.opacity(0.4))
            Text(branch)
                .foregroundColor(.white.opacity(0.75))
            Text("↗")
                .foregroundColor(.white.opacity(0.4))
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
    }

    /// Status line under a row — per-state label with a tinted indicator.
    @ViewBuilder
    private func statusLabel(for session: ClaudeSession) -> some View {
        switch session.status {
        case .working:
            HStack(spacing: 4) {
                WorkingDot(color: .blue)
                Text("Working...")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.blue.opacity(0.9))
            }
        case .awaitingApproval:
            HStack(spacing: 4) {
                WorkingDot(color: .orange)
                Text("Awaiting approval")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange.opacity(0.95))
            }
        case .idle:
            Text("Done")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.green.opacity(0.6))
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

// MARK: - WorkingDot

/// A small pulsing dot used next to busy-state status labels.
struct WorkingDot: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(pulse ? 1.0 : 0.35)
            .shadow(color: color.opacity(0.7), radius: pulse ? 3 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - PixelAvatar

/// The one canonical ClaudeNotch mascot: a 5x5 space-invader silhouette.
/// Static when idle, animated with a classic two-frame "walk" when the
/// session is busy. Color shifts with the session status:
///   - working         → blue
///   - awaitingApproval → orange
///   - idle            → green, no animation
struct PixelAvatar: View {
    let status: SessionStatus

    private var color: Color {
        switch status {
        case .working:          return .blue
        case .awaitingApproval: return .orange
        case .idle:             return .green
        }
    }

    private var isAnimating: Bool { status.isBusy }

    private let pixelSize: CGFloat = 3
    private let pixelSpacing: CGFloat = 1

    // Classic invader body — identical in both frames.
    // Only the bottom row (the "legs") alternates to create the walk.
    private static let body: [[Bool]] = [
        [false, true,  true,  true,  false],
        [true,  true,  true,  true,  true ],
        [true,  false, true,  false, true ],
        [true,  true,  true,  true,  true ],
    ]
    private static let legsFrameA: [Bool] = [true,  false, false, false, true ]
    private static let legsFrameB: [Bool] = [false, true,  false, true,  false]

    var body: some View {
        Group {
            if isAnimating {
                // Animate only while busy: TimelineView ticks twice a second
                // and we flip between the two leg frames.
                TimelineView(.periodic(from: .now, by: 0.45)) { context in
                    let phase = Int(context.date.timeIntervalSince1970 / 0.45) % 2
                    grid(legs: phase == 0 ? Self.legsFrameA : Self.legsFrameB)
                }
            } else {
                // Idle: static, frame A (standing).
                grid(legs: Self.legsFrameA)
            }
        }
        .shadow(color: color.opacity(0.65), radius: isAnimating ? 3 : 2)
    }

    private func grid(legs: [Bool]) -> some View {
        let rows = Self.body + [legs]
        return VStack(spacing: pixelSpacing) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: pixelSpacing) {
                    ForEach(0..<rows[row].count, id: \.self) { col in
                        Rectangle()
                            .fill(rows[row][col] ? color : Color.clear)
                            .frame(width: pixelSize, height: pixelSize)
                    }
                }
            }
        }
    }
}
