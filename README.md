# Seamline

One keyboard and mouse for every Mac on your desk. Push the pointer past the edge of one screen and it shows up on the next Mac; what you copied comes along with it.

Native Swift and SwiftUI. Universal binary for Apple silicon and Intel. macOS 13 Ventura or later.

## Build

```sh
./scripts/build-app.sh        # universal Seamline.app in ./build
swift test                    # protocol, crypto, geometry and a real TCP loopback
```

The script signs with your first `Apple Development` or `Developer ID Application` certificate. Pick a specific one with `SEAMLINE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"`. Sign with a real identity: macOS ties the Accessibility and Input Monitoring grants to the signature, so an ad-hoc build loses them on every rebuild. If the keychain is locked the script falls back to ad-hoc and says so.

## Setup

1. Open Seamline on the Mac with the keyboard and mouse and choose **This Mac**. Allow Accessibility and Input Monitoring.
2. Open Seamline on each other Mac and choose **Another Mac**. Allow Accessibility.
3. On the first Mac, select **Pair…** next to the other Mac. Both screens show the same six digits; confirm on both.
4. Drag the Macs in the arrangement to match your desk.

`⌃⌥⌘ Esc` brings the pointer home from anywhere.

## How it works

| Part | Approach |
| --- | --- |
| Discovery | Bonjour (`_seamline._tcp`) over Wi-Fi, Ethernet and peer-to-peer Wi-Fi. No IP addresses to type. |
| Transport | Two encrypted paths on one port. UDP carries pointer motion (newest position wins) and a fast copy of every key, click and scroll; TCP carries a reliable copy of the same events plus pairing and clipboard. The receiver takes whichever copy lands first, exactly once and in order, so a lost Wi-Fi frame never stalls typing behind a TCP retransmit. Both use the Wi-Fi voice service class. |
| Loss repair | Every datagram also carries the events from the last 150 ms, so one lost packet is repaired by the next one a few milliseconds later. Clicks carry their own position, so a click never lands where the pointer used to be. |
| Radio warm-up | While the pointer is on another Mac, or heading toward one, a small probe goes out every 20 ms. It keeps both radios out of power save and measures the real round trip shown next to each Mac. |
| Other networks | Connect by address for Macs on another network, such as over Tailscale. The address is remembered and reconnects automatically. Peer-to-peer Wi-Fi stays available as a fallback, but the shared network is preferred because peer-to-peer time-shares the radio. |
| Pairing | Curve25519 commit-then-reveal handshake. Both Macs derive a 6-digit code from the session transcript. The commitment means a man in the middle gets one guess in a million per attempt. |
| Encryption | ChaCha20-Poly1305 on every frame, counter nonces per direction. Paired keys are pinned, so later sessions are authenticated without any prompt. |
| Pointer | The host taps input on a dedicated real-time thread, freezes its own cursor, and keeps a virtual cursor in the other Mac's display space using sub-pixel deltas. Edges are detected per display, so L-shaped multi-monitor setups have no dead zones. Screen corners never switch, so Hot Corners keep working. |
| Pointer rate | A leading-edge throttle at 250 Hz: the first movement leaves immediately; a 1000 Hz mouse sends its newest position every 4 ms instead of flooding Wi-Fi airtime. If UDP is blocked, motion falls back to TCP, where moves still merge under backpressure. |
| Clipboard | Read only at the moment the pointer crosses, and only if it changed. No polling. Compressed with LZFSE when that helps, sent as 60 KB slices on a bulk lane that never delays keystrokes. |
| Keyboard | Mac-to-Mac key codes are identical, so keys travel as raw virtual key codes with modifier flags, autorepeat and keyboard type. Media and brightness keys are forwarded too. |
| Scrolling | Pixel deltas, scroll phase and momentum phase are forwarded, so trackpad scrolling and rubber-banding feel native on the other Mac. |

Secure Input (password fields, some terminals) hides keystrokes from every app that reads input. When that happens Seamline names the app holding it instead of silently typing on the wrong Mac.

## Measured

Mac mini to MacBook Pro, both on 5 GHz Wi-Fi through one access point, 20 s at 125 Hz motion plus 20 events per second:

| Path | Round trip p50 | p90 | p99 | Motion packets lost |
| --- | --- | --- | --- | --- |
| Same network | 6.4 to 6.6 ms | 8.8 to 11.6 ms | 19.8 to 34.7 ms | 0 of 1,780 |
| Tailscale | 7.6 ms | 10.0 ms | 23.3 ms | 0 of 1,820 |

Plain `ping` on the same link averaged 7.8 ms, so Seamline adds no measurable overhead; the floor is the two Wi-Fi hops. A wired Ethernet connection on one side removes one of them.

## Layout

```
Sources/SeamlineCore   Wire format, handshake, encrypted channel, geometry, layout, Bonjour (unit tested)
Sources/Seamline       Event tap, input injection, cursor control, sessions, SwiftUI interface
Tests                swift test
scripts              build-app.sh
```

## Known limits

- Mac to Mac only. Windows and Linux are not supported.
- Files are not transferred; copy and paste covers text, rich text, HTML, images, PDFs and URLs.
- The app icon is the system default until a real icon is designed.
- The in-app text is English only.

## License

MIT. See [LICENSE](LICENSE).
