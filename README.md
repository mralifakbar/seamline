<p align="center"><img src="docs/images/icon.png" width="128" height="128" alt="Seamline icon: a desktop display and a laptop joined by a glowing line that ends in a pointer."></p>

<h1 align="center">Seamline</h1>

One keyboard and mouse for every Mac on your desk. Push the pointer past the edge of one screen and it shows up on the next Mac. Whatever you copied comes along.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/5-pointer-away-dark.png">
  <img src="docs/images/5-pointer-away.png" width="600" alt="Seamline's main window: Mac Studio sits next to a MacBook Air, which is highlighted because the pointer is on it. A banner says typing stays on this Mac while 1Password protects a password field.">
</picture>

- **Native.** Swift and SwiftUI, one universal app for Apple silicon and Intel, macOS 13 Ventura or later.
- **No setup server, no IP addresses.** Macs find each other over Bonjour. Tailscale and other VPNs work too.
- **Encrypted and paired.** Two Macs are linked only after you compare a 6-digit code on both screens.
- **Fast.** About 6 ms round trip over Wi-Fi between a Mac mini and a MacBook Pro (see [Measured](#measured)).
- **Clipboard follows the pointer.** Text, rich text, images, PDFs and links.

## Contents

- [Install](#install)
- [Set up](#set-up)
- [Daily use](#daily-use)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Measured](#measured)
- [Development](#development)
- [Known limits](#known-limits)

## Install

### Download

1. Download the latest **Seamline-x.y.z.zip** from [Releases](https://github.com/mralifakbar/seamline/releases), unzip it, and move **Seamline.app** to Applications. Do this on every Mac you want to use. The app runs on both Apple silicon and Intel Macs.
2. Open Seamline. Releases are signed with a Developer ID and notarized by Apple, so macOS opens it without a warning.
3. Continue with [Set up](#set-up).

> [!NOTE]
> macOS ties the Accessibility and Input Monitoring permissions to the app's signature. Releases from 0.1.1 on share one signature, so updates keep them. **Coming from 0.1.0**, which was signed ad-hoc, switch Seamline off and on again in both lists once. Check the SHA-256 on the release page if you want to be sure the zip is the one GitHub Actions built.

### Build from source

You need Xcode 16 or its Command Line Tools (Swift 6).

```sh
git clone https://github.com/mralifakbar/seamline.git
cd seamline
./scripts/build-app.sh                 # builds build/Seamline.app (Apple silicon + Intel)
cp -R build/Seamline.app /Applications/
```

To get the app onto another Mac, copy `build/Seamline.app` over (AirDrop, a shared folder, or `scp`) and put it in `/Applications` there. A build you copy yourself doesn't get the quarantine flag, so there is no Gatekeeper prompt.

> [!TIP]
> **Sign with your own certificate** if you have one, so the permissions survive rebuilds. The script uses the first `Apple Development` or `Developer ID Application` certificate in your keychain and lists them if there are several. Choose one with:
>
> ```sh
> SEAMLINE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
> ```

## Set up

Use one Mac as the **host**: the one with the keyboard and mouse you want to share. Every other Mac is a **guest**. Setup takes about a minute.

### 1. Choose a role on each Mac

Open Seamline. On the Mac with the keyboard and mouse, choose **This Mac**. On every other Mac, choose **Another Mac**.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/1-choose-role-dark.png">
  <img src="docs/images/1-choose-role.png" width="520" alt="Setup screen asking 'Which Mac has the keyboard and mouse?' with two choices: This Mac and Another Mac.">
</picture>

### 2. Allow the permissions

macOS asks before any app can read input or control the pointer. Select **Allow…** next to each permission, switch Seamline on in System Settings, then come back. The page updates by itself.

| Permission | Host | Guest | Why |
| --- | :---: | :---: | --- |
| Accessibility | ✓ | ✓ | Holds the pointer at the edge on the host, and clicks and types on the guest. |
| Input Monitoring | ✓ | | Reads the keyboard so keystrokes can go to the Mac the pointer is on. |
| Local Network | ✓ | ✓ | Lets the Macs find each other. macOS asks the first time Seamline searches. Select **Allow**. |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/2-permissions-dark.png">
  <img src="docs/images/2-permissions.png" width="520" alt="Permission screen on the host listing Accessibility and Input Monitoring, both allowed, with a Find Nearby Macs button.">
</picture>

Then select **Find Nearby Macs** on the host, or **Make This Mac Visible** on a guest.

### 3. Pair

On the host, the guest appears under **Nearby**. Select **Pair…** next to it. Both Macs then show the same 6-digit code. If the codes match, select **Pair** on the host and **Allow** on the guest.

<p>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/3-pair-host-dark.png">
  <img src="docs/images/3-pair-host.png" width="380" alt="Host pairing sheet: 'Pair with iMac', code 482 913, Cancel and Pair buttons.">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/3-pair-guest-dark.png">
  <img src="docs/images/3-pair-guest.png" width="380" alt="Guest pairing sheet: 'Mac Studio wants to control this Mac', the same code 482 913, Decline and Allow buttons.">
</picture>
</p>

You pair only once. After that, the two Macs reconnect by themselves whenever both are running Seamline, including after sleep.

### 4. Arrange the Macs to match your desk

The guest appears next to the host in the arrangement. Drag each Mac to the side where it sits on your desk. You can also select a Mac and move it with the arrow keys. The blue bar marks the edge the pointer crosses.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/4-arrangement-dark.png">
  <img src="docs/images/4-arrangement.png" width="600" alt="Arrangement canvas: Mac Studio (this Mac) with a MacBook Air to its right, connected at 6 ms, and an offline Mac mini below. An unpaired iMac is listed under Nearby.">
</picture>

That's it. Push the pointer past that edge and it moves to the other Mac.

## Daily use

- **Move between Macs.** Push the pointer past the shared edge. A little resistance stops accidental switches. Change it under **Settings › Edge resistance**. Screen corners never switch, so Hot Corners keep working.
- **Come back from anywhere.** Press <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>Esc</kbd>.
- **Copy and paste across Macs.** Copy on one Mac, move the pointer over, and paste. The clipboard travels when the pointer crosses, and only if it changed.
- **Pause sharing.** Use the **Sharing** switch in the window or the menu bar.
- **See the connection.** The menu bar shows each Mac with its measured round trip, for example `6 ms, Wi-Fi`.

<p>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/menu-bar-dark.png">
  <img src="docs/images/menu-bar.png" width="290" alt="Menu bar panel: pointer on this Mac, MacBook Air at 6 ms over Wi-Fi, Mac mini not available, a Share Keyboard and Mouse switch, Open Seamline, Settings, Quit.">
</picture>
</p>

On a guest, the window shows whether it is free or in use:

<p>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/guest-ready-dark.png">
  <img src="docs/images/guest-ready.png" width="380" alt="Guest window: 'Ready to be controlled', with the addresses to use from another network.">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/guest-controlled-dark.png">
  <img src="docs/images/guest-controlled.png" width="380" alt="Guest window: 'Controlled by Mac Studio', with how to return the pointer.">
</picture>
</p>

### Macs on different networks

If the guest is on another network, for example reachable only over Tailscale, Bonjour can't see it. On the host, select **Connect by Address…** and enter the address shown in the guest's window, such as `100.101.102.103` or `macbook.tailnet.ts.net`. Seamline remembers the address and reconnects by itself.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Seamline isn't in the **Input Monitoring** or **Accessibility** list | Select **Allow…** in Seamline's window, which adds it to the list. Or select **+** under the list in System Settings and choose Seamline from Applications. |
| The host keeps saying "Looking for Macs" | Check **System Settings › Privacy & Security › Local Network** on both Macs and switch Seamline on. Make sure the guest chose **Another Mac** and finished its setup. Both Macs must be on the same network, otherwise use **Connect by Address…**. |
| Permissions stopped working after a rebuild | The build was signed ad-hoc, so macOS treats it as a new app. Switch Seamline off and on again in both lists, or [sign with a certificate](#install). |
| Typing stays on the host while the pointer is on a guest | A password field or a secure terminal has turned on Secure Input, which hides keystrokes from every app. Seamline shows a banner naming the app. Leave that field and typing goes across again. |
| The pointer feels slow | The menu bar shows the measured round trip. Over Wi-Fi expect 5 to 10 ms. Wired Ethernet on one Mac removes one wireless hop. |

## How it works

| Part | Approach |
| --- | --- |
| Discovery | Bonjour (`_seamline._tcp`) over Wi-Fi, Ethernet and peer-to-peer Wi-Fi. No IP addresses to type. |
| Transport | Two encrypted paths on one port. UDP carries pointer motion (newest position wins) and a fast copy of every key, click and scroll. TCP carries a reliable copy of the same events, plus pairing and the clipboard. The receiver takes whichever copy lands first, exactly once and in order, so a lost Wi-Fi frame never stalls typing behind a TCP retransmit. Both use the Wi-Fi voice service class. |
| Loss repair | Every datagram also carries the events from the last 150 ms, so the next packet a few milliseconds later repairs a lost one. Clicks carry their own position, so a click never lands where the pointer used to be. |
| Radio warm-up | While the pointer is on another Mac, or heading toward one, a small probe goes out every 20 ms. It keeps both radios out of power save and measures the round trip shown next to each Mac. |
| Other networks | Connect by address to a Mac on another network, such as over Tailscale. The address is remembered and reconnects automatically. Peer-to-peer Wi-Fi is the last resort, because it time-shares the radio. |
| Pairing | Curve25519 commit-then-reveal handshake. Both Macs derive a 6-digit code from the session transcript. Because of the commitment, a man in the middle gets one guess in a million per attempt. |
| Encryption | ChaCha20-Poly1305 on every frame, with counter nonces per direction. Paired keys are pinned, so later sessions are authenticated without any prompt. |
| Pointer | The host taps input on a dedicated real-time thread, freezes its own cursor, and keeps a virtual cursor in the other Mac's display space using sub-pixel deltas. Edges are detected per display, so L-shaped multi-monitor setups have no dead zones. |
| Pointer rate | A leading-edge throttle at 250 Hz: the first movement leaves immediately, and a 1000 Hz mouse sends its newest position every 4 ms instead of flooding Wi-Fi airtime. If UDP is blocked, motion falls back to TCP. |
| Clipboard | Read only at the moment the pointer crosses, and only if it changed. No polling. Compressed with LZFSE when that helps, and sent as 60 KB slices on a bulk lane that never delays keystrokes. |
| Keyboard | Key codes are the same on every Mac, so keys travel as raw virtual key codes with modifier flags, autorepeat and keyboard type. Media and brightness keys are forwarded too. |
| Scrolling | Pixel deltas, scroll phase and momentum phase are forwarded, so trackpad scrolling and rubber-banding feel native on the other Mac. |

## Measured

Mac mini to MacBook Pro, both on 5 GHz Wi-Fi through one access point. 20 s at 125 Hz motion plus 20 events per second:

| Path | Round trip p50 | p90 | p99 | Motion packets lost |
| --- | --- | --- | --- | --- |
| Same network | 6.4 to 6.6 ms | 8.8 to 11.6 ms | 19.8 to 34.7 ms | 0 of 1,780 |
| Tailscale | 7.6 ms | 10.0 ms | 23.3 ms | 0 of 1,820 |

Plain `ping` on the same link averaged 7.8 ms, so Seamline adds no measurable overhead. The floor is the two Wi-Fi hops. Wired Ethernet on one side removes one of them.

### Tested on real hardware

Last end-to-end run: 2 November 2026, a Mac mini (M4, macOS 26.6) as host with two displays, and a MacBook Pro (2018, Intel, macOS 15.8) as guest, on the same Wi-Fi.

| Check | Result |
| --- | --- |
| Setup, permissions, Bonjour discovery and pairing with the 6-digit code | ✓ |
| Pointer crosses at the right edge of the host's second display and moves on the guest | ✓ |
| Typing on the host lands in TextEdit on the guest, including Shift and ⌘S | ✓ |
| ⌘⇧3 pressed on the host takes a screenshot on the guest | ✓ |
| Clipboard copied on the host is ready to paste on the guest, sent by Seamline rather than Universal Clipboard | ✓ |
| ⌃⌥⌘ Esc brings the pointer home | ✓ |
| Both Macs reconnect by themselves after Seamline restarts, without pairing again | ✓ |
| Round trip shown in the app | 7 to 25 ms over Wi-Fi |

## Development

```
Sources/SeamlineCore   Wire format, handshake, encrypted channel, geometry, layout, Bonjour (unit tested)
Sources/Seamline       Event tap, input injection, cursor control, sessions, SwiftUI interface
Tests                  swift test
scripts                build-app.sh (add --zip for a release zip), make-icon.swift (draws the app icon)
docs/images            README screenshots
.github/workflows      CI on every push, and a release build for every v* tag
```

```sh
swift test                             # protocol, crypto, geometry, discovery and a real TCP loopback
swift build                            # debug build at .build/debug/Seamline
```

Debug builds read a few environment variables:

| Variable | Effect |
| --- | --- |
| `SEAMLINE_SNAPSHOT_DIR=dir SEAMLINE_SCENARIO=host` | Shows a screen with sample data, saves it as PNG to `dir`, and quits. Scenarios: `role`, `permissions`, `host`, `host-remote`, `host-empty`, `pairing-host`, `guest`, `guest-controlled`, `pairing-guest`. Add `SEAMLINE_DARK=1` for dark mode. |
| `SEAMLINE_NAME="Mac Studio"` | Uses this name instead of the Mac's real one, so screenshots don't show it. |
| `SEAMLINE_HOME=dir` | Keeps the identity and paired Macs in `dir` instead of Application Support. |
| `SEAMLINE_AUTOPAIR=1` | Accepts every pairing prompt and logs each state change, for a two-machine test without clicking. |
| `SEAMLINE_BENCH=20` | After pairing, drives the link for 20 seconds and prints latency percentiles. |
| `SEAMLINE_CONNECT=address` | Connects to that address on launch. |

The README screenshots come from the snapshot mode:

```sh
SEAMLINE_NAME="Mac Studio" SEAMLINE_SNAPSHOT_DIR=/tmp/shots SEAMLINE_SCENARIO=host .build/debug/Seamline
```

### Releasing

Add the version to [CHANGELOG.md](CHANGELOG.md), then push a tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

GitHub Actions tests, builds the universal app, and publishes `Seamline-0.1.0.zip` with its SHA-256 on the Releases page. The release notes come from the changelog.

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security problem, see [SECURITY.md](SECURITY.md).

## Known limits

- Mac to Mac only. Windows and Linux are not supported.
- Files are not transferred. Copy and paste covers text, rich text, HTML, images, PDFs and URLs.
- The interface is in English only.

## License

MIT. See [LICENSE](LICENSE).
