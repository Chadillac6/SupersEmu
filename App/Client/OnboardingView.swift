import CryptoKit
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
    @State private var fingerprintConfirmationPayload: PairingPayload?
    @State private var fingerprintConfirmationValue: String?
    @State private var showFingerprintConfirmation = false
    @State private var showCodeForm = false
    @State private var pendingRequestMessage: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var diagnostics = ""
    @State private var copiedDiagnostics = false
    #if os(macOS)
    @State private var localServer = ServerModeModel()
    #endif
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                #if os(iOS)
                codeForm
                DisclosureGroup("Scan a QR code instead") {
                    QRScannerPanel(paused: isPairing) { scanned in Task { await pair(link: scanned) } }
                }
                #else
                if localServer.health != nil {
                    Button("Use This Mac's Server") { Task { await pairWithThisMac() } }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("pair-local-server")
                }
                codeForm
                DisclosureGroup("Use a pairing link instead") { linkForm }
                #endif
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("pairing-error")
                }
                if let pendingRequestMessage {
                    VStack(spacing: 12) {
                        Text(pendingRequestMessage).multilineTextAlignment(.center)
                        Button("Cancel Request", role: .cancel) {
                            requestTask?.cancel()
                            requestTask = nil
                            self.pendingRequestMessage = nil
                            isPairing = false
                        }
                    }
                } else if isPairing {
                    ProgressView("Connecting…")
                }
                if !diagnostics.isEmpty {
                    Button(copiedDiagnostics ? "Diagnostics Copied" : "Copy Diagnostics") {
                        #if os(iOS)
                        UIPasteboard.general.string = diagnostics
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics, forType: .string)
                        #endif
                        copiedDiagnostics = true
                    }
                    .buttonStyle(.borderless)
                }
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
        .task {
            let browser = ServerBrowser()
            for await servers in browser.servers() {
                guard !Task.isCancelled else { return }
                discoveredServers = servers
            }
        }
        #if os(macOS)
        .task {
            await localServer.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await localServer.refresh()
            }
        }
        #endif
        .alert("Verify the server fingerprint", isPresented: $showFingerprintConfirmation) {
            Button("Cancel", role: .cancel) {
                fingerprintConfirmationPayload = nil
                fingerprintConfirmationValue = nil
            }
            Button("The fingerprint matches") {
                guard let payload = fingerprintConfirmationPayload,
                      let fingerprint = fingerprintConfirmationValue else { return }
                fingerprintConfirmationPayload = nil
                fingerprintConfirmationValue = nil
                Task { await completePairing(payload, confirmedCertificateSHA256: fingerprint) }
            }
        } message: {
            Text(fingerprintConfirmationMessage)
        }
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
        "Choose a server on your network or enter its address to request approval. You can also scan a QR code."
        #else
        "Choose a server on your network or enter its address to request approval. You can also use a pairing code or link."
        #endif
    }

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
            Button("Request to Connect") { beginRequestToConnect() }
                .buttonStyle(.borderedProminent)
                .disabled(address.isEmpty || isPairing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("request-to-connect")
            Button(showCodeForm ? "Hide pairing-code entry" : "Have a pairing code?") {
                showCodeForm.toggle()
            }
            .buttonStyle(.borderless)
            if showCodeForm {
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
    }

    private func beginRequestToConnect() {
        guard let endpoint = endpointURL else {
            errorMessage = "Enter a server address or choose one from Servers on your network."
            return
        }
        requestTask?.cancel()
        requestTask = Task { await requestToConnect(endpoint) }
    }

    private var endpointURL: URL? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    private func requestToConnect(_ endpoint: URL) async {
        isPairing = true
        errorMessage = nil
        defer {
            isPairing = false
            pendingRequestMessage = nil
            requestTask = nil
        }
        do {
            let fingerprint = try await server.presentedCertificateSHA256(at: endpoint)
            let secretBytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
            let secret = secretBytes.map { String(format: "%02x", $0) }.joined()
            let claimHash = SHA256.hash(data: Data(secretBytes)).map { String(format: "%02x", $0) }.joined()
            let client = APIClient(baseURL: endpoint, token: nil,
                                   session: PinnedCertificateDelegate.session(certificateSHA256: fingerprint))
            let created = try await client.createPairRequest(PairRequestCreate(
                deviceName: pairingDeviceName, platform: pairingPlatform, claimHash: claimHash))
            let matchCode = PairingMatchCode.compute(certificateSHA256: fingerprint, requestID: created.requestID,
                                                     claimHash: claimHash)
            let discoveredName = selectedServerAddress == endpoint ? selectedServer?.serverName : nil
            let serverName = discoveredName ?? endpoint.host ?? "SupersEmu Server"
            pendingRequestMessage = "Waiting for approval on \(serverName). Check that it shows code \(matchCode)."
            while !Task.isCancelled {
                do {
                    switch try await client.claimPairRequest(id: created.requestID, claimSecret: secret) {
                    case .pending:
                        try await Task.sleep(for: .seconds(2))
                    case .paired(let response):
                        try await server.pair(response: response, at: endpoint, certificateSHA256: fingerprint)
                        return
                    }
                } catch APIClientError.http(status: 403, _) {
                    errorMessage = "This connection request was denied."
                    return
                } catch APIClientError.http(status: 410, _) {
                    errorMessage = "This connection request expired. Start a new request."
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            recordDiagnostic(error, endpoint: endpoint)
        }
    }

    private var pairingDeviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    private var pairingPlatform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }

    private func recordDiagnostic(_ error: Error, endpoint: URL) {
        let diagnosis = ConnectionDiagnosis.from(error: error)
        errorMessage = diagnosis.message
        let nsError = error as NSError
        let httpStatus: String
        if let clientError = error as? APIClientError, case .http(let status, _) = clientError {
            httpStatus = "\(status)"
        } else {
            httpStatus = "none"
        }
        let info = Bundle.main.infoDictionary ?? [:]
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        let safeEndpoint = components?.string ?? "\(endpoint.scheme ?? "https")://\(endpoint.host ?? "unknown")"
        diagnostics = """
        timestamp: \(ISO8601DateFormatter().string(from: Date()))
        app: \(info["CFBundleShortVersionString"] ?? "unknown") (\(info["CFBundleVersion"] ?? "unknown"))
        endpoint: \(safeEndpoint)
        discovery source: \(selectedServerAddress == endpoint ? "Bonjour" : "manual")
        diagnosis: \(diagnosis)
        error: \(nsError.domain) \(nsError.code)
        HTTP status: \(httpStatus)
        """
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
            recordDiagnostic(error, endpoint: URL(string: "https://\(server.name).local")!)
        }
    }

    #if os(macOS)
    private func pairWithThisMac() async {
        await localServer.refresh()
        if localServer.health == nil {
            for candidate in [ServerModeModel.Source.daemon, .session] where candidate != localServer.source {
                localServer.source = candidate
                await localServer.refresh()
                if localServer.health != nil { break }
            }
        }
        guard localServer.health != nil else {
            address = localServer.localURL.absoluteString
            errorMessage = "No local server is running. Start one in Server Mode, or enter another server address below."
            return
        }
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
            if String(describing: error).contains("admin.token") {
                errorMessage = "Couldn't read this Mac's admin token. You can still enter a pairing code below."
            } else {
                recordDiagnostic(error, endpoint: localServer.localURL)
            }
        }
    }
    #endif

    private func pair(_ payload: PairingPayload) async {
        if payload.certificateSHA256 == nil,
           let url = payload.urls.first(where: { $0.scheme?.lowercased() == "https" }) {
            isPairing = true
            errorMessage = nil
            do {
                let fingerprint = try await server.presentedCertificateSHA256(at: url)
                fingerprintConfirmationPayload = payload
                fingerprintConfirmationValue = fingerprint
                showFingerprintConfirmation = true
            } catch {
                recordDiagnostic(error, endpoint: url)
            }
            isPairing = false
            return
        }
        await completePairing(payload)
    }

    private var fingerprintConfirmationMessage: String {
        guard let fingerprint = fingerprintConfirmationValue,
              let short = PairingFingerprint.short(certificateSHA256: fingerprint) else {
            return "The server's certificate fingerprint is unavailable."
        }
        return "Compare this with the fingerprint shown in Server Mode. Server fingerprint: \(short). The pairing code is sent only after you confirm."
    }

    private func completePairing(_ payload: PairingPayload, confirmedCertificateSHA256: String? = nil) async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            try await server.pair(payload, confirmedCertificateSHA256: confirmedCertificateSHA256)
        } catch {
            recordDiagnostic(error, endpoint: payload.urls.first ?? URL(string: "https://unknown")!)
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
