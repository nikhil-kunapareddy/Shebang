import AppKit
import SwiftUI

/// Status & Permissions window.
struct StatusView: View {
    @ObservedObject var model: PermissionsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shebang").font(.title2.bold())
                    Text(model.summary).foregroundStyle(model.isReady ? Color.secondary : Color.orange)
                }
            }

            Text("Switch to any app and press ⌃⌘ (Control+Command) to tell Shebang what to do. "
                 + "Press ⌃⌘ or Esc during a run to stop it. You can close this window; Shebang stays in the menu bar.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    PermissionRowView(row: row) { model.perform(row.kind) }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            Label(model.hotkeyText, systemImage: model.status.hotkeyListening ? "keyboard.fill" : "keyboard")
                .foregroundStyle(.secondary)

            Text("Screen reading and OCR run on this Mac. Your goal and the target app's visible controls are sent to "
                 + "the Jev model through Vercel AI Gateway. Every action is recorded in the local audit log.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 580)
    }
}

private struct PermissionRowView: View {
    var row: PermissionRow
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(symbolColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.body.weight(.medium))
                    Text(row.isRequired ? "Required" : "Optional")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(row.stateText)
                .font(.callout)
                .foregroundStyle(row.isGranted ? Color.secondary : symbolColor)
            Button(row.actionTitle, action: action)
                .frame(minWidth: 120)
        }
        .padding(.vertical, 10)
    }

    private var symbol: String {
        if row.isGranted { return "checkmark.circle.fill" }
        return row.isRequired ? "exclamationmark.circle.fill" : "circle.dashed"
    }

    private var symbolColor: Color {
        if row.isGranted { return .green }
        return row.isRequired ? .orange : .secondary
    }
}
