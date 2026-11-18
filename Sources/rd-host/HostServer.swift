import CoreVideo
import Foundation
import Network
import RDCore

/// Accepts one client at a time and streams the screen to it.
/// Everything here runs on `queue`, so no locking is needed.
final class HostServer {
    struct Config {
        var port: UInt16
        var maxWidth: Int
        var framesPerSecond: Int
        var bitrate: Int
    }

    /// Frames handed to the network but not yet sent. Above this we skip
    /// encoding new frames, so a slow link shows a lower frame rate instead
    /// of building up seconds of lag.
    private static let maxFramesInFlight = 3

    private let config: Config
    private let secret: PairingSecret
    private let queue = DispatchQueue(label: "rd.host", qos: .userInteractive)
    private var listener: NWListener?
    private var capturer: ScreenCapturer?
    private var encoder: VideoEncoder?

    private var client: FramedConnection?
    private var framesInFlight = 0
    private var needsKeyframe = true
    private var lastPixelBuffer: CVPixelBuffer?

    init(config: Config, secret: PairingSecret) {
        self.config = config
        self.secret = secret
    }

    func start() async throws {
        let capturer = ScreenCapturer(config: .init(maxWidth: config.maxWidth, framesPerSecond: config.framesPerSecond))
        capturer.onFrame = { [weak self] pixelBuffer in
            self?.queue.async { self?.handleCapturedFrame(pixelBuffer) }
        }
        capturer.onStop = { error in
            log("Screen capture stopped: \(error.localizedDescription)")
            exit(1)
        }
        try await capturer.start()
        self.capturer = capturer
        log("Capturing main display at \(capturer.width)x\(capturer.height), \(config.framesPerSecond) fps")

        let encoder = try VideoEncoder(config: .init(
            width: capturer.width, height: capturer.height,
            bitrate: config.bitrate, framesPerSecond: config.framesPerSecond))
        encoder.onPacket = { [weak self] packet in
            self?.queue.async { self?.send(packet) }
        }
        queue.sync { self.encoder = encoder }

        let listener = try NWListener(using: Transport.parameters(secret: secret),
                                      on: NWEndpoint.Port(rawValue: config.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("Listening on port \(self.config.port). Waiting for a client...")
            case .failed(let error):
                log("Listener failed: \(error)")
                exit(1)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let framed = FramedConnection(connection: connection, queue: queue)
        var greeted = false

        framed.onMessage = { [weak self, weak framed] type, payload in
            guard let self, let framed else { return }
            switch type {
            case .hello:
                guard let version = try? Hello.decode(payload), version == protocolVersion else {
                    log("Rejected \(framed.remoteDescription): unsupported protocol version")
                    framed.close()
                    return
                }
                greeted = true
                self.activate(framed)
            case .requestKeyframe:
                if framed === self.client { self.requestKeyframe() }
            case .videoFrame:
                break
            }
        }
        framed.onClose = { [weak self, weak framed] error in
            guard let self else { return }
            if let framed, framed === self.client {
                self.client = nil
                self.framesInFlight = 0
                log("Client disconnected\(error.map { ": \($0)" } ?? "")")
            }
        }
        framed.start()

        // Drop connections that complete TLS but never say hello.
        queue.asyncAfter(deadline: .now() + 10) { [weak framed] in
            if !greeted { framed?.close() }
        }
    }

    private func activate(_ connection: FramedConnection) {
        if let old = client, old !== connection {
            log("New client replaces the previous one")
            old.close()
        }
        client = connection
        framesInFlight = 0
        log("Client connected from \(connection.remoteDescription)")
        requestKeyframe()
    }

    // MARK: - Video pipeline

    private func requestKeyframe() {
        needsKeyframe = true
        // The screen may be idle (no new captures), so re-encode the last
        // frame right away rather than waiting for something to change.
        if let lastPixelBuffer { encodeIfPossible(lastPixelBuffer) }
    }

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer) {
        lastPixelBuffer = pixelBuffer
        encodeIfPossible(pixelBuffer)
    }

    private func encodeIfPossible(_ pixelBuffer: CVPixelBuffer) {
        guard client != nil, let encoder, framesInFlight < Self.maxFramesInFlight else { return }
        framesInFlight += 1
        let keyframe = needsKeyframe
        needsKeyframe = false
        encoder.encode(pixelBuffer, forceKeyframe: keyframe)
    }

    private func send(_ packet: VideoFramePacket?) {
        guard let packet else {
            // Encoder dropped this frame: free its slot and make sure the
            // next frame is a keyframe in case the dropped one was.
            framesInFlight = max(0, framesInFlight - 1)
            needsKeyframe = true
            return
        }
        guard let client else {
            framesInFlight = 0
            return
        }
        client.send(.videoFrame, packet.encoded()) { [weak self] in
            guard let self, self.client === client else { return }
            self.framesInFlight = max(0, self.framesInFlight - 1)
        }
    }
}

func log(_ message: String) {
    let time = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("[\(time)] \(message)")
    fflush(stdout)
}
