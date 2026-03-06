# Turbo Remote — Project Guide

## What is this?
macOS native point-to-point H.265 screen sharing app for colour-accurate remote video/photo editing. Built with Swift 5.10+, SwiftUI, Metal, VideoToolbox, and Network.framework.

## Project Structure

```
TurboRemote/
├── .github/workflows/build-release.yml   # CI: tag → build → DMG → GitHub Release
├── .gitignore
├── Secrets.example.swift                  # Template for Secrets.swift (committed)
├── TurboRemote_Spec_v3.docx              # Full product specification
└── TurboRemote/                           # XcodeGen project root
    ├── project.yml                        # XcodeGen spec — regenerates .xcodeproj
    ├── Info.plist
    ├── TurboRemote.entitlements           # Non-sandboxed (sandbox = false)
    └── Sources/
        ├── App/
        │   ├── TurboRemoteApp.swift       # Entry point: PIN gate → mode select → host/client
        │   ├── AutoUpdater.swift          # Mandatory GitHub Releases update checker
        │   └── Secrets.swift              # GITIGNORED — contains PIN, never committed
        ├── Host/
        │   ├── ScreenCaptureManager.swift # ScreenCaptureKit wrapper (Display P3, Retina)
        │   ├── H265Encoder.swift          # VideoToolbox HEVC encoder, multi-profile
        │   ├── FrameDeltaAnalyzer.swift   # Metal compute shader for frame diff analysis
        │   ├── HostServer.swift           # Network server (QUIC→TLS+TCP→TCP fallback)
        │   └── HostView.swift             # Host UI + ProfileSelector + HostManager
        ├── Client/
        │   ├── StreamClient.swift         # Network client with auto-reconnect
        │   ├── H265Decoder.swift          # VideoToolbox HEVC decoder
        │   ├── MetalRenderer.swift        # Metal rendering with colour management + EDR
        │   └── ClientView.swift           # Client UI + HUD + ClientManager
        ├── Shared/
        │   ├── FramePacket.swift          # Binary packet serialization (19-byte header)
        │   ├── EncodingProfile.swift      # ConnectionMode, QualityLevel, ControlMessage
        │   ├── ColourPipeline.swift       # Colour space detection + transform params
        │   ├── TLSIdentityManager.swift   # Self-signed X.509 cert (CryptoKit P-256)
        │   ├── PassphraseManager.swift    # 4-word passphrase generator + Keychain
        │   └── BonjourService.swift       # mDNS discovery (_turboremote._tcp)
        ├── Shaders/
        │   ├── Shaders.metal             # Vertex, passthrough, colour-managed fragment
        │   └── DeltaCompute.metal        # Frame delta compute kernel
        └── Assets.xcassets/
            └── AppIcon.appiconset/       # App icon at 128/256/512/1024
```

## Build Commands

```bash
cd TurboRemote

# Generate Xcode project (required after adding/removing source files)
xcodegen generate

# IMPORTANT: XcodeGen overwrites entitlements to empty dict every time.
# After every xcodegen generate, restore the entitlements manually or
# the build will use an empty entitlements file (may cause issues).

# Build
xcodebuild -project TurboRemote.xcodeproj -scheme TurboRemote -configuration Debug build
```

## Secrets & Security

**The repo is PUBLIC.** Never commit credentials.

- `Secrets.swift` is **gitignored** — contains `Secrets.appPin` (the PIN code)
- To build locally, copy `Secrets.example.swift` → `TurboRemote/Sources/App/Secrets.swift` and fill in the real PIN
- GitHub Actions uses the `APP_PIN` repository secret to inject the PIN at build time
- Apple Developer Team ID: set as GitHub secret, not in code
- No passwords, API keys, or credentials should ever appear in source files

## XcodeGen Gotchas

- The `.xcodeproj` is gitignored — it's generated from `project.yml`
- **Every `xcodegen generate` overwrites `TurboRemote.entitlements`** to an empty `<dict/>`. You must restore `com.apple.security.app-sandbox = false` after each run.
- New source files are only picked up after re-running `xcodegen generate`
- Metal shaders (`.metal` files) are included via the `Sources` directory glob

## Releasing a New Version

1. Update `MARKETING_VERSION` in `project.yml`
2. Commit and push
3. Tag and push:
   ```bash
   git tag v1.0.1
   git push --tags
   ```
4. GitHub Actions automatically: builds → packages DMG → creates GitHub Release
5. All running app instances detect the update on next launch (mandatory, cannot skip)

## Architecture

### Transport
QUIC (preferred) → TLS 1.3 + TCP (fallback) → plain TCP (last resort). Port 7420. Bonjour discovery via `_turboremote._tcp`.

### Encoding Pipeline (Host)
ScreenCaptureKit → GPU delta analysis → ProfileSelector (hysteresis) → VideoToolbox H.265 → FramePacket → Network send

### Decoding Pipeline (Client)
Network receive → FramePacket parse → VideoToolbox H.265 decode → Metal render (colour-managed, EDR-aware)

### Connection Modes
| Mode | Bitrate | Use case |
|------|---------|----------|
| Studio | Uncapped | LAN, lossless |
| Broadband | 80 Mbps | Fast internet |
| Mobile | 30 Mbps | Slower connections |
| Low BW | 10 Mbps | Minimal bandwidth |

### Quality Levels
Lossless → High Quality → Quality → Low BW → Skipped (no change detected)

ProfileSelector uses hysteresis: immediate downgrade on motion, 3-frame delay before upgrading back. Prevents quality thrashing.

### Colour Pipeline
Captures in Display P3. Metal shaders handle sRGB↔P3↔Rec.2020 conversion with proper OETF/EOTF gamma. EDR headroom scaling on HDR displays.

## Key Decisions
- Non-sandboxed app (needs ScreenCaptureKit + network server access)
- Self-signed TLS certs via CryptoKit + manual DER encoding (no openssl dependency)
- Passphrase auth via SHA-256 hash over the wire
- `UnsafeMutablePointer<Int>` for cross-thread bandwidth counter (avoids Swift concurrency warnings)
- `SWIFT_STRICT_CONCURRENCY: minimal` to reduce noise from VideoToolbox/Metal callback patterns
