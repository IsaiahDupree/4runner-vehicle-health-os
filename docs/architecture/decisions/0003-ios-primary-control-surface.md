# ADR-0003: iOS is the primary mobile control surface

- Status: Accepted
- Date: 2026-08-16
- Supersedes: the PRD v0.1 assumption that Android is the first mobile implementation

## Decision

Build the first owner, engineering, capture, OTA, and AI-handoff client as a native iPhone app using SwiftUI, Core Bluetooth, CryptoKit, and local file/database storage. The immutable PRD remains preserved as v0.1; this ADR records the implementation change until a v0.2 PRD incorporates it.

The shared domain, gateway, capture, equation, and evidence contracts remain platform-neutral. Android can be added later without changing gateway authority or durable evidence formats.

## Consequences

- BLE is the routine control and streaming transport. Core Bluetooth state restoration and the `bluetooth-central` background mode support reconnection/event handling, but iOS background execution is bounded and cannot be treated as an always-running daemon.
- Wi-Fi is the bulk-transfer path for firmware images and large capture bundles. OTA must not depend on sustained high-throughput BLE.
- The app uses project-owned gateway frames and semantic commands. It never exposes a raw CAN-transmit API.
- AI integration starts as a signed/checksummed evidence handoff package. An AI provider remains optional and non-authoritative.
- Simulator, replay, and real gateway data implement the same source interface so product/domain behavior does not fork by transport.

## Platform baseline

- Minimum deployment target: iOS 17.0.
- Current build toolchain: Xcode 26.0.1, Swift 6.2, XcodeGen 2.45.4.
- Apple frameworks: SwiftUI, CoreBluetooth, CryptoKit, Foundation, UniformTypeIdentifiers, OSLog.

Apple requires `NSBluetoothAlwaysUsageDescription` for Core Bluetooth access. Background BLE operation uses the `bluetooth-central` mode and must be session-based, resilient to suspension, and state-restorable.

## References

- [Apple Core Bluetooth](https://developer.apple.com/documentation/corebluetooth)
- [Apple Bluetooth state restoration rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
- [Apple background Core Bluetooth guidance](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
