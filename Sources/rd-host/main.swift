import CoreGraphics
import Foundation
import RDCore

let usage = """
Usage:
  rd-host pair                 Create a new pairing secret (replaces any old one)
  rd-host [options]            Start sharing this screen

Options:
  --port N        Port to listen on (default \(Transport.defaultPort))
  --max-width N   Scale the stream down to at most N pixels wide (default 2560)
  --fps N         Frames per second (default 30)
  --bitrate N     Target bitrate in megabits per second (default 8)
"""

var args = Array(CommandLine.arguments.dropFirst())

if args.first == "pair" {
    let secret = PairingSecret.generate()
    do {
        try SecretStore.save(secret, role: .host)
    } catch {
        print("Could not save the secret to the Keychain: \(error)")
        exit(1)
    }
    print("""
    New pairing secret saved. On your MacBook, run:

      rd-client pair \(secret.displayString)

    Treat it like a password: anyone with it can connect to this computer.
    Running `rd-host pair` again creates a new secret and locks out old clients.
    """)
    exit(0)
}

if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}

var config = HostServer.Config(port: Transport.defaultPort, maxWidth: 2560, framesPerSecond: 30, bitrate: 8_000_000)
while !args.isEmpty {
    let flag = args.removeFirst()
    guard let value = args.first.flatMap(Int.init), value > 0 else {
        print("Missing or invalid value for \(flag)\n\n\(usage)")
        exit(2)
    }
    args.removeFirst()
    switch flag {
    case "--port" where value <= 65535: config.port = UInt16(value)
    case "--max-width": config.maxWidth = value
    case "--fps" where value <= 120: config.framesPerSecond = value
    case "--bitrate": config.bitrate = value * 1_000_000
    default:
        print("Unknown or out-of-range option \(flag)\n\n\(usage)")
        exit(2)
    }
}

guard let secret = SecretStore.load(role: .host) else {
    print("No pairing secret yet. Run `rd-host pair` first.")
    exit(1)
}

if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    print("""
    Screen Recording permission is needed. Allow it in
    System Settings > Privacy & Security > Screen Recording for the app you
    are running rd-host from (e.g. Terminal), then run rd-host again.
    """)
    exit(1)
}

if !InputInjector.checkPermission(prompt: true) {
    print("""
    Note: remote mouse and keyboard need Accessibility permission. macOS should
    show a prompt; allow the app you run rd-host from (e.g. Terminal) in
    System Settings > Privacy & Security > Accessibility, then restart rd-host.
    Screen viewing works without it.
    """)
}

let server = HostServer(config: config, secret: secret)
Task {
    do {
        try await server.start()
    } catch {
        log("Failed to start: \(error.localizedDescription)")
        exit(1)
    }
}
dispatchMain()
