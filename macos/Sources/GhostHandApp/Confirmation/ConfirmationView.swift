import SwiftUI

/// Human-approval panel for sensitive actions (port of ConfirmationDialog.xaml).
struct ConfirmationView: View {
    static let width: CGFloat = 480

    @ObservedObject var model: ConfirmationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Color.yellow)
                Text("HUMAN APPROVAL REQUIRED")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.yellow)
            }
            Text("A sensitive action was paused for your safety.")
                .font(.system(size: 13))
                .foregroundStyle(.white)

            if let details = model.details {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Action:", details.action, color: .white, weight: .semibold)
                    row("Target:", details.target, color: Color(red: 0.38, green: 0.65, blue: 0.98), weight: .semibold)
                    if let text = details.text {
                        row("Text:", "“\(text)”", color: Color.white.opacity(0.85))
                    }
                    row("App:", details.app, color: Color.white.opacity(0.85))
                    row("Reason:", details.reason, color: Color(red: 0.97, green: 0.44, blue: 0.44))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Reject & Abort (Esc)", action: model.reject)
                Button("Approve & Execute (↩)", action: model.approve)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.13, green: 0.62, blue: 0.35))
                    .disabled(!model.isArmed)
            }
        }
        .padding(20)
        .frame(width: Self.width)
        .background(PanelBackground(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ label: String, _ value: String, color: Color, weight: Font.Weight = .regular) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(size: 12, weight: weight))
                .foregroundStyle(color)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
