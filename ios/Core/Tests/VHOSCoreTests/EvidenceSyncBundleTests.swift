import Foundation
import Testing

@testable import VHOSCore

@Test func evidenceSyncBundleRoundTripsChecksummedLogicalFrames() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth,
    sequence: 42,
    monotonicMicroseconds: 9_001,
    payload: Data("{\"contract\":\"gateway.health\"}".utf8)
  )
  let record = PortableLogicalFrame(
    frame: frame,
    sourceRole: .obdCAN,
    sourceID: "esp32-test",
    ingestedAt: "2026-08-17T12:00:00Z"
  )
  let archive = try EvidenceSyncBundle.encode(
    records: [record],
    creator: EvidenceBundleCreator(
      platform: "IOS",
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.1",
      deviceModel: "iPhone"
    ),
    bundleID: UUID(uuidString: "7EFEC738-4535-4C66-9EC5-64BDA8ED57FB")!,
    createdAt: "2026-08-17T12:00:00Z"
  )
  let imported = try EvidenceSyncBundle.decode(archive)

  #expect(imported.manifest.bundleID.uuidString == "7EFEC738-4535-4C66-9EC5-64BDA8ED57FB")
  #expect(imported.records == [record])
  #expect(try imported.records[0].validatedFrame() == frame)
}

@Test func evidenceSyncBundleRejectsTampering() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 2,
    payload: Data([1, 2, 3]))
  let record = PortableLogicalFrame(
    frame: frame, sourceRole: .obdCAN, sourceID: "esp32-test",
    ingestedAt: "2026-08-17T12:00:00Z")
  var archive = try EvidenceSyncBundle.encode(
    records: [record],
    creator: EvidenceBundleCreator(
      platform: "IOS", applicationID: "test", applicationVersion: "1", deviceModel: "test"))
  archive[80] ^= 0x01

  #expect(throws: EvidenceSyncError.self) { try EvidenceSyncBundle.decode(archive) }
}

@Test func evidenceSyncBundleImportsAndroidGoldenArchive() throws {
  let base64 =
    "UEsDBAoAAAgAAAAAIQB6RuMh4gEAAOIBAAANAAkAbWFuaWZlc3QuanNvblVUBQABAAAAAHsiY29udHJhY3QiOiJ2aG9zLmV2aWRlbmNlLXN5bmMtYnVuZGxlIiwiY29udHJhY3RfdmVyc2lvbiI6IjEuMC4wIiwiYnVuZGxlX2lkIjoiN2VmZWM3MzgtNDUzNS00YzY2LTllYzUtNjRiZGE4ZWQ1N2ZiIiwiY3JlYXRlZF9hdCI6IjIwMjYtMDgtMTdUMTI6MDA6MDBaIiwiY3JlYXRvciI6eyJwbGF0Zm9ybSI6IkFORFJPSUQiLCJhcHBsaWNhdGlvbl9pZCI6ImRldi52aG9zLmhlYWR1bml0IiwiYXBwbGljYXRpb25fdmVyc2lvbiI6IjAuMS4wIiwiZGV2aWNlX21vZGVsIjoiaGVhZC11bml0In0sInNlZ21lbnRzIjpbeyJwYXRoIjoic2VnbWVudHMvbG9naWNhbC1mcmFtZXMubmRqc29uIiwibWVkaWFfdHlwZSI6ImFwcGxpY2F0aW9uL3gtbmRqc29uIiwic2hhMjU2IjoiYzFlMDFkNGMyYzJiNzdhYmI2NTU0MzI2MzcxMmY2YjI1ZTgzNzM3ZGRjMWMxNmY2NWM4MGU0MTY3ZTlkZmVmMiIsImJ5dGVfY291bnQiOjQ3NywicmVjb3JkX2NvdW50IjoxfV19UEsDBAoAAAgAAAAAIQBnS0qx3QEAAN0BAAAeAAkAc2VnbWVudHMvbG9naWNhbC1mcmFtZXMubmRqc29uVVQFAAEAAAAAeyJjb250cmFjdCI6InZob3MucG9ydGFibGUtbG9naWNhbC1mcmFtZSIsImNvbnRyYWN0X3ZlcnNpb24iOiIxLjAuMCIsInNvdXJjZV9yb2xlIjoiT0JEX0NBTiIsInNvdXJjZV9pZCI6ImVzcDMyLXRlc3QiLCJzb3VyY2Vfc2VxdWVuY2UiOiI0MiIsInNvdXJjZV9tb25vdG9uaWNfbWljcm9zZWNvbmRzIjoiOTAwMSIsInByb3RvY29sX21ham9yIjoxLCJwcm90b2NvbF9taW5vciI6MCwibWVzc2FnZV90eXBlIjo0LCJmbGFncyI6MCwiaW5nZXN0ZWRfYXQiOiIyMDI2LTA4LTE3VDEyOjAwOjAwWiIsImVudmVsb3BlX3NoYTI1NiI6ImFmOGEyMWIwYTgwOTFiNjM3YTU2YjZlYmUxMGYwNGFlZmFkMWZmN2E0NDRlNzEyZjc5ZmI0ZjlhZThkMzQ4ZTIiLCJlbnZlbG9wZV9iYXNlNjQiOiJWa2hQVXdFQUJBQWRBQUFBS2dBQUFBQUFBQUFwSXdBQUFBQUFBQlo4WXdmVWJ4SGZleUpqYjI1MGNtRmpkQ0k2SW1kaGRHVjNZWGt1YUdWaGJIUm9JbjA9In0KUEsBAgoACgAACAAAAAAhAHpG4yHiAQAA4gEAAA0ACQAAAAAAAAAAAAAAAAAAAG1hbmlmZXN0Lmpzb25VVAUAAQAAAABQSwECCgAKAAAIAAAAACEAZ0tKsd0BAADdAQAAHgAJAAAAAAAAAAAAAAAWAgAAc2VnbWVudHMvbG9naWNhbC1mcmFtZXMubmRqc29uVVQFAAEAAAAAUEsFBgAAAAACAAIAmQAAADgEAAAAAA=="
  let archive = try #require(Data(base64Encoded: base64))
  let imported = try EvidenceSyncBundle.decode(archive)

  #expect(imported.manifest.creator.platform == "ANDROID")
  #expect(imported.records.count == 1)
  #expect(imported.records[0].sourceID == "esp32-test")
  #expect(imported.records[0].sourceSequence == "42")
}
