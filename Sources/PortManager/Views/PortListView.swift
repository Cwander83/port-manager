import Core
import SwiftUI

struct PortListView: View {
    @ObservedObject var store: PortStore

    var body: some View {
        VStack(spacing: 0) {
            header
            summary
            Divider()
            list
            Divider()
            footer
            actions
        }
        .frame(width: 340)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text("Port Manager")
                .font(.system(size: 13.5, weight: .bold))
            Spacer()
            Text(refreshedText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var refreshedText: String {
        guard let date = store.lastScanAt else { return "⟳ —" }
        let seconds = Int(Date().timeIntervalSince(date))
        return "⟳ \(seconds)s ago"
    }

    private var summary: some View {
        HStack {
            Text("\(store.listeners.count) listeners")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(totalRAM)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var totalRAM: String {
        let bytes = store.listeners.compactMap(\.ramBytes).reduce(0, +)
        return "\(bytes.formatBytes()) RAM held"
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.listeners) { item in
                    PortRow(item: item)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                Text("Next free port")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(nextFreePort)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("⧉ copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(nextFreePort, forType: .string)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var nextFreePort: String {
        let used = Set(store.listeners.map(\.port))
        var candidate = 3000
        while used.contains(candidate) {
            candidate += 1
        }
        return String(candidate)
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Button("Preferences…") {
                // v1: open preferences window
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Quit Port Manager ⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

private struct PortRow: View {
    let item: PortItem

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(kindColor)
                .frame(width: 7, height: 7)

            Text(":\(item.port)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(item.isZombie ? .red : .accentColor)
                .frame(width: 58, alignment: .leading)

            HStack(spacing: 0) {
                Text(item.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(" · \(subtitle)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.ramBytes?.formatBytes() ?? "—")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Button(actionLabel) {}
                .font(.system(size: 10.5, weight: .semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(item.isZombie ? .red.opacity(0.85) : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(item.isZombie ? .red.opacity(0.45) : .secondary.opacity(0.25), lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(item.isZombie ? .red.opacity(0.12) : .clear)
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(item.isZombie ? Color.red.opacity(0.07) : Color.clear)
    }

    private var kindColor: Color {
        switch item.kind {
        case .node: return .green
        case .brew: return .yellow
        case .docker: return .blue
        case .ollama: return .purple
        case .other: return .gray
        }
    }

    private var subtitle: String {
        if item.isZombie {
            return "orphaned · 3d"
        }
        switch item.kind {
        case .node: return "\(item.processName) dev"
        case .brew: return "brew service"
        case .docker: return "docker"
        case .ollama: return "\(item.label) loaded"
        case .other: return item.processName
        }
    }

    private var actionLabel: String {
        switch item.kind {
        case .docker, .brew: return "stop"
        case .ollama: return "unload"
        case .node, .other: return "kill"
        }
    }
}

private extension Int64 {
    func formatBytes() -> String {
        let gb = Double(self) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(self) / (1024 * 1024)
        if mb >= 1.0 {
            return String(format: "%.0f MB", mb)
        }
        let kb = Double(self) / 1024
        if kb >= 1.0 {
            return String(format: "%.1f KB", kb)
        }
        return "\(self) B"
    }
}
