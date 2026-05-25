import Foundation
import Testing
@testable import FramePipelineKit

@Suite struct StreamStateMutationTests {

    typealias K = StreamStateMutation.Key

    // MARK: - merging(needFramesInto:)

    @Test func needFramesPreservesNewClientConnected() {
        // The lived bug: source.startStream had just set newClientConnected = true,
        // then deviceSource.startStreaming triggered signalNeedFrames which
        // replaced the dict, wiping the flag before the app could observe it.
        let existing: [String: Any] = [
            K.newClientConnected: true,
            K.clientConnectedTime: 123.456
        ]
        let result = StreamStateMutation.merging(
            needFramesInto: existing,
            nowEpochSeconds: 999.0,
            pid: 42
        )
        #expect(result[K.newClientConnected] as? Bool == true)
        #expect(result[K.clientConnectedTime] as? TimeInterval == 123.456)
        #expect(result[K.streamActive] as? Bool == true)
        #expect(result[K.pid] as? Int32 == 42)
    }

    @Test func needFramesPreservesUnknownKeys() {
        let existing: [String: Any] = [
            "unrelated-flag": "value",
            K.streamActive: false  // overwritten
        ]
        let result = StreamStateMutation.merging(
            needFramesInto: existing,
            nowEpochSeconds: 1.0,
            pid: 1
        )
        #expect(result["unrelated-flag"] as? String == "value")
        #expect(result[K.streamActive] as? Bool == true)
    }

    @Test func needFramesHandlesNilExisting() {
        let result = StreamStateMutation.merging(
            needFramesInto: nil,
            nowEpochSeconds: 1.0,
            pid: 1
        )
        #expect(result[K.streamActive] as? Bool == true)
        #expect(result[K.pid] as? Int32 == 1)
    }

    // MARK: - merging(streamStoppedInto:)

    @Test func streamStoppedPreservesNewClientConnected() {
        let existing: [String: Any] = [
            K.streamActive: true,
            K.newClientConnected: true,
            K.clientConnectedTime: 5.0
        ]
        let result = StreamStateMutation.merging(
            streamStoppedInto: existing,
            nowEpochSeconds: 10.0
        )
        #expect(result[K.streamActive] as? Bool == false)
        #expect(result[K.newClientConnected] as? Bool == true)
        #expect(result[K.clientConnectedTime] as? TimeInterval == 5.0)
    }

    @Test func streamStoppedSurfacesObservableTransition() {
        // The previous behavior removed the dict entirely, which made the
        // app's `if let state = ...` guard early-return without ever seeing
        // streamActive flip from true→false. We need the false value present
        // so the app's observer fires its else branch.
        let existing: [String: Any] = [K.streamActive: true]
        let result = StreamStateMutation.merging(
            streamStoppedInto: existing,
            nowEpochSeconds: 0
        )
        #expect(result[K.streamActive] != nil)
        #expect(result[K.streamActive] as? Bool == false)
    }

    // MARK: - merging(newClientConnectedInto:)

    @Test func newClientConnectedDoesNotClearStreamActive() {
        let existing: [String: Any] = [K.streamActive: true]
        let result = StreamStateMutation.merging(
            newClientConnectedInto: existing,
            connectedAtEpochSeconds: 1.0
        )
        #expect(result[K.streamActive] as? Bool == true)
        #expect(result[K.newClientConnected] as? Bool == true)
        #expect(result[K.clientConnectedTime] as? TimeInterval == 1.0)
    }

    // MARK: - Compose: simulate the bug we fixed

    @Test func bugRepro_sequentialNewClientThenNeedFrames_preservesFlag() {
        // Order of operations inside SourceStreamSource.startStream:
        //   1. set newClientConnected=true (this function)
        //   2. deviceSource.startStreaming() → signalNeedFrames()
        // Step 2 must NOT clobber step 1's flag.
        let step1 = StreamStateMutation.merging(
            newClientConnectedInto: nil,
            connectedAtEpochSeconds: 100.0
        )
        let step2 = StreamStateMutation.merging(
            needFramesInto: step1,
            nowEpochSeconds: 101.0,
            pid: 9999
        )
        #expect(step2[K.newClientConnected] as? Bool == true,
                "newClientConnected must survive signalNeedFrames or the app can't see the edge")
        #expect(step2[K.streamActive] as? Bool == true)
        #expect(step2[K.pid] as? Int32 == 9999)
    }
}
