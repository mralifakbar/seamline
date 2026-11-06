# Contributing to Seamline

Thanks for helping out. This guide covers the setup, the layout of the code, and
what a good pull request looks like.

## Setup

You need macOS 13 or later and Xcode 16 or its Command Line Tools (Swift 6).

```sh
git clone https://github.com/mralifakbar/seamline.git
cd seamline
swift test                          # run the tests
./scripts/build-app.sh && open build/Seamline.app
```

Run the app from the bundle `build-app.sh` makes: macOS needs the `Info.plist` and a
stable signature for the Accessibility, Input Monitoring and Local Network prompts.

## Layout

```
Sources/
  SeamlineCore/   wire format, handshake, encrypted channel, geometry, layout,
                  Bonjour (no AppKit or SwiftUI here, so it's easy to test)
  Seamline/       event tap, input injection, cursor control, sessions, SwiftUI app
Tests/                   swift test: protocol, crypto, geometry, discovery and a real TCP loopback
scripts/build-app.sh     builds, signs and packages the .app (add --zip for a release zip)
scripts/make-icon.swift  draws the app icon
scripts/notarize.sh      notarizes and staples a Developer ID build
scripts/ci.sh            every check, run locally (there's no hosted CI)
scripts/release.sh       signs, notarizes and publishes a release from this Mac
docs/images/             README screenshots
```

## Development switches

Debug builds (`swift build`, then `.build/debug/Seamline`) read these:

| Switch | Effect |
|---|---|
| `SEAMLINE_SNAPSHOT_DIR=dir SEAMLINE_SCENARIO=host` | Show a screen with sample data, save it as PNG to `dir`, and quit. Scenarios: `role`, `permissions`, `host`, `host-remote`, `host-empty`, `pairing-host`, `guest`, `guest-controlled`, `pairing-guest`. Add `SEAMLINE_DARK=1` for dark mode. |
| `SEAMLINE_NAME="Mac Studio"` | Use this name instead of the Mac's real one, so screenshots don't show it. |
| `SEAMLINE_HOME=dir` | Keep the identity and paired Macs in `dir` instead of Application Support. |
| `SEAMLINE_AUTOPAIR=1` | Accept every pairing prompt and log each state change, for a two-machine test without clicking. |
| `SEAMLINE_BENCH=20` | After pairing, drive the link for 20 seconds and print latency percentiles. |
| `SEAMLINE_CONNECT=address` | Connect to that address on launch. |
| `SEAMLINE_SIGN_IDENTITY="…"` (build-app.sh) | Sign with that certificate instead of the first one in the keychain. |

The README screenshots are made like this:

```sh
SEAMLINE_NAME="Mac Studio" SEAMLINE_SNAPSHOT_DIR=/tmp/shots SEAMLINE_SCENARIO=host .build/debug/Seamline
```

## Reporting a bug

Open an issue with:

- The macOS version and Mac model on **both** sides (for example, Mac mini M4 on
  macOS 26 as host, MacBook Pro Intel on macOS 15 as guest).
- How the Macs are connected: same Wi-Fi, Ethernet, Tailscale.
- What you did, what you expected, and what happened.
- For a crash, the report from `~/Library/Logs/DiagnosticReports/Seamline-*.ips`.

## Pull requests

- Keep each PR focused on one thing, and describe what changed and how you tested it.
- `./scripts/ci.sh` must pass: unit tests, a universal build and a smoke test. There's
  no hosted CI, so run it on your Mac before opening the PR.
- Try the change on two real Macs if it touches input, discovery or the connection.
  Unit tests cover the protocol, but not the event tap or the injector.
- If the change affects what a screen looks like, regenerate the README screenshots
  and include them.
- Keep `SeamlineCore` free of AppKit and SwiftUI. Anything that can be unit tested
  belongs there, with a test.
- Nothing on the input path may block: the event tap thread and the connection queue
  never wait on the main thread.
- Interface text is short, in plain English, and names the next step when something
  is wrong. Debug-only helpers go behind `#if DEBUG`.
- Run `./scripts/ci.sh` before opening a PR. There's no hosted CI.
- Update `CHANGELOG.md` under **Unreleased**.

## Releasing (maintainers)

1. Move the **Unreleased** notes in `CHANGELOG.md` under a new version heading.
2. Commit, then run `./scripts/release.sh 0.2.0` on your Mac. There is no hosted CI:
   the script checks everything first, then runs the tests, builds the universal app
   signed with the Developer ID, notarizes and staples it, pushes `main` and the
   `v0.2.0` tag, and publishes the GitHub release with the zip, its SHA-256 and the
   changelog section as notes.
3. Once per Mac: the Developer ID Application certificate in the keychain, notarization
   credentials saved with `xcrun notarytool store-credentials notary …` (see the top of
   `scripts/notarize.sh`), and `gh auth login`.

By contributing, you agree that your work is released under the [MIT License](LICENSE).
