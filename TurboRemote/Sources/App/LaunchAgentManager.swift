import Foundation

enum LaunchAgentManager {
    private static let plistName = "com.turboproductions.turboremote.plist"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(plistName)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private static func install() {
        guard let appPath = Bundle.main.bundlePath as String? else { return }

        let plist: [String: Any] = [
            "Label": "com.turboproductions.turboremote",
            "ProgramArguments": ["\(appPath)/Contents/MacOS/TurboRemote"],
            "RunAtLoad": true,
            "KeepAlive": [
                "SuccessfulExit": false
            ],
        ]

        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
            print("[LaunchAgent] Installed at \(plistURL.path)")
        }
    }

    private static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
        print("[LaunchAgent] Removed")
    }
}
