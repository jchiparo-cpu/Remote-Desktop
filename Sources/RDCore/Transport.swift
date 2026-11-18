import Foundation
import Network
import Security

public enum Transport {
    public static let defaultPort: UInt16 = 47800
    private static let pskIdentity = Data("remote-desktop-v1".utf8)

    /// TCP + TLS with a pre-shared key derived from the pairing secret.
    /// Both ends must hold the same secret or the handshake fails, which
    /// gives mutual authentication and encryption without certificates.
    public static func parameters(secret: PairingSecret) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = secret.derivedPSK().withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = pskIdentity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            psk as __DispatchData,
            identity as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10

        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// Wraps an NWConnection with the length-prefixed message framing from
/// Protocol.swift. All callbacks run on the queue passed to `init`.
public final class FramedConnection {
    public let connection: NWConnection
    public let queue: DispatchQueue
    public var onReady: (() -> Void)?
    public var onMessage: ((MessageType, Data) -> Void)?
    public var onClose: ((Error?) -> Void)?
    private var closed = false

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public var remoteDescription: String { "\(connection.endpoint)" }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveHeader()
            case .failed(let error):
                self.close(error)
            case .waiting(let error):
                // e.g. host unreachable or TLS rejected; don't retry forever.
                self.close(error)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ type: MessageType, _ payload: Data = Data(), completion: (() -> Void)? = nil) {
        guard !closed else { completion?(); return }
        var w = ByteWriter(capacity: payload.count + 5)
        w.u8(type.rawValue)
        w.u32(UInt32(payload.count))
        w.bytes(payload)
        connection.send(content: w.data, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error) }
            completion?()
        })
    }

    public func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
        onClose = nil
        onMessage = nil
        onReady = nil
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error { self.close(error); return }
            guard let data, data.count == 5 else {
                self.close(isComplete ? nil : ProtocolError("short header"))
                return
            }
            var r = ByteReader(data)
            let rawType = (try? r.u8()) ?? 0
            let length = Int((try? r.u32()) ?? 0)
            guard length <= maxPayloadSize else {
                self.close(ProtocolError("message too large: \(length) bytes"))
                return
            }
            if length == 0 {
                self.deliver(rawType, Data())
                self.receiveHeader()
            } else {
                self.receivePayload(rawType, length)
            }
        }
    }

    private func receivePayload(_ rawType: UInt8, _ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error { self.close(error); return }
            guard let data, data.count == length else {
                self.close(isComplete ? nil : ProtocolError("short payload"))
                return
            }
            self.deliver(rawType, data)
            self.receiveHeader()
        }
    }

    private func deliver(_ rawType: UInt8, _ payload: Data) {
        // Unknown message types are ignored for forward compatibility.
        guard let type = MessageType(rawValue: rawType) else { return }
        onMessage?(type, payload)
    }
}
