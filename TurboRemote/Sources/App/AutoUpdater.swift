import Foundation
import SwiftUI

@MainActor
final class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    @Published var updateAvailable = false
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var latestVersion = ""
    @Published var releaseNotes = ""
    @Published var errorMessage: String?

    private let currentVersion: String
    private let repoOwner = "turbo360"
    private let repoName = "TurboRemote"

    private init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var releaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    func checkForUpdates() async {
        isChecking = true
        errorMessage = nil

        defer { isChecking = false }

        do {
            var request = URLRequest(url: releaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return }

            if httpResponse.statusCode == 404 {
                // No releases yet
                return
            }

            guard httpResponse.statusCode == 200 else {
                errorMessage = "GitHub API returned \(httpResponse.statusCode)"
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            latestVersion = remoteVersion
            releaseNotes = (json["body"] as? String) ?? ""

            if isNewerVersion(remote: remoteVersion, local: currentVersion) {
                updateAvailable = true

                // Find .dmg or .zip asset
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           (name.hasSuffix(".dmg") || name.hasSuffix(".zip")) {
                            // Asset found — ready for download
                            break
                        }
                    }
                }
            }
        } catch {
            errorMessage = "Update check failed: \(error.localizedDescription)"
        }
    }

    func downloadAndInstall() async {
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            var request = URLRequest(url: releaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else {
                errorMessage = "Could not parse release assets"
                isDownloading = false
                return
            }

            // Find downloadable asset (.dmg preferred, .zip fallback)
            var downloadURL: URL?
            var assetName = ""

            for asset in assets {
                guard let name = asset["name"] as? String,
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString) else { continue }

                if name.hasSuffix(".dmg") {
                    downloadURL = url
                    assetName = name
                    break
                } else if name.hasSuffix(".zip") && downloadURL == nil {
                    downloadURL = url
                    assetName = name
                }
            }

            guard let url = downloadURL else {
                errorMessage = "No downloadable asset found in release"
                isDownloading = false
                return
            }

            // Download to temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let destPath = tempDir.appendingPathComponent(assetName)

            // Clean up any previous download
            try? FileManager.default.removeItem(at: destPath)

            let (fileURL, _) = try await URLSession.shared.download(from: url)
            try FileManager.default.moveItem(at: fileURL, to: destPath)

            downloadProgress = 1.0

            if assetName.hasSuffix(".dmg") {
                try await installFromDMG(destPath)
            } else if assetName.hasSuffix(".zip") {
                try await installFromZip(destPath, tempDir: tempDir)
            }

            isDownloading = false
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            isDownloading = false
        }
    }

    // MARK: - Install from DMG (silent mount, copy, unmount, relaunch)

    private func installFromDMG(_ dmgPath: URL) async throws {
        // Mount DMG silently
        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mount.arguments = ["attach", dmgPath.path, "-nobrowse", "-quiet", "-mountrandom", "/tmp"]
        let mountPipe = Pipe()
        mount.standardOutput = mountPipe
        try mount.run()
        mount.waitUntilExit()

        let mountOutput = String(data: mountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Find mount point from hdiutil output (last column of last line)
        guard let mountPoint = mountOutput
            .components(separatedBy: .newlines)
            .last(where: { !$0.isEmpty })?
            .components(separatedBy: "\t")
            .last?
            .trimmingCharacters(in: .whitespaces),
              !mountPoint.isEmpty else {
            errorMessage = "Could not mount DMG"
            return
        }

        defer {
            // Unmount DMG
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-quiet", "-force"]
            try? detach.run()
            detach.waitUntilExit()
        }

        // Find .app in mounted volume
        let mountURL = URL(fileURLWithPath: mountPoint)
        let contents = try FileManager.default.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil)
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            errorMessage = "No .app found in DMG"
            return
        }

        replaceAndRelaunch(newApp: appBundle)
    }

    // MARK: - Install from ZIP

    private func installFromZip(_ zipPath: URL, tempDir: URL) async throws {
        let extractDir = tempDir.appendingPathComponent("TurboRemote_update")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", zipPath.path, "-d", extractDir.path]
        try unzip.run()
        unzip.waitUntilExit()

        let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            errorMessage = "No .app found in ZIP"
            return
        }

        replaceAndRelaunch(newApp: appBundle)
    }

    // MARK: - Replace current app and relaunch

    private func replaceAndRelaunch(newApp: URL) {
        // Determine where the current app lives
        let currentAppPath = Bundle.main.bundlePath
        let currentAppURL = URL(fileURLWithPath: currentAppPath)
        let appName = currentAppURL.lastPathComponent
        let parentDir = currentAppURL.deletingLastPathComponent()

        // Destination is same location as current app
        let destURL = parentDir.appendingPathComponent(appName)

        // Use a shell script to: wait for us to quit → replace app → relaunch
        let script = """
        #!/bin/bash
        sleep 1
        rm -rf "\(destURL.path)"
        cp -R "\(newApp.path)" "\(destURL.path)"
        open "\(destURL.path)"
        rm -f /tmp/turboremote_update.sh
        """

        let scriptPath = "/tmp/turboremote_update.sh"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [scriptPath]
        try? launcher.run()

        // Quit current app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func isNewerVersion(remote: String, local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(remoteParts.count, localParts.count)
        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

// MARK: - Mandatory Update View

struct MandatoryUpdateView: View {
    @ObservedObject var updater: AutoUpdater

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Update Required")
                .font(.title2.bold())

            Text("Version \(updater.latestVersion) is available.")
                .font(.subheadline)

            if !updater.releaseNotes.isEmpty {
                ScrollView {
                    Text(updater.releaseNotes)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(.horizontal)
            }

            Text("This update is mandatory and will install automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if updater.isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: updater.downloadProgress)
                        .frame(width: 200)
                    Text(updater.downloadProgress < 1.0 ? "Downloading..." : "Installing...")
                        .font(.caption)
                }
            } else {
                Button("Update Now") {
                    Task { await updater.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let error = updater.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)

                Button("Retry") {
                    Task { await updater.downloadAndInstall() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(30)
        .frame(width: 380, height: 420)
        .interactiveDismissDisabled()
    }
}
