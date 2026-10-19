#if os(macOS)
/// Fixed identifiers of the Mac's local server: the boot daemon, the per-session server and the installed app.
enum LocalServerConstants {
    static let daemonLabel = "com.chadillac6.supersemu.server"
    static let daemonPlistName = "\(daemonLabel).plist"
    static let daemonPort = 8487
    static let sessionPort = 8488
    static let installedAppPath = "/Applications/SupersEmu.app"
    static let installedServerBinaryPath = "\(installedAppPath)/Contents/MacOS/supersemu-server"
}
#endif
