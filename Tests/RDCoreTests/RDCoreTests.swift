import XCTest
@testable import RDCore

final class RDCoreTests: XCTestCase {
    func testSecretRoundTripsThroughDisplayString() {
        let secret = PairingSecret.generate()
        XCTAssertEqual(PairingSecret(string: secret.displayString), secret)
        XCTAssertEqual(PairingSecret(string: secret.displayString.uppercased()), secret)
        XCTAssertEqual(PairingSecret(string: " " + secret.displayString.replacingOccurrences(of: "-", with: " ")), secret)
    }

    func testSecretRejectsBadInput() {
        XCTAssertNil(PairingSecret(string: "1234"))
        let valid = PairingSecret.generate().displayString
        XCTAssertNil(PairingSecret(string: valid + "00"))
        XCTAssertNil(PairingSecret(string: "zz" + valid.dropFirst(2)))
    }

    func testDerivedPSKIsStableAndDistinct() {
        let a = PairingSecret.generate()
        let b = PairingSecret.generate()
        XCTAssertEqual(a.derivedPSK(), a.derivedPSK())
        XCTAssertNotEqual(a.derivedPSK(), b.derivedPSK())
        XCTAssertEqual(a.derivedPSK().count, 32)
        XCTAssertNotEqual(a.derivedPSK(), a.bytes)
    }

    func testVideoPacketRoundTrip() throws {
        let keyframe = VideoFramePacket(
            isKeyframe: true, presentationTimeMicros: 123_456_789,
            parameterSets: [Data([0x67, 1, 2, 3]), Data([0x68, 4])],
            avccData: Data([0, 0, 0, 2, 0x65, 9]))
        XCTAssertEqual(try VideoFramePacket.decode(keyframe.encoded()), keyframe)

        let delta = VideoFramePacket(isKeyframe: false, presentationTimeMicros: 1,
                                     parameterSets: [], avccData: Data([0, 0, 0, 1, 0x41]))
        XCTAssertEqual(try VideoFramePacket.decode(delta.encoded()), delta)
    }

    func testDecodingSlicedDataWorks() throws {
        // Network buffers are often Data slices with a non-zero startIndex.
        let packet = VideoFramePacket(isKeyframe: true, presentationTimeMicros: 7,
                                      parameterSets: [Data([1, 2])], avccData: Data([3, 4, 5]))
        let padded = Data([0xFF, 0xFF]) + packet.encoded()
        XCTAssertEqual(try VideoFramePacket.decode(padded.dropFirst(2)), packet)
    }

    func testTruncatedPacketThrows() {
        let encoded = VideoFramePacket(isKeyframe: true, presentationTimeMicros: 1,
                                       parameterSets: [Data([1, 2, 3])], avccData: Data()).encoded()
        XCTAssertThrowsError(try VideoFramePacket.decode(encoded.prefix(10)))
    }

    func testHello() throws {
        XCTAssertEqual(try Hello.decode(Hello.encode()), protocolVersion)
        XCTAssertThrowsError(try Hello.decode(Data([1])))
    }
}
