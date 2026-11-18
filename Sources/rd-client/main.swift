import AppKit
import Foundation
import Network
import RDCore

let usage = """
Usage:
  rd-client pair <secret>          Save the secret printed by `rd-host pair`
  rd-client connect <host> [port]  Connect to a host (Tailscale name or IP)
"""

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "pair":
    guard args.count >= 2, let secret = PairingSecret(string: args.dropFirst().joined()) else {
        print("That doesn't look like a valid secret. Copy the whole value printed by `rd-host pair`.")
        exit(2)
    }
    do {
        try SecretStore.save(secret, role: .client)
        print("Paired. Now run: rd-client connect <host>")
        exit(0)
    } catch {
        print("Could not save the secret to the Keychain: \(error)")
        exit(1)
    }

case "connect":
    guard args.count >= 2 else { print(usage); exit(2) }
    let host = args[1]
    var port = Transport.defaultPort
    if args.count >= 3 {
        guard let p = UInt16(args[2]), p > 0 else { print("Invalid port \(args[2])"); exit(2) }
        port = p
    }
    guard let secret = SecretStore.load(role: .client) else {
        print("Not paired yet. Run `rd-host pair` on the host, then `rd-client pair <secret>` here.")
        exit(1)
    }
    let app = NSApplication.shared
    let delegate = ClientController(host: host, port: port, secret: secret)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()

default:
    print(usage)
    exit(args.isEmpty ? 0 : 2)
}

/// Owns the window and the connection to the host.
final class ClientController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let host: String
    private let port: UInt16
    private let secret: PairingSecret
    private let queue = DispatchQueue(label: "rd.client", qos: .userInteractive)
    private var window: NSWindow!
    private var videoView: VideoView!
    private var connection: FramedConnection?
    private var sizedToVideo = false

    init(host: String, port: UInt16, secret: PairingSecret) {
        self.host = host
        self.port = port
        self.secret = secret
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        videoView = VideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window = NSWindow(contentRect: videoView.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.contentView = videoView
        window.delegate = self
        window.title = "Connecting to \(host)..."
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        videoView.onNeedKeyframe = { [weak self] in
            guard let self else { return }
            self.queue.async { self.connection?.send(.requestKeyframe) }
        }
        videoView.onVideoSize = { [weak self] size in self?.fit(to: size) }

        connect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        queue.sync { connection?.close() }
    }

    private func connect() {
        let nw = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                              using: Transport.parameters(secret: secret))
        let framed = FramedConnection(connection: nw, queue: queue)
        framed.onReady = { [weak self, weak framed] in
            framed?.send(.hello, Hello.encode())
            DispatchQueue.main.async { self?.window.title = "Remote Desktop: \(self?.host ?? "")" }
        }
        framed.onMessage = { [weak self] type, payload in
            guard type == .videoFrame, let packet = try? VideoFramePacket.decode(payload) else { return }
            DispatchQueue.main.async { self?.videoView.display(packet) }
        }
        framed.onClose = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                let reason = error.map { "\($0)" } ?? "closed by host"
                self.window.title = "Disconnected from \(self.host) (\(reason))"
            }
        }
        connection = framed
        framed.start()
    }

    /// Size the window to the stream's aspect ratio, fitting the screen.
    private func fit(to videoSize: CGSize) {
        window.contentAspectRatio = videoSize
        guard !sizedToVideo, let screen = window.screen ?? NSScreen.main else { return }
        sizedToVideo = true
        let visible = screen.visibleFrame.size
        let scale = min(visible.width * 0.9 / videoSize.width, visible.height * 0.9 / videoSize.height, 1)
        window.setContentSize(NSSize(width: videoSize.width * scale, height: videoSize.height * scale))
        window.center()
    }
}
