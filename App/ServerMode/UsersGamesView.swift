#if os(macOS)
import SwiftUI
import SupersEmuKit

struct UsersGamesView: View {
    private enum VisibilityFilter: String, CaseIterable {
        case all = "All"
        case visible = "Visible"
        case hidden = "Hidden"
    }

    let model: UsersGamesModel
    @State private var search = ""
    @State private var systemFilter: SystemID?
    @State private var visibilityFilter = VisibilityFilter.all
    @State private var showingAddFriend = false
    @State private var showingRename = false
    @State private var showingInvite = false
    @State private var showingRemoveUser = false

    private var filteredGames: [GameSummary] {
        model.games.filter { game in
            (search.isEmpty || game.title.localizedCaseInsensitiveContains(search))
                && (systemFilter == nil || game.system == systemFilter)
                && (visibilityFilter == .all
                    || (visibilityFilter == .visible) == !model.hiddenGameIDs.contains(game.id))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            peopleColumn
                .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Users & Games")
        .task { await model.refresh() }
        .sheet(isPresented: $showingAddFriend) {
            AddFriendSheet { name in try await model.createFriend(displayName: name) }
        }
        .sheet(isPresented: $showingRename) {
            if let user = model.selectedUser {
                RenameFriendSheet(name: user.displayName) { name in try await model.renameSelectedUser(displayName: name) }
            }
        }
        .sheet(isPresented: $showingInvite) {
            if let user = model.selectedUser {
                InviteDeviceSheet(user: user, createCode: { try await model.createPairingCode(for: user.id) })
            }
        }
        .confirmationDialog("Remove \(model.selectedUser?.displayName ?? "friend")?", isPresented: $showingRemoveUser) {
            Button("Remove Friend", role: .destructive) { Task { await model.removeSelectedUser() } }
        } message: {
            Text("Their devices are signed out. Their saves stay on the server.")
        }
    }

    private var peopleColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PEOPLE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 18)
            List(selection: Binding(get: { model.selectedUserID }, set: { id in Task { await model.selectUser(id) } })) {
                ForEach(model.users) { user in
                    HStack(spacing: 8) {
                        Text(user.displayName).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(user.role == .admin ? "Admin · all games" : deviceSummary(for: user))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(user.id)
                }
            }
            .listStyle(.plain)
            Button { showingAddFriend = true } label: {
                Label("Add Friend…", systemImage: "plus").font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var detailContent: some View {
        if model.isLoading && model.users.isEmpty {
            ProgressView("Loading users…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.error != nil && model.users.isEmpty {
            ContentUnavailableView("Server not running", systemImage: "server.rack",
                                   description: Text("Start the server to manage friends and game access."))
        } else if let user = model.selectedUser, user.role == .admin {
            VStack(alignment: .leading, spacing: 12) {
                Text(user.displayName).font(.title2.weight(.semibold))
                Text("The server admin always sees every game.")
                    .foregroundStyle(.secondary)
                if let error = model.error { errorLabel(error) }
                Spacer()
            }
            .padding(22)
        } else if let user = model.selectedUser {
            friendDetail(user)
        } else {
            ContentUnavailableView("No friends yet", systemImage: "person.2",
                                   description: Text("Add a friend to invite devices and manage game visibility."))
        }
    }

    private func friendDetail(_ user: UserInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(user.displayName).font(.title2.weight(.semibold))
                Button("Rename") { showingRename = true }
                Spacer()
                Button("Invite a Device…") { showingInvite = true }.buttonStyle(.borderedProminent)
                Button("Remove \(user.displayName)…", role: .destructive) { showingRemoveUser = true }
            }
            Text("Invite a Device shows a one-time pairing code and QR for \(user.displayName). It expires in 10 minutes.")
                .font(.caption).foregroundStyle(.secondary)
            Text("DEVICES").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
            VStack(spacing: 0) {
                if model.activeDevices.isEmpty {
                    Text("Not paired").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.activeDevices) { device in
                        HStack {
                            Text(device.name)
                            if let lastSeenAt = device.lastSeenAt {
                                Text("· seen \(lastSeen(lastSeenAt))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { Task { await model.removeDevice(device) } }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            gamesSection(user)
            Text("Changes save immediately. New games are shared with everyone automatically. Hiding a game doesn't delete \(user.displayName)'s saves.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { errorLabel(error) }
        }
        .padding(18)
    }

    private func gamesSection(_ user: UserInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Games \(user.displayName) can see · \(model.visibleGameCount) of \(model.games.count)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.isLoadingAccess {
                ProgressView("Loading game access…").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Search games", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 100, maxWidth: .infinity)
                            .layoutPriority(1)
                        Menu(systemFilter.map(systemName) ?? "All Systems") {
                            Button("All Systems") { systemFilter = nil }
                            ForEach(SystemID.allCases, id: \.self) { system in
                                Button(systemName(system)) { systemFilter = system }
                            }
                        }
                        .fixedSize()
                        Menu("Show: \(visibilityFilter.rawValue)") {
                            ForEach(VisibilityFilter.allCases, id: \.self) { filter in
                                Button(filter.rawValue) { visibilityFilter = filter }
                            }
                        }
                        .fixedSize()
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Select All") { setShown(visible: true) }
                            .fixedSize()
                        Button("Clear") { setShown(visible: false) }
                            .fixedSize()
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredGames) { game in
                            HStack(spacing: 10) {
                                Toggle(game.title, isOn: Binding(
                                    get: { !model.hiddenGameIDs.contains(game.id) },
                                    set: { model.setVisible(game.id, visible: $0) }))
                                    .toggleStyle(VisibilityCheckboxStyle())
                                    .labelsHidden()
                                    .accessibilityLabel(game.title)
                                    .accessibilityValue(model.hiddenGameIDs.contains(game.id) ? "Hidden" : "Visible")
                                Text(game.title).lineLimit(1)
                                Text(systemName(game.system))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(minHeight: 160, maxHeight: 280)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            }
        }
        .padding(.top, 10)
    }

    private func setShown(visible: Bool) {
        for game in filteredGames { model.setVisible(game.id, visible: visible) }
    }

    private func deviceSummary(for user: UserInfo) -> String {
        let count = model.devices.filter { $0.userID == user.id && $0.revokedAt == nil }.count
        return count == 0 ? "Not paired" : "\(count) device\(count == 1 ? "" : "s")"
    }

    private func systemName(_ system: SystemID) -> String {
        switch system {
        case .snes: "SNES"
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .gba: "Game Boy Advance"
        case .genesis: "Genesis"
        case .segacd: "Sega CD"
        case .sega32x: "32X"
        case .psx: "PS1"
        case .n64: "N64"
        }
    }

    private func lastSeen(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
    }
}

private struct VisibilityCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

private struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    let create: (String) async throws -> UserInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Friend").font(.title2.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit { Task { await submit() } }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Friend") { Task { await submit() } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private func submit() async {
        do { _ = try await create(name); dismiss() }
        catch { self.error = LibraryManagerModel.describe(error) }
    }
}

private struct RenameFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State private var error: String?
    let rename: (String) async throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Friend").font(.title2.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { Task { await submit() } }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private func submit() async {
        do { try await rename(name); dismiss() }
        catch { self.error = LibraryManagerModel.describe(error) }
    }
}

private struct InviteDeviceSheet: View {
    let user: UserInfo
    let createCode: () async throws -> PairingCode
    @State private var pairing: PairingCode?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Invite a Device").font(.title2.weight(.semibold))
                Spacer()
                Button(pairing == nil ? "Create Code" : "New Code") { Task { await makeCode() } }
                    .buttonStyle(.borderedProminent).disabled(loading)
            }
            if let pairing {
                HStack(alignment: .top, spacing: 20) {
                    QRCodeImage(text: pairing.qrURL).frame(width: 190, height: 190)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scan with the SupersEmu app, or enter the code:").foregroundStyle(.secondary)
                        Text(ServerModeView.grouped(pairing.code))
                            .font(.system(size: 36, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(pairing.expiresAt.timeIntervalSince(context.date)))
                            Text(remaining > 0 ? "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)) · one-time use" : "Expired")
                                .foregroundStyle(remaining > 0 ? Color.gray : Color.red)
                        }
                    }
                }
            } else if loading {
                ProgressView("Creating pairing code…")
            } else {
                Text("Create a one-time pairing code for \(user.displayName).")
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(22)
        .frame(minWidth: 540, idealWidth: 540, minHeight: 280)
    }

    @Environment(\.dismiss) private var dismiss

    private func makeCode() async {
        loading = true
        defer { loading = false }
        do { pairing = try await createCode(); error = nil }
        catch { self.error = LibraryManagerModel.describe(error) }
    }
}
#endif
