# Security

Seamline reads your keyboard and mouse on one Mac and replays them on another. That makes it a remote control for your Macs, so this page explains what it can do, how it protects the link, and how to report a problem.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through [GitHub's vulnerability reporting](https://github.com/mralifakbar/seamline/security/advisories/new) with steps to reproduce. You'll get a reply within a week, and a fix or a plan soon after that.

Only the latest release gets security fixes.

## What each Mac does

- **Host** (the Mac with the keyboard and mouse) installs an event tap while at least one paired Mac is connected. While the pointer is on this Mac, every event passes through unchanged. While it is on another Mac, the host swallows the events locally and sends them to that Mac.
- **Guest** listens on TCP and UDP port **47321** and advertises itself over Bonjour as `_seamline._tcp`. It posts mouse and keyboard events only for a Mac it has paired with, and only between that Mac's "pointer entered" and "pointer left" messages.

## How the link is protected

- **Pairing.** The two Macs run a Curve25519 commit-then-reveal handshake and each show a 6-digit code derived from the session transcript. Input is accepted only after a person confirms the code on **both** Macs. The commitment means an attacker in the middle gets one guess in a million per attempt.
- **Pinned keys.** After pairing, each Mac stores the other's public key. Later connections must present the same key, or they are treated as a new, unpaired Mac and have to be confirmed again.
- **Encryption.** Every frame, on both TCP and UDP, is sealed with ChaCha20-Poly1305 using per-direction counter nonces. Altered packets fail authentication and are dropped. On TCP the receive counter must match exactly, so a replayed frame fails too. On UDP a replayed packet has no effect: events are deduplicated by sequence number, and an old pointer position loses to a newer one.
- **Unpaired connections can't type.** Until both sides have confirmed, the guest drops every input message before it reaches the injector.

## What is stored

In `~/Library/Application Support/Seamline/`, readable only by your user account:

- `identity.json`: this Mac's ID and private key.
- `trusted.json`: the IDs, names and public keys of the Macs you paired with.

Select **Forget** next to a Mac to remove it. Deleting the folder resets Seamline to a fresh install.

## Clipboard

With **Share clipboard** on (the default), the host sends the current clipboard to a guest when the pointer moves there, and a guest sends its clipboard back when the pointer leaves, but only if something new was copied. The clipboard travels only to paired Macs, over the encrypted link. Turn it off in **Settings › Clipboard**.

## Known limits

- **Anyone who controls a paired Mac controls the other.** Pair only Macs you trust, and select **Forget** for a Mac you sell or give away.
- **The guest listens on every network interface,** including VPNs such as Tailscale, so it can be reached by address. Unpaired connections still need confirmation on both screens, but the port is visible to anyone on those networks.
- **Secure Input is respected.** When a password field or a secure terminal has Secure Input on, macOS hides keystrokes from Seamline, and typing stays on the host. Seamline shows which app holds it.
- **Release builds are ad-hoc signed and not notarized.** Check the SHA-256 on the release page, or build from source.
