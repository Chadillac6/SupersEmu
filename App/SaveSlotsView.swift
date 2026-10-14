import ImageIO
import SwiftUI

struct SaveSlotsView: View {
    @Bindable var session: GameSession

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 420
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}

                ZStack {
                    card(compact: compact)
                        .disabled(session.slotNavigator.confirmation != nil)
                        .accessibilityHidden(session.slotNavigator.confirmation != nil)

                    if let confirmation = session.slotNavigator.confirmation {
                        confirmationOverlay(confirmation, compact: compact)
                    }
                }
                .frame(maxWidth: 460)
                .padding(22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("save-slots")
    }

    private func card(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 14) {
            Text("Save States")
                .font(.title3.bold())
                .lineLimit(1)

            VStack(spacing: 8) {
                ForEach(session.saveSlots) { slot in
                    slotRow(slot, compact: compact)
                        .accessibilityIdentifier("save-slot-\(slot.slot)")
                }
            }

            HStack(spacing: 8) {
                Text("↑↓ slot · ←→ action · A select · B close")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Button("Close") { session.closeSaveSlots() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("save-slots-close")
            }
        }
        .padding(compact ? 16 : 22)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func slotRow(_ slot: SaveSlotInfo, compact: Bool) -> some View {
        let selected = session.slotNavigator.row == slot.slot - 1
        if slot.isEmpty {
            Button {
                session.activateSlot(slot.slot, .save)
            } label: {
                HStack(spacing: 8) {
                    SaveSlotThumbnail(url: nil, empty: true, compact: compact)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Slot \(slot.slot)").font(.callout.bold())
                        Text("Empty").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Label("Save", systemImage: "square.and.arrow.down")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowBackground(selected && session.slotNavigator.column == 0),
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save to Slot \(slot.slot)")
            .accessibilityIdentifier("save-slot-\(slot.slot)-save")
        } else {
            HStack(spacing: 8) {
                SaveSlotThumbnail(url: slot.screenshotURL, empty: false, compact: compact)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slot \(slot.slot)")
                        .font(.callout.bold())
                        .lineLimit(1)
                    if let savedAt = slot.savedAt {
                        Text(savedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 3) {
                    actionButton(slot, .load, label: "Load", column: 0)
                    actionButton(slot, .overwrite, label: "Overwrite", column: 1)
                    Button {
                        session.activateSlot(slot.slot, .delete)
                    } label: {
                        Image(systemName: "trash")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(rowBackground(selected && session.slotNavigator.column == 2),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete")
                    .accessibilityIdentifier("save-slot-\(slot.slot)-delete")
                }
                .font(.caption)
                .frame(minWidth: compact ? 58 : 72)
            }
            .padding(8)
            .background(rowBackground(selected), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }

    private func actionButton(_ slot: SaveSlotInfo, _ action: SaveSlotAction, label: String, column: Int) -> some View {
        Button {
            session.activateSlot(slot.slot, action)
        } label: {
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(rowBackground(session.slotNavigator.row == slot.slot - 1
                                          && session.slotNavigator.column == column),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("save-slot-\(slot.slot)-\(label.lowercased())")
    }

    private func confirmationOverlay(_ confirmation: SaveSlotConfirmation, compact: Bool) -> some View {
        let savedAt = session.saveSlots.first(where: { $0.slot == confirmation.slot })?.savedAt
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "an unknown date"
        let title: String
        let message: String
        let confirmLabel: String
        let destructive: Bool
        switch confirmation.action {
        case .overwrite:
            title = "Replace Slot \(confirmation.slot)?"
            message = "Your save from \(savedAt) will be replaced."
            confirmLabel = "Replace"
            destructive = true
        case .load:
            title = "Load Slot \(confirmation.slot)?"
            message = "Progress since your last save will be lost."
            confirmLabel = "Load"
            destructive = false
        case .delete:
            title = "Delete Slot \(confirmation.slot)?"
            message = "Your save from \(savedAt) will be deleted from this device."
            confirmLabel = "Delete"
            destructive = true
        case .save:
            title = "Save to Slot \(confirmation.slot)?"
            message = "This slot will be replaced."
            confirmLabel = "Save"
            destructive = false
        }

        return ZStack {
            Color.black.opacity(0.68)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { session.slotNavigator.cancelConfirmation() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .padding(4)
                        .background(!confirmation.confirmFocused ? Color.accentColor.opacity(0.35) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("save-slot-cancel")
                    Spacer()
                    Button(role: destructive ? .destructive : nil) {
                        if let command = session.slotNavigator.confirm() { session.perform(command) }
                    } label: {
                        Text(confirmLabel)
                    }
                    .buttonStyle(.bordered)
                    .padding(4)
                    .background(confirmation.confirmFocused ? Color.accentColor.opacity(0.35) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("save-slot-confirm")
                }
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: compact ? 310 : 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("save-slot-confirmation")
        }
        .padding(compact ? 8 : 16)
    }

    private func rowBackground(_ focused: Bool) -> Color {
        focused ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)
    }
}

private struct SaveSlotThumbnail: View {
    let url: URL?
    let empty: Bool
    let compact: Bool

    private var image: CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        if !empty { Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
            }
        }
        .frame(width: compact ? 84 : 96, height: compact ? 63 : 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
