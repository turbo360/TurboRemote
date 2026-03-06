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

            // Open the downloaded file
            if assetName.hasSuffix(".dmg") {
                // Mount the DMG
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = [destPath.path]
                try process.run()
                process.waitUntilExit()
            } else if assetName.hasSuffix(".zip") {
                // Unzip and open
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", destPath.path, "-d", tempDir.path]
                try process.run()
                process.waitUntilExit()

                // Look for .app in extracted contents
                let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                if let app = contents.first(where: { $0.pathExtension == "app" }) {
                    // Move to Applications
                    let appDest = URL(fileURLWithPath: "/Applications/\(app.lastPathComponent)")
                    try? FileManager.default.removeItem(at: appDest)
                    try FileManager.default.moveItem(at: app, to: appDest)

                    // Relaunch
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    relaunch.arguments = ["-n", appDest.path]
                    try relaunch.run()

                    // Quit current app
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }

            isDownloading = false
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            isDownloading = false
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

            Text("This update is mandatory. Please install it to continue using Turbo Remote.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if updater.isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: updater.downloadProgress)
                        .frame(width: 200)
                    Text("Downloading...")
                        .font(.caption)
                }
            } else {
                Button("Install Update") {
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
