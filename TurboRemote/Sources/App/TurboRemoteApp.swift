import SwiftUI

@main
struct TurboRemoteApp: App {
    @State private var isUnlocked = false
    @State private var mode: AppMode = .selection
    @StateObject private var updater = AutoUpdater.shared

    var body: some Scene {
        WindowGroup {
            if updater.updateAvailable {
                MandatoryUpdateView(updater: updater)
            } else if !isUnlocked {
                PinGateView(isUnlocked: $isUnlocked)
            } else {
                switch mode {
                case .selection:
                    ModeSelectionView(mode: $mode)
                case .host:
                    HostView()
                case .client:
                    ClientView()
                }
            }
        }
        .windowResizability(mode == .client && isUnlocked ? .automatic : .contentSize)

        Settings {
            SettingsView()
        }
    }

    init() {
        // Check for updates on launch
        Task { @MainActor in
            await AutoUpdater.shared.checkForUpdates()
        }
    }
}

enum AppMode {
    case selection
    case host
    case client
}

struct PinGateView: View {
    @Binding var isUnlocked: Bool
    @State private var pin = ""
    @State private var shake = false
    @FocusState private var focused: Bool

    private let correctPin = Secrets.appPin

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Turbo Remote")
                .font(.title2.bold())

            SecureField("Enter PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .multilineTextAlignment(.center)
                .focused($focused)
                .onSubmit { checkPin() }

            Button("Unlock") { checkPin() }
                .buttonStyle(.borderedProminent)
                .disabled(pin.isEmpty)
        }
        .padding(40)
        .frame(width: 300, height: 250)
        .offset(x: shake ? -8 : 0)
        .animation(.default.repeatCount(3, autoreverses: true).speed(6), value: shake)
        .onAppear { focused = true }
    }

    private func checkPin() {
        if pin == correctPin {
            isUnlocked = true
        } else {
            pin = ""
            shake.toggle()
        }
    }
}

struct ModeSelectionView: View {
    @Binding var mode: AppMode

    var body: some View {
        VStack(spacing: 24) {
            Text("Turbo Remote")
                .font(.largeTitle.bold())

            Text("Point-to-Point Screen Sharing")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 40)

            HStack(spacing: 30) {
                modeButton(
                    title: "Host",
                    subtitle: "Share this screen",
                    icon: "display",
                    color: .blue
                ) {
                    mode = .host
                }

                modeButton(
                    title: "Client",
                    subtitle: "View remote screen",
                    icon: "laptopcomputer",
                    color: .green
                ) {
                    mode = .client
                }
            }
        }
        .padding(40)
        .frame(width: 450, height: 300)
    }

    private func modeButton(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 150, height: 140)
            .background(color.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            HostSettingsView()
                .tabItem { Label("Host", systemImage: "display") }
            ClientSettingsView()
                .tabItem { Label("Client", systemImage: "laptopcomputer") }
        }
        .frame(width: 450, height: 350)
    }
}

struct HostSettingsView: View {
    @AppStorage("maxBandwidthMbps") private var maxBandwidth: Double = 0
    @AppStorage("losslessThreshold") private var losslessThreshold: Double = 2.0
    @AppStorage("connectionPort") private var port: Int = 7420
    @AppStorage("autoStartOnLogin") private var autoStart = false
    @AppStorage("permitRemoteInput") private var permitRemoteInput = true
    @AppStorage("showRemoteIndicator") private var showRemoteIndicator = true

    var body: some View {
        Form {
            Section("Encoding") {
                HStack {
                    Text("Max bandwidth (0 = uncapped)")
                    Spacer()
                    TextField("Mbps", value: $maxBandwidth, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Lossless threshold (%)")
                    Spacer()
                    TextField("%", value: $losslessThreshold, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Network") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $port, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Remote Input") {
                Toggle("Permit remote keyboard & mouse", isOn: $permitRemoteInput)
                Toggle("Show indicator when controlled", isOn: $showRemoteIndicator)
            }

            Section("System") {
                Toggle("Start on login", isOn: $autoStart)

                HStack {
                    Text("Passphrase")
                    Spacer()
                    Text(PassphraseManager.getOrCreatePassphrase())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
    }
}

struct ClientSettingsView: View {
    @AppStorage("defaultMode") private var defaultMode: Int = 0
    @AppStorage("showHUDOverlay") private var showHUD = true
    @AppStorage("colourSpaceOverride") private var colourOverride: Int = -1
    @AppStorage("motionAdvisory") private var motionAdvisory = true

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Default mode", selection: $defaultMode) {
                    Text("Studio").tag(0)
                    Text("Broadband").tag(1)
                    Text("Mobile").tag(2)
                    Text("Low BW").tag(3)
                }
            }

            Section("Display") {
                Toggle("Show HUD overlay", isOn: $showHUD)
                Toggle("Motion advisory in Mobile mode", isOn: $motionAdvisory)

                Picker("Colour space override", selection: $colourOverride) {
                    Text("Native (auto-detect)").tag(-1)
                    Text("sRGB").tag(0)
                    Text("Display P3").tag(1)
                    Text("Rec. 2020").tag(2)
                }
            }
        }
        .padding()
    }
}
