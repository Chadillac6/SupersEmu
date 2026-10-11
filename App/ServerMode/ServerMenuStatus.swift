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

    init(daemonStatus: SMAppService.Status, sessionRunning: Bool, health: HealthResponse?, deviceCount: Int) {
        if health != nil {
            state = .running
            if daemonStatus == .enabled {
                let devices = deviceCount == 1 ? "1 device" : "\(deviceCount) devices"
                detail = "Boot server · port 8487 · \(devices)"
            } else {
                detail = "This session only · port 8488"
            }
        } else if daemonStatus == .requiresApproval {
            state = .needsApproval
            detail = "Approve the server in Login Items"
        } else if daemonStatus == .enabled || sessionRunning {
            state = .notRunning
            detail = daemonStatus == .enabled ? "Boot server · port 8487" : "This session only · port 8488"
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
