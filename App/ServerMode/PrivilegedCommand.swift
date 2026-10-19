#if os(macOS)
import Foundation
import SupersEmuKit

struct ProcessResult {
    var status: Int
    var stdout: String
    var stderr: String

    var lastMessage: String {
        (stderr + "\n" + stdout).split(whereSeparator: \.isNewline).last.map(String.init)
            ?? "Command failed (exit status \(status))."
    }
}

/// Runs shell commands as root through AppleScript's `with administrator privileges` prompt.
enum PrivilegedCommand {
    /// The status osascript reports when the user cancels the administrator prompt.
    static let userCancelledStatus = -128

    static func run(arguments: [String]) async -> ProcessResult {
        await run(shellCommand: shellCommand(arguments))
    }

    static func run(shellCommand: String) async -> ProcessResult {
        await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", appleScriptSource(shellCommand: shellCommand)])
    }

    /// osascript's own error code when it reported one, else the process status.
    static func exitStatus(of result: ProcessResult) -> Int {
        RemoteAccessChecks.osascriptExitStatus(stderr: result.stderr) ?? result.status
    }

    static func appleScriptSource(shellCommand: String) -> String {
        "do shell script \"\(appleScriptQuote(shellCommand))\" with administrator privileges"
    }

    static func shellCommand(_ arguments: [String]) -> String {
        arguments.map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Runs off the main thread. With `combinedOutput` stdout and stderr share one pipe, returned as `stdout`;
    /// otherwise stdout is discarded and stderr is captured unless `captureStderr` is false.
    static func runProcess(
        executableURL: URL,
        arguments: [String],
        combinedOutput: Bool = false,
        captureStderr: Bool = true
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = combinedOutput || captureStderr ? Pipe() : nil
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = combinedOutput ? pipe?.fileHandleForWriting : FileHandle.nullDevice
                process.standardError = pipe?.fileHandleForWriting ?? FileHandle.nullDevice
                do {
                    try process.run()
                    pipe?.fileHandleForWriting.closeFile()
                    let text = pipe.flatMap {
                        String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    } ?? ""
                    process.waitUntilExit()
                    let status = Int(process.terminationStatus)
                    continuation.resume(returning: combinedOutput
                        ? ProcessResult(status: status, stdout: text, stderr: "")
                        : ProcessResult(status: status, stdout: "", stderr: text))
                } catch {
                    continuation.resume(returning: ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription))
                }
            }
        }
    }
}

/// The macOS Application Firewall command-line tool.
enum Firewall {
    static let socketFilterPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    /// Adds the binary to the firewall and allows its incoming connections.
    static func allowShellCommand(binaryPath: String) -> String {
        PrivilegedCommand.shellCommand([socketFilterPath, "--add", binaryPath])
            + " && " + PrivilegedCommand.shellCommand([socketFilterPath, "--unblockapp", binaryPath])
    }

    /// nil when the firewall couldn't say.
    static func isBlocked(binaryPath: String) async -> Bool? {
        let result = await PrivilegedCommand.runProcess(
            executableURL: URL(fileURLWithPath: socketFilterPath),
            arguments: ["--getappblocked", binaryPath],
            combinedOutput: true)
        guard result.status == 0 else { return nil }
        let text = result.stdout.lowercased()
        return text.contains("blocked") && !text.contains("not blocked")
    }
}
#endif
