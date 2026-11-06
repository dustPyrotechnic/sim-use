// SPDX-License-Identifier: Apache-2.0
#if canImport(HarmonyBackend)
import ArgumentParser
import Foundation
import HarmonyBackend
import SimUseCore
import Testing
@testable import SimUse

@Suite("Harmony device listing availability")
struct HarmonyDeviceListingTests {
    @Test("Harmony devices JSON exposes data.devices with unified rows", arguments: [false, true])
    func devicesJSONEnvelope(empty: Bool) throws {
        let serial = "TESTHARMONY000001"
        let devices = empty ? [] : [
            Device(udid: serial, name: serial, platform: .harmony, kind: .physical,
                   state: "device", runtime: "HarmonyOS"),
        ]
        let unifiedResult = Devices.ExecutionResult(devices: devices)
        let result: HarmonyDevicesCommand.ExecutionResult
        // Construct either result type so the original bare-array bug stays
        // a runtime encoding failure, not a mutation compile failure.
        do {
            result = try JSONDecoder().decode(HarmonyDevicesCommand.ExecutionResult.self,
                                             from: JSONEncoder().encode(unifiedResult))
        } catch {
            result = try JSONDecoder().decode(HarmonyDevicesCommand.ExecutionResult.self,
                                             from: JSONEncoder().encode(devices))
        }
        let encoded = try JSONEnvelopeWriter.encodeSuccess(result)
        let json = try JSONValue.decode(from: encoded)
        guard case .object(let envelope) = json,
              case .object(let data)? = envelope["data"],
              case .array(let rows)? = data["devices"] else {
            Issue.record("Expected data.devices array; received \(String(decoding: encoded, as: UTF8.self))")
            return
        }
        #expect(envelope["ok"] == .bool(true))
        #expect(rows == (empty ? [] : [.object([
            "deviceId": .string(serial), "name": .string(serial),
            "platform": .string("harmony"), "kind": .string("physical"),
            "state": .string("device"), "runtime": .string("HarmonyOS"),
        ])]))
        let unifiedJSON = try JSONValue.decode(from: JSONEnvelopeWriter.encodeSuccess(unifiedResult))
        #expect(json == unifiedJSON)
    }

    @Test("Absent hdc preserves the original three-backend failure summary")
    func absentTooling() async throws {
        let command = try Devices.parse([])
        let harmony = await command.listHarmony(isAvailable: false) {
            Issue.record("Missing hdc must be skipped without launching a listing")
            return []
        }
        guard case .skipped = harmony else {
            Issue.record("Missing hdc is neither a failed nor a successful empty listing")
            return
        }
        #expect(command.shouldWarnAllListingsFailed(
            ios: .failed, android: .failed, physicalIOS: .failed, harmony: harmony
        ))
        #expect(!command.shouldWarnAllListingsFailed(
            ios: .failed, android: .succeeded([]), physicalIOS: .failed, harmony: harmony
        ))
    }

    @Test("Available hdc with no connected devices suppresses the all-failed summary")
    func successfulEmptyListing() async throws {
        let command = try Devices.parse([])
        let harmony = await command.listHarmony(isAvailable: true) { [] }
        guard case .succeeded = harmony else {
            Issue.record("An available, empty Harmony listing must count as success")
            return
        }
        #expect(!command.shouldWarnAllListingsFailed(
            ios: .failed, android: .failed, physicalIOS: .failed, harmony: harmony
        ))
    }

    @Test("Available hdc listing failure participates in the all-failed summary")
    func failedListing() async throws {
        let command = try Devices.parse([])
        let harmony = await command.listHarmony(isAvailable: true) {
            throw HarmonyError("Fake hdc listing failed")
        }
        guard case .failed = harmony else {
            Issue.record("An hdc listing error must be reported as failure")
            return
        }
        #expect(command.shouldWarnAllListingsFailed(
            ios: .failed, android: .failed, physicalIOS: .failed, harmony: harmony
        ))
    }

    @Test("Platform-scoped listings never emit a global failure summary", arguments: [Device.Platform.ios, .android, .harmony])
    func scopedListing(platform: Device.Platform) async throws {
        let command = try Devices.parse(["--platform", platform.rawValue])
        #expect(!command.shouldWarnAllListingsFailed(
            ios: .failed, android: .failed, physicalIOS: .failed, harmony: .failed
        ))
        #expect(!command.shouldWarnAllListingsFailed(
            ios: .failed, android: .failed, physicalIOS: .failed, harmony: .skipped
        ))
        if platform != .harmony {
            let harmony = await command.listHarmony(isAvailable: true) {
                Issue.record("Other platform scopes must not invoke hdc")
                return []
            }
            guard case .skipped = harmony else {
                Issue.record("Harmony must be skipped outside its platform scope")
                return
            }
        }
    }

    @Test("Explicitly skipped physical iOS preserves existing summary behavior")
    func skippedPhysicalIOS() throws {
        let command = try Devices.parse(["--no-physical-ios"])
        #expect(!command.shouldWarnAllListingsFailed(
            ios: .failed, android: .failed, physicalIOS: .skipped, harmony: .skipped
        ))
    }

    @Test("Harmony devices rejects the removed no-op online flag")
    func removedOnlineFlag() throws {
        #expect(throws: (any Error).self) {
            try HarmonyCommand.parseAsRoot(["devices", "--online"])
        }
    }
}
#endif
