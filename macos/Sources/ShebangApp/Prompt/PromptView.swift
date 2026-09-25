import SwiftUI

/// The goal prompt: target header, goal field, and a footer with the status line, mic, and send buttons.
struct PromptView: View {
    static let width: CGFloat = 600

    @ObservedObject var model: PromptViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            field
            footer
        }
        .padding(18)
        .frame(width: Self.width)
        .background(PanelBackground(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusRequest) { fieldFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = model.targetIcon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Badge(text: "SHEBANG", color: Color(red: 0.39, green: 0.40, blue: 0.95))
            if model.isDryRun {
                Badge(text: "DRY RUN", color: .orange)
            }
            Text(model.targetDescription)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: model.cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
        }
    }

    private var field: some View {
        TextField("What would you like Shebang to do?", text: $model.goal)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .focused($fieldFocused)
            .onSubmit(model.submit)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .accessibilityLabel("Goal")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.status.text)
                .font(.system(size: 11))
                .foregroundStyle(model.status.tone.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if model.isVoiceAvailable {
                Button(action: model.toggleListening) {
                    Label(model.isListening ? "Stop" : "Mic", systemImage: model.isListening ? "stop.fill" : "mic.fill")
                }
                .controlSize(.small)
                .help(model.isListening ? "Stop listening" : "Speak your goal")
            }
            Button(action: model.submit) {
                Text("Send ↩")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.39, green: 0.40, blue: 0.95))
            .controlSize(.small)
            .disabled(!model.canSubmit)
        }
    }
}

struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
    }
}
