import SupersEmuKit
import SwiftUI

/// "A newer save from <device> is available": the player picks which copy to continue. Both copies are kept.
struct SaveConflictPrompt: View {
    let conflict: SaveConflict
    let choose: (SaveConflictChoice) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(conflict.message)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("save-conflict-message")
            Text("\(kindName) from \(conflict.remote.createdAt.formatted(date: .abbreviated, time: .shortened)). Your copy on this device is kept either way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons(fill: false) }
                VStack(spacing: 8) { buttons(fill: true) }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }

    /// Side by side only when both labels fit unwrapped; stacked, full-width buttons may wrap at large text sizes.
    @ViewBuilder private func buttons(fill: Bool) -> some View {
        Button { choose(.keepLocal) } label: { label("Keep This Device's", fill: fill) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("save-conflict-keep-local")
        Button { choose(.useRemote) } label: { label("Use Newer Save", fill: fill) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("save-conflict-use-remote")
    }

    private func label(_ title: String, fill: Bool) -> some View {
        Text(title)
            .multilineTextAlignment(.center)
            .lineLimit(fill ? nil : 1)
            .fixedSize(horizontal: !fill, vertical: fill)
            .frame(maxWidth: fill ? .infinity : nil)
    }

    private var kindName: String {
        switch conflict.line.kind {
        case .native: "In-game save"
        case .auto: "Resume point"
        case .manual: "Saved slot"
        }
    }
}
