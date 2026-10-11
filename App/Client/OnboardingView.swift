import SupersEmuKit
import SwiftUI
#if os(iOS)
import AVFoundation
#else
import AppKit
#endif

/// "Connect to your SupersEmu Server": scan the pairing QR (iOS), paste the pairing link (macOS),
/// or type the server address and 6-digit code. The same pairing code is the Phase 2 invite.
struct OnboardingView: View {
    @Environment(ServerSession.self) private var server
    let onSkip: (() -> Void)?

    @State private var address = ""
    @State private var code = ""
    @State private var link = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var discoveredServers: [DiscoveredServer] = []
    @State private var selectedServer: DiscoveredServer?
    @State private var selectedServerAddress: URL?
    @State private var resolvingServerID: String?
    #if os(macOS)
    @State private var localServer = ServerModeModel()
    #endif
    #if os(iOS)
    @State private var mode: Mode = .scan
    enum Mode: String, CaseIterable { case scan = "Scan QR Code", code = "Enter Code" }
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                #if os(iOS)
                Picker("Pairing method", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pairing-mode")
                if mode == .scan {
                    QRScannerPanel(paused: isPairing) { scanned in Task { await pair(link: scanned) } }
                } else {
                    codeForm
                }
                #else
                if localServer.health != nil {
                    Button("Use This Mac's Server") { Task { await pairWithThisMac() } }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("pair-local-server")
                }
                linkForm
                HStack { line; Text("or").foregroundStyle(.secondary); line }
                codeForm
                #endif
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("pairing-error")
                }
                if isPairing { ProgressView("Connecting…") }
                if let onSkip {
                    Button("Not now — play games on this device", action: onSkip)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("skip-onboarding")
                }
            }
            .frame(maxWidth: 440)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .disabled(isPairing)
        .task {
            let browser = ServerBrowser()
            for await servers in browser.servers() {
                guard !Task.isCancelled else { return }
                discoveredServers = servers
            }
        }
        #if os(macOS)
        .task { await localServer.refresh() }
        #endif
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Connect to your SupersEmu Server").font(.title2.bold()).multilineTextAlignment(.center)
            Text(instructions).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    private var instructions: String {
        #if os(iOS)
        "On your Mac mini, open SupersEmu in Server mode and choose Pair a Device. Scan the QR code, or type the address and 6-digit code."
        #else
        "On your Mac mini, open SupersEmu in Server mode and choose Pair a Device. Paste the pairing link, or type the address and 6-digit code."
        #endif
    }

    private var line: some View { Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1) }

    #if os(macOS)
    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pairing link").font(.headline)
            HStack {
                TextField("supersemu://pair?d=…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("pairing-link")
                    .onSubmit { Task { await pair(link: link) } }
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) { link = text }
                }
                .accessibilityIdentifier("paste-link")
            }
            Button("Connect with Link") { Task { await pair(link: link) } }
                .buttonStyle(.borderedProminent)
                .disabled(link.isEmpty)
                .accessibilityIdentifier("connect-link")
        }
    }
    #endif

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !discoveredServers.isEmpty {
                Text("Servers on your network").font(.headline)
                ForEach(discoveredServers) { server in
                    Button {
                        Task { await select(server) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.serverName)
                                Text(server.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if resolvingServerID == server.id {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(resolvingServerID != nil)
                    .accessibilityIdentifier("discovered-server-\(server.id)")
                }
            }
            Text("Server address").font(.headline)
            TextField("mac-mini.local", text: $address)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .accessibilityIdentifier("server-address")
            Text("Pairing code").font(.headline).padding(.top, 6)
            TextField("123456", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(6)) }
                .accessibilityIdentifier("pairing-code")
            Button("Connect") { Task { await pairWithCode() } }
                .buttonStyle(.borderedProminent)
                .disabled(address.isEmpty || code.count != 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("connect-code")
        }
    }

    private func pair(link: String) async {
        guard let payload = PairingLinkParser.payload(fromLink: link) else {
            errorMessage = "That isn't a SupersEmu pairing link."
            return
        }
        await pair(payload)
    }

    private func pairWithCode() async {
        if let selectedServer, let selectedServerAddress, address == selectedServerAddress.absoluteString {
            await pair(selectedServer.pairingPayload(at: selectedServerAddress, code: code))
            return
        }
        guard let payload = PairingLinkParser.payload(address: address, code: code) else {
            errorMessage = "Enter the server address and the 6-digit code."
            return
        }
        await pair(payload)
    }

    private func select(_ server: DiscoveredServer) async {
        resolvingServerID = server.id
        errorMessage = nil
        defer { resolvingServerID = nil }
        do {
            let resolvedAddress = try await ServerBrowser.resolve(server)
            selectedServer = server
            selectedServerAddress = resolvedAddress
            address = resolvedAddress.absoluteString
        } catch {
            errorMessage = "Couldn't resolve \(server.serverName). Try entering its address manually."
        }
    }

    #if os(macOS)
    private func pairWithThisMac() async {
        guard let pin = localServer.certificateSHA256 else {
            address = localServer.localURL.absoluteString
            errorMessage = "This Mac's server certificate is unavailable. Enter a pairing code below instead."
            return
        }
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            let client = try LocalServerAdminClient.make(
                dataDirectory: localServer.dataDirectory,
                serverURL: localServer.localURL,
                certificateSHA256: pin,
                timeout: 15
            )
            let pairing = try await client.createPairingCode()
            let payload = PairingPayload(
                serverName: pairing.payload.serverName,
                urls: [localServer.localURL],
                certificateSHA256: pin,
                code: pairing.code
            )
            try await server.pair(payload)
        } catch {
            address = localServer.localURL.absoluteString
            let description = String(describing: error)
            errorMessage = description.contains("admin.token")
                ? "Couldn't read this Mac's admin token. You can still enter a pairing code below."
                : "Couldn't pair with this Mac's server: \(description)"
        }
    }
    #endif

    private func pair(_ payload: PairingPayload) async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            try await server.pair(payload)
        } catch let error as APIClientError {
            switch error {
            case .http(let status, let message) where status == 400 || status == 401 || status == 404 || status == 410:
                errorMessage = message ?? "That code didn't work. It may have expired; make a new one on the server."
            default:
                errorMessage = error.description
            }
        } catch {
            errorMessage = "Couldn't reach \(payload.serverName). Check that you're on the same network (or Tailscale)."
        }
    }
}

#if os(iOS)
struct QRScannerPanel: View {
    let paused: Bool
    let onScan: (String) -> Void
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            if AVCaptureDevice.default(for: .video) == nil {
                unavailable("No camera available on this device. Use Enter Code instead.")
            } else if authorization == .authorized {
                QRScannerView(paused: paused, onScan: onScan)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.4), lineWidth: 2))
            } else if authorization == .notDetermined {
                Color.clear.frame(height: 1).task {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    authorization = AVCaptureDevice.authorizationStatus(for: .video)
                }
            } else {
                unavailable("Camera access is off. Allow it in Settings, or use Enter Code.")
            }
        }
        .accessibilityIdentifier("qr-scanner")
    }

    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct QRScannerView: UIViewRepresentable {
    let paused: Bool
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = context.coordinator.session
        if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
        }
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setPaused(paused)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let onScan: (String) -> Void
        private var lastValue: String?
        private var lastScan = Date.distantPast
        private var paused = false

        /// No scans are delivered while a pairing request is in flight; after a failure the same
        /// code can retry once the 3 s grace period has passed.
        func setPaused(_ value: Bool) {
            if paused, !value { lastScan = Date() }
            paused = value
        }

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  value.hasPrefix("supersemu://"), !paused else { return }
            if value == lastValue, Date().timeIntervalSince(lastScan) < 3 { return }
            lastValue = value
            lastScan = Date()
            onScan(value)
        }
    }
}
#endif
