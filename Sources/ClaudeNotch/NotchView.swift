import SwiftUI

/// Two-state notch widget: a slim collapsed pill glued to the notch that
/// expands into a full session dashboard on hover, inspired by Dynamic
/// Island and NotchNook.
struct NotchView: View {
    @ObservedObject var watcher: ClaudeWatcher
    @ObservedObject var usage: UsageFetcher
    @ObservedObject var focusMonitor: FocusMonitor
    @State private var tick = 0
    @State private var isExpanded = false
    @State private var hoveredSessionID: ClaudeSession.ID?
    @State private var showUsageLimits = true
    @State private var showAllSessions = false
    @State private var autoExpanded = false
    @State private var focusedSessionId: String?
    @State private var hiddenSessionIDs: Set<String> = []
    @State private var hoverCooldownUntil: Date = .distantPast
    @State private var showSettings = false
    @ObservedObject private var settings = AppSettings.shared

    /// Rows visible before the user taps "Show all N sessions".
    private let defaultRowLimit = 8

    // Re-render clock so relative times update every second.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Top inset so visible content starts below the physical notch cutout.
    private var notchInset: CGFloat { NotchPanel.currentNotchHeight }

    // MARK: - Dimensions

    private let collapsedWidth: CGFloat = 300
    private let collapsedContentHeight: CGFloat = 30
    private let expandedWidth: CGFloat = 560
    private let maxExpandedContentHeight: CGFloat = 400

    private var currentWidth: CGFloat { isExpanded ? expandedWidth : collapsedWidth }
    private var topCornerR: CGFloat { isExpanded ? 16 : 12 }
    private var bottomCornerR: CGFloat { isExpanded ? 26 : 20 }

    /// Expand: slightly slower, luxurious feel with subtle bounce.
    private let expandAnimation: Animation = .spring(response: 0.4, dampingFraction: 0.78)
    /// Collapse: snappy retract, no bounce.
    private let collapseAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.88)

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
            .frame(width: currentWidth)
            .frame(maxHeight: isExpanded ? maxExpandedContentHeight + notchInset : collapsedContentHeight + notchInset)
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(notchShape)
            .shadow(color: .black.opacity(0.3), radius: isExpanded ? 12 : 4, y: 3)
            .contentShape(notchShape)
            .onHover { hovering in
                if hovering && Date() < hoverCooldownUntil { return }
                let hasPermission = watcher.sessions.contains { $0.status == .awaitingApproval }
                if hovering {
                    withAnimation(expandAnimation) {
                        if !isExpanded { CNLog.ui("hover expand") }
                        isExpanded = true
                    }
                    if !hasPermission { autoExpanded = false }
                    usage.refreshIfStale(maxAge: 20)
                } else {
                    focusedSessionId = nil
                    if !autoExpanded && !hasPermission {
                        withAnimation(collapseAnimation) {
                            if isExpanded { CNLog.ui("hover collapse") }
                            isExpanded = false
                            hoverCooldownUntil = Date().addingTimeInterval(0.6)
                        }
                    }
                }
            }
            // Auto-expand focused on the specific session that triggered.
            // Uses a counter so onChange always fires even for repeat events.
            .onChange(of: watcher.autoExpandCounter) { _ in
                guard let sid = watcher.autoExpandFocusedSession else { return }
                withAnimation(expandAnimation) {
                    isExpanded = true
                    autoExpanded = true
                    focusedSessionId = sid
                    showAllSessions = false
                }
                let session = watcher.sessions.first { $0.sessionID == sid }
                let isPermission = session?.status == .awaitingApproval
                if !isPermission {
                    let counter = watcher.autoExpandCounter
                    let delay = AppSettings.shared.autoCollapseDelay
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if autoExpanded && watcher.autoExpandCounter == counter {
                            CNLog.ui("auto-expand timer collapse")
                            withAnimation(collapseAnimation) {
                                isExpanded = false
                                autoExpanded = false
                                focusedSessionId = nil
                            }
                        }
                    }
                }
            }
            // Collapse when user switches app — but only for manual hovers,
            // not for auto-expanded popups (those use their own timer).
            .onChange(of: focusMonitor.appSwitchCounter) { _ in
                let hasPermission = watcher.sessions.contains { $0.status == .awaitingApproval }
                if isExpanded && !autoExpanded && !hasPermission {
                    CNLog.ui("app-switch collapse")
                    withAnimation(collapseAnimation) {
                        isExpanded = false
                        focusedSessionId = nil
                    }
                }
            }
        }
        .frame(
            width: NotchPanel.panelWidth,
            height: NotchPanel.visibleContentHeight + notchInset,
            alignment: .top
        )
        .onReceive(clock) { _ in tick &+= 1 }
        .onChange(of: isExpanded) { expanded in
            if !expanded { showSettings = false }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isExpanded {
            expandedContent
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            collapsedContent
                .transition(.opacity)
        }
    }

    private var collapsedContent: some View {
        HStack(spacing: 8) {
            // Session avatars on the left
            HStack(spacing: 6) {
                ForEach(watcher.sessions.prefix(4)) { session in
                    PixelAvatar(status: session.status)
                }
            }
            Spacer(minLength: 4)
            // Usage pill: "✦ 5h 3%" or "⚠ Unavailable" or session count
            if usage.lastError != nil && usage.utilization == nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.6))
                Text("Unavailable")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            } else if usage.utilization != nil {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.orange)
                collapsedLimitSegment(label: "5h", limit: usage.utilization?.five_hour)
            } else if !watcher.sessions.isEmpty {
                Text("\(watcher.sessions.count)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
            } else {
                Text("◆ CLAUDE NOTCH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.55))
            }
        }
        .transition(.opacity)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showSettings {
                SettingsView { withAnimation(.easeInOut(duration: 0.2)) { showSettings = false } }
                    .transition(.opacity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        if watcher.sessions.isEmpty {
                            Text("> no active sessions")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .padding(.top, 4)
                        } else if let fid = focusedSessionId,
                                  let focused = watcher.sessions.first(where: { $0.sessionID == fid }) {
                            sessionRow(focused)
                            if watcher.sessions.count > 1 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        focusedSessionId = nil
                                        autoExpanded = false
                                    }
                                } label: {
                                    Text("Show all \(watcher.sessions.count) sessions")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.white.opacity(0.45))
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            let filtered = watcher.sessions.filter { !hiddenSessionIDs.contains($0.sessionID) }
                            let visible = showAllSessions
                                ? Array(filtered)
                                : Array(filtered.prefix(defaultRowLimit))
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(visible) { session in
                                    sessionRow(session)
                                }
                            }
                            if filtered.count > defaultRowLimit && !showAllSessions {
                                showAllButton
                            }
                        }
                    }
                }
                .transition(.opacity)
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

            // Copilot toggle — only visible when enabled in settings.
            if settings.copilotEnabled || !settings.autoApproveTools.isEmpty {
                Button {
                    settings.copilotEnabled.toggle()
                } label: {
                    Image(systemName: settings.copilotEnabled ? "bolt.shield.fill" : "bolt.shield")
                        .font(.system(size: 12))
                        .foregroundColor(settings.copilotEnabled ? .green : .white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }

            Button {
                settings.soundEnabled.toggle()
            } label: {
                Image(systemName: settings.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundColor(settings.soundEnabled ? .white.opacity(0.55) : .orange.opacity(0.7))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundColor(showSettings ? .cyan : .white.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
    }

    // Usage limit chip: `✦ 5h 64% 2h12m | 7d 25% 4d`
    // Data comes from GET https://api.anthropic.com/api/oauth/usage using
    // the OAuth token Claude Code stores in the login keychain. Falls back
    // to a muted "—%" / "—" when the fetcher hasn't produced a value yet
    // (expired token, offline, first tick, etc).
    private var usageLimitView: some View {
        HStack(spacing: 6) {
            if usage.lastError != nil && usage.utilization == nil {
                // No data at all — show unavailable
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.orange.opacity(0.7))
                Text("Unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            } else {
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

    /// Compact version for the collapsed pill: "5h 2% 1h28m"
    @ViewBuilder
    private func collapsedLimitSegment(label: String, limit: Utilization.Limit?) -> some View {
        let font = Font.system(size: 10, weight: .bold, design: .monospaced)
        Text(label).font(font).foregroundColor(.white)
        if let limit {
            Text(Self.formatPercent(limit.utilization)).font(font)
                .foregroundColor(Self.colorForUtilization(limit.utilization))
            Text(Self.formatResetCountdown(limit.resets_at)).font(Font.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        } else {
            Text("—%").font(font).foregroundColor(.white.opacity(0.35))
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
        let bgColor: Color = isHovered ? Color.white.opacity(0.06) : Color.clear
        let isActive = session.isRecentlyActive || hookAliveSessions(session)

        return Group {
            if isActive {
                // Full row for active sessions
                HStack(alignment: .top, spacing: 10) {
                    PixelAvatar(status: session.status)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        sessionRowHeader(session)
                        sessionRowBody(session)
                        statusLabel(for: session)
                    }
                }
            } else {
                // Compact single-line for inactive sessions
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 5, height: 5)
                    Text(sessionTitle(session))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    badge("Claude")
                    badge("Terminal")
                    Text(relativeTime(session.lastModified))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isActive ? 6 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(bgColor))
        .contentShape(Rectangle())
        .onTapGesture {
            if session.status == .awaitingApproval { return }
            SessionLauncher.open(session)
            withAnimation(collapseAnimation) {
                isExpanded = false
                autoExpanded = false
                focusedSessionId = nil
            }
        }
        .onHover { hovering in hoveredSessionID = hovering ? session.id : nil }
    }

    /// Check if session is tracked as alive via hooks.
    private func hookAliveSessions(_ session: ClaudeSession) -> Bool {
        watcher.isSessionHookAlive(session.sessionID)
    }

    /// Top line of a session row: title + badges + terminal button + archive.
    private func sessionRowHeader(_ session: ClaudeSession) -> some View {
        HStack(spacing: 5) {
            Text(sessionTitle(session))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            badge("Claude")
            Button {
                SessionLauncher.open(session)
                withAnimation(collapseAnimation) {
                    isExpanded = false
                    autoExpanded = false
                    focusedSessionId = nil
                }
            } label: { badge("Terminal") }
                .buttonStyle(.plain)
            if let tokenText = formatTokens(session.usage?.contextTokens) {
                badge(tokenText, tint: .cyan)
            }
            Text(relativeTime(session.lastModified))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { _ = hiddenSessionIDs.insert(session.sessionID) }
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
    }

    /// Body of a session row: snippet, tasks, subagents, tool badge.
    @ViewBuilder
    private func sessionRowBody(_ session: ClaudeSession) -> some View {
        if let userMsg = session.lastUserMessage, !userMsg.isEmpty {
            HStack(spacing: 4) {
                Text("You:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Text(userMsg)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }

        if settings.showToolBadge, session.status != .awaitingApproval, let tool = session.currentTool {
            toolBadge(tool)
        }

        if settings.showTasks {
            let activeTodos = session.todos.filter { $0.status != .completed }
            if !activeTodos.isEmpty {
                tasksList(session.todos)
            }
        }

        if settings.showSubagents {
            let visibleSubs = Self.filterSubagents(session.subagents)
            if !visibleSubs.isEmpty {
                subagentTree(visibleSubs)
            }
        }
    }

    /// Tasks section matching Vibe Island: "Tasks (N done, N in progress, N open)"
    /// Shows first 2 items + "... +N completed" truncation.
    private func tasksList(_ todos: [TodoItem]) -> some View {
        let done = todos.filter { $0.status == .completed }.count
        let inProgress = todos.filter { $0.status == .inProgress }.count
        let pending = todos.filter { $0.status == .pending }.count

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("Tasks")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                Text("  (\(done) done, \(inProgress) in progress, \(pending) open)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            let active = todos.filter { $0.status != .completed }
            let completed = todos.filter { $0.status == .completed }
            let visibleCompleted = Array(completed.prefix(2))
            let hiddenCount = completed.count - visibleCompleted.count

            ForEach(active) { todo in
                taskRow(todo)
            }
            ForEach(visibleCompleted) { todo in
                taskRow(todo)
            }
            if hiddenCount > 0 {
                Text("... +\(hiddenCount) completed")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private func taskRow(_ todo: TodoItem) -> some View {
        HStack(spacing: 6) {
            // In-progress: blue dot, Completed: green checkbox, Pending: empty checkbox
            switch todo.status {
            case .inProgress:
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
            case .completed:
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.blue.opacity(0.6))
            case .pending:
                Image(systemName: "square")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
            }
            Text(todo.content)
                .font(.system(size: 11))
                .foregroundColor(todo.status == .completed ? .white.opacity(0.35) : .white.opacity(0.7))
                .strikethrough(todo.status == .completed, color: .white.opacity(0.2))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Filter subagents: show running ones + last completed.
    private static func filterSubagents(_ subs: [Subagent]) -> [Subagent] {
        let running = subs.filter { $0.status == .running }
        let lastDone = subs.last(where: { $0.status == .done })
        var result = running
        if let done = lastDone, !running.contains(where: { $0.id == done.id }) {
            result.append(done)
        }
        return result
    }

    /// Collapsible subagent tree: "⎇ Subagents (N)" header followed by
    /// each subagent as a row with status dot, type, description, and
    /// running duration.
    private func subagentTree(_ subagents: [Subagent]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 4) {
                Text("⎇")
                    .foregroundColor(.white.opacity(0.5))
                Text("Subagents (\(subagents.count))")
                    .foregroundColor(.white.opacity(0.6))
            }
            .font(.system(size: 10, weight: .medium))

            // Each subagent
            ForEach(subagents) { sub in
                HStack(spacing: 6) {
                    Circle()
                        .fill(sub.status == .running ? Color.blue : Color.green)
                        .frame(width: 5, height: 5)
                    Text(sub.agentType)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    if let desc = sub.description {
                        Text("(\(desc))")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Text(formatDuration(sub.duration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                    if sub.status == .done {
                        Text("Done")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.green.opacity(0.7))
                    }
                }
                // Show current tool of subagent if available
                if let tool = sub.currentTool {
                    HStack(spacing: 4) {
                        Text("└")
                            .foregroundColor(.white.opacity(0.25))
                        Text("$")
                            .foregroundColor(.white.opacity(0.35))
                        Text(tool.detail ?? tool.name)
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .padding(.leading, 11)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(s % 60)s" }
        return "\(s / 3600)h\(s / 60 % 60)m"
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
    /// When awaiting approval, render Allow / Deny buttons inline.
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
        case .compacting:
            HStack(spacing: 4) {
                WorkingDot(color: .purple)
                Text("Compacting context...")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.purple.opacity(0.9))
            }
        case .awaitingApproval:
            permissionCard(for: session)
        case .interrupted:
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                Text("Interrupted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange.opacity(0.9))
            }
        case .idle:
            if settings.showConversationCard {
                conversationCard(for: session)
            }
        }
    }

    /// Dark card showing the last conversation turn: user message on top
    /// with "Done" label, assistant response below. Matches Vibe Island's
    /// auto-expand-on-completion card.
    private func conversationCard(for session: ClaudeSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: "You: message" + "Done" tag
            HStack(alignment: .top) {
                if let userMsg = session.lastUserMessage, !userMsg.isEmpty {
                    Text("You:  " + userMsg)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Done")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.green.opacity(0.15))
                    )
            }

            // Scrollable markdown content with max height
            if let full = session.assistantFull, !full.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(Self.markdownText(full))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 80)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    /// Parse markdown string into AttributedString for rich rendering.
    private static func markdownText(_ raw: String) -> AttributedString {
        var result: AttributedString
        if let md = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            result = md
        } else {
            result = AttributedString(raw)
        }
        // Force system font so markdown doesn't render everything as monospace.
        let baseFont = NSFont.systemFont(ofSize: 11)
        for run in result.runs {
            let range = run.range
            result[range].font = baseFont
        }
        return result
    }

    /// Full permission card matching Vibe Island's layout:
    /// ⚠ Tool label → diff preview (Edit/Write) or command box → 4 buttons
    private func permissionCard(for session: ClaudeSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tool = session.currentTool {
                // ⚠ Tool label
                HStack(spacing: 4) {
                    Text("⚠")
                        .foregroundColor(.orange)
                    Text(tool.name)
                        .foregroundColor(.orange)
                        .fontWeight(.bold)
                    if let diff = tool.diffPreview {
                        Spacer()
                        Text((diff.filePath as NSString).lastPathComponent)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .font(.system(size: 11, design: .monospaced))

                // Diff preview for Edit/Write, or command box for others
                if let diff = tool.diffPreview {
                    diffPreviewView(diff)
                } else {
                    // Code box — tall enough to show multi-line commands
                    VStack(alignment: .leading, spacing: 6) {
                        if let detail = tool.detail, !detail.isEmpty {
                            ScrollView(.vertical, showsIndicators: false) {
                                Text("$ " + detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                        }
                        if let desc = tool.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(white: 0.08))
                    )
                }
            }

            // Permission buttons: dynamic based on permission_suggestions
            HStack(spacing: 5) {
                permButton("Deny",
                           bg: Color.white.opacity(0.1),
                           fg: .white.opacity(0.7),
                           decision: "deny",
                           sessionId: session.sessionID)
                permButton("Allow Once",
                           bg: Color.white.opacity(0.1),
                           fg: .white.opacity(0.85),
                           decision: "allow",
                           sessionId: session.sessionID)
                if session.currentTool?.hasAlwaysAllow == true {
                    permButton("Always Allow",
                               bg: Color.green.opacity(0.4),
                               fg: .white,
                               decision: "always_allow",
                               sessionId: session.sessionID)
                }
                permButton("Bypass",
                           bg: Color.red.opacity(0.5),
                           fg: .white,
                           decision: "bypass",
                           sessionId: session.sessionID)
            }
        }
    }

    // MARK: - Diff preview

    /// Code diff view for Edit/Write tools — shows removed lines in red
    /// and added lines in green, similar to Vibe Island's permission card.
    private func diffPreviewView(_ diff: DiffPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let old = diff.oldString {
                let lines = old.components(separatedBy: "\n")
                ForEach(0..<min(lines.count, 8), id: \.self) { i in
                    diffLine(text: lines[i], isAddition: false)
                }
            }
            if let new = diff.newString {
                let lines = new.components(separatedBy: "\n")
                ForEach(0..<min(lines.count, 8), id: \.self) { i in
                    diffLine(text: lines[i], isAddition: true)
                }
            }
            if let content = diff.content {
                let lines = content.components(separatedBy: "\n")
                ForEach(0..<min(lines.count, 10), id: \.self) { i in
                    writeContentLine(text: lines[i], lineNumber: i + 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Single diff line: red background for removals, green for additions.
    private func diffLine(text: String, isAddition: Bool) -> some View {
        HStack(spacing: 0) {
            Text(isAddition ? "+" : "-")
                .frame(width: 16, alignment: .center)
                .foregroundColor(isAddition ? .green : .red)
            Text(" ")
            Text(text)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isAddition
            ? Color.green.opacity(0.1)
            : Color.red.opacity(0.1))
    }

    /// Single line for Write tool content preview with line number.
    private func writeContentLine(text: String, lineNumber: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(lineNumber)")
                .frame(width: 24, alignment: .trailing)
                .foregroundColor(.white.opacity(0.25))
            Text("  ")
            Text(text)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.06))
    }

    private func permButton(
        _ label: String,
        bg: Color,
        fg: Color,
        decision: String,
        sessionId: String
    ) -> some View {
        Button {
            guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
            appDelegate.resolvePermission(sessionId: sessionId, decision: decision)
            withAnimation(collapseAnimation) {
                isExpanded = false
                autoExpanded = false
                focusedSessionId = nil
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(fg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(bg)
                )
        }
        .buttonStyle(.plain)
    }

    /// Compose "ProjectName · branch" using cwd for accurate project name
    /// (avoids the dash-encoding problem in directory names like
    /// "NumeroAssistant-AI" which would otherwise split into subfolders).
    private func sessionTitle(_ session: ClaudeSession) -> String {
        let label: String
        if let cwd = session.cwd {
            label = (cwd as NSString).lastPathComponent
        } else {
            let name = session.projectName.hasPrefix("~/")
                ? String(session.projectName.dropFirst(2))
                : session.projectName
            label = name.split(separator: "/").last.map(String.init) ?? name
        }

        if let branch = session.gitBranch, !branch.isEmpty {
            return "\(label) · \(branch)"
        }
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

    // MARK: - Background shape (unified NotchShape)

    private var notchShape: NotchShape {
        NotchShape(topCornerRadius: topCornerR, bottomCornerRadius: bottomCornerR)
    }

    private var background: some View {
        notchShape
            .fill(Color.black)
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
        case .compacting:       return .purple
        case .awaitingApproval: return .orange
        case .interrupted:      return .orange
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

// MARK: - InverseCorner

/// Unified notch panel shape using quadratic Bezier curves.
/// Concave (inverse) corners at top connect to the notch cutout;
/// convex corners at bottom round off the panel body. Both radii
/// are animatable so SwiftUI interpolates the morph each frame.
///
/// Layout:
/// ```
/// (minX,minY)━━━━━━━━━━━━━━━━━━(maxX,minY)   ← top edge (behind notch)
///    ╲                                ╱        ← concave quad curves (topR)
///     │                              │
///     │          panel body          │
///     │                              │
///      ╲__________________________╱            ← convex quad curves (botR)
/// ```
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let topR = min(topCornerRadius, rect.width / 4)
        let botR = min(bottomCornerRadius, rect.width / 4)
        var p = Path()

        // Top-left: concave curve from top edge inward
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY))

        // Left edge down
        p.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - botR))

        // Bottom-left: convex corner
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + botR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY))

        // Bottom edge
        p.addLine(to: CGPoint(x: rect.maxX - topR - botR, y: rect.maxY))

        // Bottom-right: convex corner
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - botR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY))

        // Right edge up
        p.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))

        // Top-right: concave curve back to top edge
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topR, y: rect.minY))

        p.closeSubpath()
        return p
    }
}
