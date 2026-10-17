import SwiftUI
import SupersEmuKit

/// One-line connection status above the library: unreachable, certificate mismatch, signed out, connected via
/// the public internet, and a short "back online" after recovering. Nothing on the home network.
struct ConnectionBanner: View {
    @Environment(ServerSession.self) private var server
    @Environment(DownloadCenter.self) private var downloads
    @State private var dismissedRecovery: Date?
    @State private var retrying = false

    var body: some View {
        Group {
            if let message = server.connection.message(serverName: server.serverName) {
                problem(message)
            } else if server.connection == .connecting, server.games.isEmpty {
                ProgressView("Connecting to \(server.serverName)…")
                    .padding(.horizontal, 20)
            } else if showsRecovery {
                pill("Back online. Saves made offline are syncing.", symbol: "checkmark.icloud", id: "connection-recovered")
            } else if server.connection == .connected(.internet) {
                pill("Connected to \(server.serverName) via Internet", symbol: "globe", id: "connection-internet")
            }
        }
        .animation(.default, value: server.connection)
        .animation(.default, value: showsRecovery)
        .task(id: server.recoveredAt) {
            guard let recoveredAt = server.recoveredAt else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            dismissedRecovery = recoveredAt
        }
        .foregroundStyle(Brand.Colors.ink)
    }

    private var showsRecovery: Bool {
        guard let recoveredAt = server.recoveredAt, recoveredAt != dismissedRecovery, server.isOnline else { return false }
        return Date().timeIntervalSince(recoveredAt) < 6
    }

    private var unavailableCount: Int {
        server.games.filter { !downloads.isDownloaded($0.id) }.count
    }

    private func problem(_ message: ConnectionState.Message) -> some View {
        HStack(spacing: 12) {
            Image(systemName: message.symbol).font(.title3)
                .foregroundStyle(server.connection == .unreachable ? Brand.Colors.ink2 : Brand.Colors.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title).font(.callout.bold())
                Text(message.detail).font(.caption).foregroundStyle(.secondary)
                if unavailableCount > 0 {
                    Text("Showing games you can play offline. \(unavailableCount) more \(unavailableCount == 1 ? "is" : "are") unavailable until you reconnect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("offline-unavailable-count")
                }
            }
            Spacer()
            if message.canRetry {
                Button {
                    retrying = true
                    Task {
                        await server.retryNow()
                        retrying = false
                    }
                } label: {
                    if retrying { ProgressView().controlSize(.small) } else { Text("Retry") }
                }
                .disabled(retrying)
                .accessibilityIdentifier("retry-server")
            }
        }
        .padding(14)
        .background(Brand.Colors.surface, in: RoundedRectangle(cornerRadius: Brand.Radii.card))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radii.card).stroke(Brand.Colors.line, lineWidth: 1))
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(bannerID)
    }

    private var bannerID: String {
        switch server.connection {
        case .certificateMismatch: return "certificate-mismatch-banner"
        case .signedOut: return "signed-out-banner"
        default: return "offline-banner"
        }
    }

    private func pill(_ text: String, symbol: String, id: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(Brand.Colors.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Brand.Colors.surface, in: Capsule())
            .overlay(Capsule().stroke(Brand.Colors.line, lineWidth: 1))
            .padding(.horizontal, 20)
            .accessibilityIdentifier(id)
    }
}
