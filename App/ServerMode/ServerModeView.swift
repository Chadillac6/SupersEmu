#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import SupersEmuKit

struct ServerModeScene: Scene {
    static let windowID = "server-mode"

    var body: some Scene {
        Window("SupersEmu Server", id: Self.windowID) {
            ServerModeView()
        }
        .defaultSize(width: 980, height: 820)
        .commands { ServerModeCommands() }
    }
}

/// Applied to the main window: opens Server mode at launch when requested (`--server-mode` or the toggle).
struct ServerModeLaunchHook: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            if ServerModeLaunch.consumeRequest() { openWindow(id: ServerModeScene.windowID) }
        }
    }
}

extension View {
    func serverModeLaunchHook() -> some View { modifier(ServerModeLaunchHook()) }
}

struct ServerModeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Server Mode") { openWindow(id: ServerModeScene.windowID) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

/// Sidebar sections of the Server Mode window. Each is a self-contained view; add a case to add a section.
enum ServerModeSection: String, CaseIterable, Identifiable {
    case server, library, review, bios, storage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .server: return "Server"
        case .library: return "Add Games"
        case .review: return "Review Needed"
        case .bios: return "BIOS"
        case .storage: return "Storage"
        }
    }
    var systemImage: String {
        switch self {
        case .server: return "server.rack"
        case .library: return "square.and.arrow.down.on.square"
        case .review: return "exclamationmark.bubble"
        case .bios: return "cpu"
        case .storage: return "externaldrive"
        }
    }
}

struct ServerModeView: View {
    @State private var model = ServerModeModel()
    @State private var library: LibraryManagerModel?
    @State private var section: ServerModeSection? = .server
    @AppStorage(ServerModeLaunch.defaultsKey) private var openAtLaunch = false

    var body: some View {
        NavigationSplitView {
            List(ServerModeSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.systemImage)
                    .badge(item == .review ? library?.issues.count ?? 0 : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail
                .frame(minWidth: 620, minHeight: 600)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let library, !urls.isEmpty, library.canImport else { return false }
            if section != .bios { section = .library }
            Task { await library.importItems(urls) }
            return true
        }
        .task {
            if library == nil { library = LibraryManagerModel(server: model) }
            await library?.refreshStorage()
        }
        .onChange(of: model.source) {
            library?.reset()
            Task { await model.refresh(); await library?.refreshAll() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch (section ?? .server, library) {
        case (.library, let library?): LibraryImportView(model: library, onReview: { section = .review })
        case (.review, let library?): ReviewNeededView(model: library)
        case (.bios, let library?): BIOSView(model: library)
        case (.storage, let library?): StorageView(model: library)
        default: overview
        }
    }

    private var overview: some View {
        Form {
            serverSection
            if model.isLocal {
                daemonSection
                pairingSection
                devicesSection
            }
            BackupsSection(model: model)
        }
        .formStyle(.grouped)
        .task {
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await model.refresh()
            }
        }
    }

    private var serverSection: some View {
        Section("Server") {
            Picker("Server", selection: $model.source) {
                ForEach(model.sources) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.source) { Task { await model.refresh() } }

            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(model.health != nil ? Color.green : Color.red).frame(width: 9, height: 9)
                    if let health = model.health {
                        Text("Running: \(health.serverName) v\(health.serverVersion)")
                    } else {
                        Text(model.statusError ?? "Checking…").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Address", value: model.serverURL.absoluteString)
            if model.isLocal {
                LabeledContent("Data folder") {
                    Text(model.dataDirectory.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
            if let pin = model.certificateSHA256 {
                LabeledContent("Certificate SHA-256") {
                    Text(pin.prefix(16) + "…").font(.system(.body, design: .monospaced)).help(pin).textSelection(.enabled)
                }
            }
            if model.source == .session {
                HStack {
                    if model.sessionRunning {
                        Button("Stop Server") { Task { await model.stopSession() } }
                    } else {
                        Button("Start Server for This Session") { Task { await model.startSession() } }
                            .disabled(model.busy || model.serverBinary == nil)
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Toggle("Open Server mode when SupersEmu launches", isOn: $openAtLaunch)
        }
    }

    private var daemonSection: some View {
        Section {
            LabeledContent("Launch daemon", value: model.daemonStatusText)
            HStack {
                if model.daemonStatus == .enabled || model.daemonStatus == .requiresApproval {
                    Button("Unregister") { Task { await model.unregisterDaemon() } }
                } else {
                    Button("Register Boot Daemon") { Task { await model.registerDaemon() } }
                }
                Button("Open Login Items Settings") { model.openLoginItems() }
            }
        } header: {
            Text("Start at boot")
        } footer: {
            Text("Runs supersemu-server as a launch daemon so the library is available after a restart with no one logged in. macOS asks an administrator to approve it once in System Settings › General › Login Items.")
        }
    }

    private var pairingSection: some View {
        Section("Pair a device") {
            HStack {
                Button(model.pairing == nil ? "New Pairing Code" : "New Code") { Task { await model.createPairingCode() } }
                    .disabled(model.health == nil)
                Spacer()
            }
            if let error = model.pairingError { Text(error).foregroundStyle(.red).font(.callout) }
            if let pairing = model.pairing {
                HStack(alignment: .top, spacing: 24) {
                    QRCodeImage(text: pairing.qrURL).frame(width: 220, height: 220)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Scan with the SupersEmu app, or enter the code:").foregroundStyle(.secondary)
                        Text(Self.grouped(pairing.code)).font(.system(size: 40, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(pairing.expiresAt.timeIntervalSince(context.date)))
                            Text(remaining > 0 ? "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)) · one-time use" : "Expired")
                                .foregroundStyle(remaining > 0 ? Color.secondary : Color.red)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Addresses in this code").font(.caption).foregroundStyle(.secondary)
                            ForEach(pairing.payload.urls, id: \.self) { Text($0.absoluteString).font(.caption.monospaced()) }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var devicesSection: some View {
        Section("Paired devices") {
            if let error = model.devicesError {
                Text(error).foregroundStyle(.secondary).font(.callout)
            } else if model.devices.isEmpty {
                Text(model.health == nil ? "Start the server to see devices." : "No devices paired yet.").foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                LabeledContent {
                    if device.revokedAt != nil {
                        Text("Revoked").foregroundStyle(.red)
                    } else if let seen = device.lastSeenAt {
                        Text("Seen \(seen.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Paired \(device.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                } label: {
                    Text(device.name)
                }
            }
        }
    }

    static func grouped(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

/// QR code rendered with CoreImage's generator, scaled with nearest-neighbour so it stays sharp.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Pairing QR code")
        } else {
            Text("QR unavailable")
        }
    }

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
#endif
