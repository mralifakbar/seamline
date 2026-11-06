# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- A new look that matches Panefold: grouped settings on soft cards with a caption under each setting, a menu bar panel with the app icon, a status dot and the sharing switch in its header, step dots and a button bar during setup, and keycaps for shortcuts. Everything works as before.

## [0.1.1] - 2026-11-03

### Changed

- Releases are signed with a Developer ID and notarized by Apple, so macOS opens Seamline without a warning, and updates keep the Accessibility and Input Monitoring permissions. Coming from 0.1.0, which was signed ad-hoc, switch Seamline off and on again in both lists once.
- `scripts/notarize.sh` notarizes and staples a signed build.
- `scripts/build-app.sh` stops with an error when the identity in `SEAMLINE_SIGN_IDENTITY` cannot sign, instead of falling back to ad-hoc.

## [0.1.0] - 2026-11-02

First public release.

### Added

- One keyboard and mouse across Macs: push the pointer past a screen edge to move to the next Mac, and press Control-Option-Command-Escape to come back from anywhere.
- Discovery over Bonjour, plus Connect by Address for Macs on another network such as Tailscale.
- Pairing with a 6-digit code confirmed on both Macs, pinned keys, and ChaCha20-Poly1305 on every frame.
- Dual-path transport: UDP for pointer motion and fast event copies, TCP as the reliable copy, with loss repair and radio warm-up.
- Clipboard sharing for text, rich text, HTML, images, PDFs and URLs.
- Arrangement canvas with drag and arrow-key placement, per-display edges and protected screen corners.
- Menu bar panel with live round-trip time per Mac, edge resistance setting, launch at login.
- App icon: a desktop display and a laptop joined by the pointer's path, drawn by `scripts/make-icon.swift`.
- Universal app for Apple silicon and Intel, macOS 13 or later.

### Fixed

- Seamline no longer crashes when it first sees another Mac over peer-to-peer Wi-Fi.
- **Allow…** for Input Monitoring now adds Seamline to the list in System Settings, so there is something to switch on.
- The host explains where to look when no Mac shows up, because macOS can block Local Network access without an error.
- The keyboard focus ring on the arrangement tiles hugs the tile instead of floating between Macs.

[Unreleased]: https://github.com/mralifakbar/seamline/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/mralifakbar/seamline/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mralifakbar/seamline/releases/tag/v0.1.0
