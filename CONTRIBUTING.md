# Contributing to Seamline

Thanks for helping. Bug reports, fixes and small focused features are all welcome.

## Reporting a bug

Open an issue with:

- The macOS version and Mac model on **both** sides (for example, Mac mini M4 on macOS 26 as host, MacBook Pro Intel on macOS 15 as guest).
- How the Macs are connected: same Wi-Fi, Ethernet, Tailscale.
- What you did, what you expected, and what happened.
- For a crash, the report from `~/Library/Logs/DiagnosticReports/Seamline-*.ips`.

## Making a change

1. Fork the repository and create a branch.
2. Build and test:

   ```sh
   swift test
   ./scripts/build-app.sh
   ```

3. Try the change on two real Macs if it touches input, discovery or the connection. Unit tests cover the protocol, but not the event tap or the injector.
4. If the change affects what a screen looks like, regenerate the README screenshots (see **Development** in the README) and include them.
5. Open a pull request that says what changed and how you tested it.

## Guidelines

- Keep `SeamlineCore` free of AppKit and SwiftUI. Anything that can be unit tested belongs there, with a test.
- Nothing on the input path may block: the event tap thread and the connection queue never wait on the main thread.
- Interface text is short, in plain English, and names the next step when something is wrong.
- Debug-only helpers go behind `#if DEBUG`.

By contributing, you agree that your work is released under the [MIT License](LICENSE).
