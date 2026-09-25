import ShebangCore
import SwiftUI

/// What the compact, click-through status HUD shows during and after a run.
struct RunHUDState: Equatable {
    enum Mode: Equatable {
        case running
        case stopping
        case result(RunOutcome)
    }

    var mode: Mode = .running
    var status = "Starting…"
    var targetName = ""
    var isDryRun = false
}

struct RunHUDView: View {
    static let width: CGFloat = 380

    var state: RunHUDState
    var icon: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            indicator.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text(state.targetName.isEmpty ? "Shebang" : state.targetName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                    if state.isDryRun {
                        Badge(text: "DRY RUN", color: .orange)
                    }
                }
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: Self.width, alignment: .leading)
        .background(PanelBackground(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var indicator: some View {
        switch state.mode {
        case .running, .stopping:
            ProgressView().controlSize(.small)
        case .result(let outcome):
            let style = Self.resultStyle(outcome)
            Image(systemName: style.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(style.color)
        }
    }

    private static func resultStyle(_ outcome: RunOutcome) -> (symbol: String, color: Color) {
        if outcome.isSuccess { return ("checkmark.circle.fill", StatusLine.Tone.success.color) }
        if outcome.status == .cancelled { return ("stop.circle.fill", Color.white.opacity(0.6)) }
        return ("exclamationmark.triangle.fill", StatusLine.Tone.warning.color)
    }

    @ViewBuilder private var content: some View {
        switch state.mode {
        case .running:
            Text(state.status)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("⌃⌘ or Esc to stop")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.45))
        case .stopping:
            Text("Stopping…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        case .result(let outcome):
            Text(outcome.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(outcome.message)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
