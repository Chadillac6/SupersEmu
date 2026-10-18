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
            HStack {
                Text("Save States")
                    .font(.title2.bold())
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { session.closeSaveSlots() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("save-slots-close")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(session.saveSlots) { slot in
                            slotCard(slot, compact: compact)
                                .id(slot.slot)
                                .accessibilityIdentifier("save-slot-\(slot.slot)")
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: session.slotNavigator.row) { _, row in
                    withAnimation { proxy.scrollTo(row + 1) }
                }
            }

            Text("↑↓ slot · ←→ action · A select · B close")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(compact ? 16 : 20)
        .frame(maxWidth: .infinity)
        .brandPanel()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func slotCard(_ slot: SaveSlotInfo, compact: Bool) -> some View {
        let focusedRow = session.slotNavigator.row == slot.slot - 1
        let column = session.slotNavigator.column
        if slot.isEmpty {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slot \(slot.slot)").font(.headline)
                    Text("Empty").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                bigButton("Save Here", systemImage: "square.and.arrow.down", primary: true,
                          focused: focusedRow && column == 0, id: "save-slot-\(slot.slot)-save") {
                    session.activateSlot(slot.slot, .save)
                }
                .accessibilityLabel("Save to Slot \(slot.slot)")
                .frame(maxWidth: 180)
            }
            .padding(12)
            .background(Brand.Colors.card, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SaveSlotThumbnail(url: slot.screenshotURL, height: compact ? 150 : 180)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Slot \(slot.slot)").font(.headline).lineLimit(1)
                            if slot.isNew {
                                Text("NEW")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Brand.Colors.red, in: Capsule())
                                    .accessibilityIdentifier("save-slot-\(slot.slot)-new")
                            }
                        }
                        HStack(spacing: 4) {
                            Label(slot.deviceName ?? "This \(SaveDevice.thisDevice)",
                                  systemImage: SaveDevice.symbol(for: slot.deviceName ?? SaveDevice.thisDevice))
                                .accessibilityIdentifier("save-slot-\(slot.slot)-device")
                            if let savedAt = slot.savedAt {
                                Text("· \(savedAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Menu {
                        Button("Delete Save", systemImage: "trash", role: .destructive) {
                            session.activateSlot(slot.slot, .delete)
                        }
                        .accessibilityIdentifier("save-slot-\(slot.slot)-delete")
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.12), in: Circle())
                            .overlay { if focusedRow && column == 2 { Circle().strokeBorder(.white, lineWidth: 3) } }
                            .contentShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More for Slot \(slot.slot)")
                    .accessibilityIdentifier("save-slot-\(slot.slot)-more")
                }
                HStack(spacing: 10) {
                    bigButton("Load", systemImage: "play.fill", primary: true,
                              focused: focusedRow && column == 0, id: "save-slot-\(slot.slot)-load") {
                        session.activateSlot(slot.slot, .load)
                    }
                    bigButton("Save Here", systemImage: "square.and.arrow.down", primary: false,
                              focused: focusedRow && column == 1, id: "save-slot-\(slot.slot)-overwrite") {
                        session.activateSlot(slot.slot, .overwrite)
                    }
                }
            }
            .padding(12)
            .background(Brand.Colors.card, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .contain)
        }
    }

    private func bigButton(_ title: String, systemImage: String, primary: Bool, focused: Bool, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(primary ? Brand.Colors.red : Color.white.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: 14).strokeBorder(.white, lineWidth: 3) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
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
                    Button {
                        session.slotNavigator.cancelConfirmation()
                    } label: {
                        if !confirmation.confirmFocused {
                            Text("Cancel").foregroundStyle(.white)
                        } else {
                            Text("Cancel")
                        }
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .padding(4)
                    .background(!confirmation.confirmFocused ? Brand.Colors.red : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("save-slot-cancel")
                    Spacer()
                    Button(role: destructive ? .destructive : nil) {
                        if let command = session.slotNavigator.confirm() { session.perform(command) }
                    } label: {
                        if confirmation.confirmFocused {
                            Text(confirmLabel).foregroundStyle(.white)
                        } else {
                            Text(confirmLabel)
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(4)
                    .background(confirmation.confirmFocused ? Brand.Colors.red : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("save-slot-confirm")
                }
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: compact ? 310 : 360)
            .brandPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("save-slot-confirmation")
        }
        .padding(compact ? 8 : 16)
    }

    private func rowBackground(_ focused: Bool) -> Color {
        focused ? Brand.Colors.red : Brand.Colors.card
    }
}

private struct SaveSlotThumbnail: View {
    let url: URL?
    let height: CGFloat

    private var image: CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    var body: some View {
        Color.white.opacity(0.08)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }
}
