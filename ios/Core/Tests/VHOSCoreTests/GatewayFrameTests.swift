import Foundation
import Testing

@testable import VHOSCore

@Test func gatewayFrameRoundTripsAndStreamsAcrossChunks() throws {
  let first = GatewayFrame(
    messageType: .gatewayHealth, sequence: 7, monotonicMicroseconds: 42,
    payload: Data("health".utf8))
  let second = GatewayFrame(
    messageType: .experimentResult, sequence: 8, monotonicMicroseconds: 99,
    payload: Data("result".utf8))
  #expect(try GatewayFrame.decode(first.encoded()) == first)

  let combined = first.encoded() + second.encoded()
  var decoder = GatewayFrameStreamDecoder()
  #expect(try decoder.append(Data(combined.prefix(11))).isEmpty)
  #expect(try decoder.append(Data(combined.dropFirst(11))) == [first, second])
}

@Test func gatewayFrameRejectsCorruption() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 1, payload: Data([1, 2, 3]))
  var corrupted = frame.encoded()
  corrupted[GatewayFrame.headerLength] ^= 0xFF
  #expect(throws: GatewayFrameError.self) {
    try GatewayFrame.decode(corrupted)
  }
}
