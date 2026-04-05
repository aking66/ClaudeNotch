import SwiftUI

/// Retro pixel-style panel UI inspired by Vibe Island.
struct NotchView: View {
    @ObservedObject var watcher: ClaudeWatcher
    @State private var tick = 0

    // Re-render clock so relative times update every second.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            divider
            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: NotchPanel.panelWidth, height: NotchPanel.panelHeight, alignment: .topLeading)
        .background(background)
        .onReceive(clock) { _ in tick &+= 1 }
    }

    private var header: some View {
        HStack {
            Text("◆ CLAUDE NOTCH")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .shadow(color: .cyan.opacity(0.6), radius: 2)
            Spacer()
            Text("[\(watcher.sessions.count) ACTIVE]")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.cyan.opacity(0.7))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.cyan.opacity(0.25))
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        if watcher.sessions.isEmpty {
            Text("> no active sessions")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .padding(.top, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(watcher.sessions.prefix(4)) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: ClaudeSession) -> some View {
        HStack(spacing: 6) {
            Text("▸")
                .foregroundColor(.green)
            Text(session.projectName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            Text(relativeTime(session.lastModified))
                .foregroundColor(.white.opacity(0.45))
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .cyan.opacity(0.15), radius: 20)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
