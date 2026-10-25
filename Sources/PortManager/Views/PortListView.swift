import Core
import SwiftUI

struct PortListView: View {
    @ObservedObject var store: PortStore

    var body: some View {
        VStack(spacing: 0) {
            header
            if let errorMessage = store.error?.localizedDescription {
                errorBanner(message: errorMessage)
            }
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

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.red.opacity(0.08))
    }

    private var summary: some View {
        HStack {
            Text("\(store.processCount) listeners")
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
        "\(store.totalRAM.formatBytes()) RAM held"
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
                Text(nextFreePortText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("⧉ copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(nextFreePortText, forType: .string)
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

    private var nextFreePortText: String {
        let used = Set(store.listeners.map(\.port))
        guard let port = Core.nextFreePort(used: used) else { return "—" }
        return String(port)
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
                .overlay(
                    item.isZombie
                        ? Image(systemName: "xmark")
                            .font(.system(size: 5, weight: .bold))
                            .foregroundStyle(.white)
                        : nil
                )

            Text(":\(item.port)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(item.isZombie ? .red : .accentColor)
                .frame(width: 58, alignment: .leading)

            HStack(spacing: 0) {
                Text(item.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(" · \(displaySubtitle)")
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
                .disabled(true)
                .help("requires KillEngine (v1)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(item.isZombie ? Color.red.opacity(0.07) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
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

    private var displaySubtitle: String {
        if item.isZombie {
            return "orphaned · \(item.ageLabel())"
        }
        return item.subtitle
    }

    private var actionLabel: String {
        switch item.kind {
        case .docker, .brew: return "stop"
        case .ollama: return "unload"
        case .node, .other: return "kill"
        }
    }

    private var accessibilityLabel: String {
        let state = item.isZombie ? "zombie" : item.kind.displayName
        return "\(state) on port \(item.port), \(item.label), \(item.ramBytes?.formatBytes() ?? "unknown RAM")"
    }
}

