#if os(macOS)
import AppKit
import SwiftUI

/// Server Mode › Remote Access: public HTTPS at a hostname like games.supersemu.com so devices can play away from home.
struct RemoteAccessView: View {
    @Bindable var model: RemoteAccessModel
    let serverMode: ServerModeModel

    var body: some View {
        Form {
            statusSection
            switch model.phase {
            case .off:
                setupSection
            case .turningOn(let steps):
                stepsSection(steps, title: "Turning on")
            case .on(let status):
                onSection(status)
            case .error(let problem, let steps):
                problemSection(problem)
                if let steps { stepsSection(steps, title: "Progress") }
                setupSection
            }
        }
        .formStyle(.grouped)
        .task {
            model.attach(serverMode: serverMode)
            await model.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                await model.refresh()
            }
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    if model.isOn {
                        Text("On — \(model.publicURLText)").foregroundStyle(.green).textSelection(.enabled)
                    } else {
                        Text(model.summary).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Remote Access")
        } footer: {
            Text("Play from anywhere: your devices connect to \(model.host) when they're away from home Wi-Fi.")
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .on: return .green
        case .turningOn: return .orange
        case .error: return .red
        case .off: return .secondary
        }
    }

    private var setupSection: some View {
        Section {
            TextField("Hostname", text: $model.host, prompt: Text(RemoteAccessModel.defaultHost))
                .textContentType(.URL)
                .disabled(model.busy)
            tokenRows
            HStack(spacing: 10) {
                Button(isRetry ? "Try Again" : "Turn On") { Task { await model.turnOn() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canTurnOn)
                Text("Asks for your Mac password once").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Set up")
        } footer: {
            Text("Turning on installs a small HTTPS server (Caddy) that only forwards player requests. Admin controls stay on your home network.")
        }
    }

    @ViewBuilder private var tokenRows: some View {
        if model.needsTokenEntry {
            SecureField("Cloudflare API token", text: $model.pastedToken, prompt: Text("Paste token"))
                .disabled(model.busy)
            VStack(alignment: .leading, spacing: 4) {
                Text("Use the \"Edit zone DNS\" template, limited to the supersemu.com zone only. It's saved on this Mac for the server and never shown again.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Link("Create a token in Cloudflare…", destination: RemoteAccessModel.cloudflareTokensURL)
                    if model.isOn {
                        Button("Save Token") { Task { await model.turnOn() } }
                            .disabled(!model.canTurnOn)
                    }
                    if model.replacingToken {
                        Button("Keep Saved Token") { model.replacingToken = false; model.pastedToken = "" }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
        } else {
            savedTokenRow
        }
    }

    private var savedTokenRow: some View {
        LabeledContent("Cloudflare API token") {
            HStack(spacing: 8) {
                Label("Token saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Replace…") { model.replacingToken = true }
                    .controlSize(.small)
                    .disabled(model.busy)
            }
        }
    }

    private var isRetry: Bool { if case .error = model.phase { return true } else { return false } }

    private func stepsSection(_ steps: [RemoteAccessStep: RemoteAccessStepState], title: String) -> some View {
        Section(title) {
            ForEach(RemoteAccessStep.allCases) { step in
                HStack(spacing: 10) {
                    StepIcon(state: steps[step] ?? .pending).frame(width: 18)
                    Text(step.title).foregroundStyle((steps[step] ?? .pending) == .pending ? .secondary : .primary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func onSection(_ status: RemoteAccessStatus) -> some View {
        Section {
            LabeledContent("Public IP", value: status.publicIP ?? "Unknown")
            tokenRows
            LabeledContent("DNS last updated", value: Self.relative(status.dnsUpdatedAt))
            LabeledContent("Certificate valid until") {
                Text(status.certificateValidUntil.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown")
            }
            LabeledContent("Last outside check") {
                HStack(spacing: 6) {
                    switch status.lastOutsideCheck {
                    case .reachable?:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Reachable · \(Self.relative(status.lastOutsideCheckAt))")
                    case .unverifiedFromInside?:
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("Couldn't verify from inside your network · \(Self.relative(status.lastOutsideCheckAt))")
                    case .failed(let reason)?:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(reason) · \(Self.relative(status.lastOutsideCheckAt))")
                    case nil:
                        Text("Not checked yet").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Check Now") { Task { await model.checkNow() } }
                    .disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(role: .destructive) { Task { await model.turnOff() } } label: {
                    Text("Turn Off").foregroundStyle(.red)
                }
                .disabled(model.busy)
            }
        } header: {
            Text("Details")
        } footer: {
            Text("This Mac updates the DNS record every 5 minutes if your home IP changes. Turning off also asks for your Mac password.")
        }
    }

    private func problemSection(_ problem: RemoteAccessProblem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(problem.title, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(problem.fix)
                switch problem {
                case .caddyMissing(let homebrewInstalled):
                    if homebrewInstalled {
                        HStack {
                            Button("Install Caddy") { Task { await model.installCaddy() } }
                                .disabled(model.busy)
                            Text("Runs brew install caddy").font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    } else {
                        Link("Get Homebrew at brew.sh", destination: RemoteAccessModel.homebrewURL)
                    }
                default:
                    EmptyView()
                }
            }
            .padding(.vertical, 4)
        }
    }

    static func relative(_ date: Date?) -> String {
        date.map { $0.formatted(.relative(presentation: .named)) } ?? "Never"
    }
}

private struct StepIcon: View {
    let state: RemoteAccessStepState

    var body: some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
#endif
