# Remote Desktop

A small, private remote desktop for two Macs: view and control one Mac from another over the internet.

- **rd-host** runs on the computer being controlled. It captures the screen with ScreenCaptureKit, encodes it with the hardware H.264 encoder and streams it.
- **rd-client** runs on the computer you sit at. It decodes the stream in hardware and shows it in a window.

## Security

- Traffic is encrypted with TLS using a pre-shared key (`TLS_PSK_WITH_AES_128_GCM_SHA256`). The key is derived (HKDF-SHA256) from a 256-bit random pairing secret, so only a client holding the secret can complete the handshake. No certificates are needed.
- The secret is stored in each Mac's login Keychain.
- Recommended network: put both Macs on [Tailscale](https://tailscale.com) and connect using the host's Tailscale name. Nothing needs to be opened on your router, and the stream gets a second layer of encryption. Don't port-forward 47800 to the internet.

## Requirements

- macOS 13 or later on both Macs
- Xcode or the Xcode Command Line Tools (`xcode-select --install`) to build

## Build

```sh
swift build -c release
# binaries land in .build/release/rd-host and .build/release/rd-client
swift test   # protocol and pairing tests
```

## First-time setup

On the host (the Mac you want to reach):

```sh
.build/release/rd-host pair     # prints a secret
.build/release/rd-host          # start sharing
```

The first run asks for two permissions for the app you run it from, such as Terminal. Allow both in System Settings > Privacy & Security, then run `rd-host` again:
- **Screen Recording**, to see the screen.
- **Accessibility**, to accept mouse and keyboard input. Without it the stream is view-only.

After each rebuild macOS may ask for your login password so the new binary can read the pairing secret from the Keychain. Choose **Always Allow**.

On the client (your MacBook):

```sh
.build/release/rd-client pair <secret from the host>
.build/release/rd-client connect <host's Tailscale name or IP>
```

Host options: `--port`, `--max-width` (default 2560), `--fps` (default 30), `--bitrate` in Mbps (default 8).

## Roadmap

1. **Live view:** screen stream, pairing, encrypted connection. ✅
2. **Control:** mouse, keyboard and scrolling from the client, injected on the host. ✅ Click into the client window to send it keystrokes; Command shortcuts like Cmd+C go to the remote Mac. Close the client with its window's close button.
3. Clipboard sync and choosing between multiple displays.
4. Polish: menu bar app for the host, start at login, auto-reconnect, quality settings.
