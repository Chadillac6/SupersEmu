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
            HStack(spacing: 12) {
                Button("Keep This Device's") { choose(.keepLocal) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("save-conflict-keep-local")
                Button("Use Newer Save") { choose(.useRemote) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("save-conflict-use-remote")
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }

    private var kindName: String {
        switch conflict.line.kind {
        case .native: "In-game save"
        case .auto: "Resume point"
        case .manual: "Saved slot"
        }
    }
}
