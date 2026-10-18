import ImageIO
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
        .brandPanel()
        .padding(24)
    }

    /// Side by side only when both labels fit unwrapped; stacked, full-width buttons may wrap at large text sizes.
    @ViewBuilder private func buttons(fill: Bool) -> some View {
        Button { choose(.keepLocal) } label: { label("Keep This Device's", fill: fill) }
            .buttonStyle(BrandSecondaryButtonStyle())
            .accessibilityIdentifier("save-conflict-keep-local")
        Button { choose(.useRemote) } label: { label("Use Newer Save", fill: fill) }
            .buttonStyle(BrandPrimaryButtonStyle())
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

/// Names and icons for the device a save came from.
enum SaveDevice {
    static var thisDevice: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    static func symbol(for name: String?) -> String {
        let name = name?.lowercased() ?? ""
        if name.contains("ipad") { return "ipad" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("mac") { return "laptopcomputer" }
        return "externaldrive.connected.to.line.below"
    }

    static func image(from png: Data?) -> Image? {
        guard let png, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Image(decorative: image, scale: 1)
    }
}

/// "Newer save from <device>" while playing: Load swaps it in, X keeps playing this device's game.
struct NewerSaveBanner: View {
    let revision: SaveRevision
    let load: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: SaveDevice.symbol(for: revision.deviceName))
                .font(.title2)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Newer save from \(revision.deviceName ?? "another device")")
                    .font(.callout.bold())
                    .lineLimit(2)
                Text("\(what) · \(revision.createdAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Load", action: load)
                .buttonStyle(BrandPrimaryButtonStyle())
                .accessibilityIdentifier("newer-save-load")
            Button(action: dismiss) {
                Image(systemName: "xmark").padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep playing")
            .accessibilityIdentifier("newer-save-dismiss")
        }
        .padding(14)
        .frame(maxWidth: 460)
        .brandPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newer-save-banner")
    }

    private var what: String {
        revision.kind == .manual ? "Slot \(revision.slot.dropFirst(4))" : "Resume point"
    }
}
