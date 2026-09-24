import AppKit
import SwiftUI

struct APIKeyView: View {
    @ObservedObject var model: APIKeyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.headline).font(.title3.bold())
                    Text(model.explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Vercel AI Gateway API key").font(.headline)
                SecureField(model.placeholder, text: $model.keyText)
                    .textFieldStyle(.roundedBorder)
                Link("Get a key at vercel.com/dashboard → AI Gateway → API Keys", destination: APIKeyViewModel.dashboardURL)
                    .font(.callout)
            }

            if model.environmentOverride {
                Label("AI_GATEWAY_API_KEY is set in the environment or .env and takes precedence over the Keychain.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Your key is stored in the macOS Keychain and never written to logs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.isTesting {
                    ProgressView().controlSize(.small)
                }
                if let message = model.message {
                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(color(for: message.tone))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)

            HStack {
                Button("Test Connection", action: model.testConnection)
                    .disabled(model.isTesting)
                Spacer()
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func color(for tone: StatusLine.Tone) -> Color {
        switch tone {
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        case .neutral, .info, .listening: return .secondary
        }
    }
}
