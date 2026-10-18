#if os(macOS)
import ServiceManagement
import SupersEmuKit

struct ServerMenuStatus: Equatable {
    enum State: Equatable {
        case running
        case needsApproval
        case notRunning
        case off
    }

    let state: State
    let title: String
    let detail: String
    let symbolName: String
    let sessionStoppedUnexpectedly: Bool

    static let daemonDetail = "Boot server · port \(LocalServerConstants.daemonPort)"
    static let sessionDetail = "This session only · port \(LocalServerConstants.sessionPort)"

    init(
        daemonStatus: SMAppService.Status,
        sessionRunning: Bool,
        health: HealthResponse?,
        deviceCount: Int,
        sessionStoppedUnexpectedly: Bool = false
    ) {
        self.sessionStoppedUnexpectedly = sessionStoppedUnexpectedly
        if health != nil {
            state = .running
            if daemonStatus == .enabled {
                let devices = deviceCount == 1 ? "1 device" : "\(deviceCount) devices"
                detail = "\(Self.daemonDetail) · \(devices)"
            } else {
                detail = Self.sessionDetail
            }
        } else if daemonStatus == .requiresApproval {
            state = .needsApproval
            detail = "Approve the server in Login Items"
        } else if sessionStoppedUnexpectedly {
            state = .notRunning
            detail = "Server stopped unexpectedly"
        } else if daemonStatus == .enabled || sessionRunning {
            state = .notRunning
            detail = daemonStatus == .enabled ? Self.daemonDetail : Self.sessionDetail
        } else {
            state = .off
            detail = "Start a server for this session"
        }

        switch state {
        case .running:
            title = "SupersEmu Server: Running"
            symbolName = "server.rack"
        case .needsApproval:
            title = "SupersEmu Server: Needs approval in Login Items"
            symbolName = "exclamationmark.triangle"
        case .notRunning:
            title = "SupersEmu Server: Not responding"
            symbolName = "exclamationmark.triangle"
        case .off:
            title = "SupersEmu Server: Off"
            symbolName = "exclamationmark.triangle"
        }
    }
}
#endif
