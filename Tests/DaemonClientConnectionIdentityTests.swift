// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import ArgumentParser
import Darwin
import Foundation
import Testing

// Coverage for the request-level connection gate on the real
// `DaemonClient.invoke` path.
//
// The `_ping` gate restarts a daemon started for another connection,
// but its probe times out after 2 s. The daemon serves one connection
// at a time, so a busy daemon makes the probe inconclusive, and the
// business request used to run in that daemon anyway — against the
// adb server of the client that started it. Every business request now
// carries the identity `invoke` read at entry, and the daemon refuses
// one that does not match its own.

// MARK: - Fixtures

private func makeTempDirectory() throws -> URL {
    // Short /tmp path: sockaddr_un.sun_path is ~104 bytes.
    let dir = URL(fileURLWithPath: "/tmp/sim-use-ci-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The connection identity the test's client currently computes for one
/// UDID. Read by `DaemonClient.connectionIdentityProvider` from whatever
/// thread runs `invoke`, so it is lock-protected.
private final class ClientConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String?) { self.value = value }

    var identity: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

@MainActor
private enum SlowCommandState {
    static var executeCount = 0
    static var started = false
    static var duration: TimeInterval = 0
    static var failuresRemaining = 0

    static func reset(duration: TimeInterval, failures: Int = 0) {
        executeCount = 0
        started = false
        self.duration = duration
        failuresRemaining = failures
    }
}

/// Daemon-dispatchable command that runs for `SlowCommandState.duration`
/// and fails with a `transient_booting` message `failuresRemaining` times.
private struct FakeSlowCommand: SimUseExecutableCommand {
    struct Payload: Codable { var value: String }
    typealias ExecutionResult = Payload

    static let configuration = CommandConfiguration(commandName: "fake-slow")

    var jsonOutput: Bool { false }

    func execute() async throws -> Payload {
        let (duration, fail) = await MainActor.run {
            SlowCommandState.executeCount += 1
            SlowCommandState.started = true
            let fail = SlowCommandState.failuresRemaining > 0
            if fail { SlowCommandState.failuresRemaining -= 1 }
            return (SlowCommandState.duration, fail)
        }
        if duration > 0 {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
        if fail {
            // Message shape matches DaemonErrorKind.classify's
            // transient_booting detection.
            throw CLIError(errorDescription: "Simulator is unavailable as it is not booted")
        }
        return Payload(value: "ok")
    }

    func format(_ result: Payload) -> CommandOutput { .line(result.value) }
}

// MARK: - Suite

// Serialised: DaemonServer installs process-wide signal sources, and the
// suite swaps the process-global command parser and identity provider.
@Suite("DaemonClient.invoke connection identity", .serialized)
@MainActor
struct DaemonClientConnectionIdentityTests {
    enum TestError: Error { case daemonNeverReady, commandNeverStarted }

    private func startTestDaemon(
        udid: String,
        connectionIdentity: String,
        baseDirectory: URL
    ) async throws -> (DaemonPaths, Task<Void, Error>) {
        let paths = DaemonPaths(udid: udid, baseDirectory: baseDirectory)
        try paths.ensureBaseDirectory()
        let server = DaemonServer(udid: udid, idleTimeout: 30, paths: paths, connectionIdentity: connectionIdentity)
        let task = Task { try await server.run() }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: paths.socketURL.path),
               paths.readPidfile() != nil {
                return (paths, task)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        throw TestError.daemonNeverReady
    }

    /// Install a provider that answers for `udid` only, so concurrently
    /// running suites (which use other UDIDs) keep their identities.
    private func withClientConnection(
        _ connection: ClientConnection,
        udid: String,
        body: () async throws -> Void
    ) async rethrows {
        let saved = DaemonClient.connectionIdentityProvider
        DaemonClient.connectionIdentityProvider = { candidate, platform in
            candidate == udid ? connection.identity : saved?(candidate, platform)
        }
        defer { DaemonClient.connectionIdentityProvider = saved }
        try await body()
    }

    private func waitUntilCommandStarted() async throws {
        for _ in 0..<250 {
            if SlowCommandState.started { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestError.commandNeverStarted
    }

    @Test("A request whose identity probe times out behind a busy daemon is refused, not run")
    func busyDaemonRefusesOtherConnection() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let udid = "emulator-\(Int.random(in: 5554...5680))"
        try await withExclusiveCommandParser({ _ in FakeSlowCommand() }) {
            let (paths, task) = try await startTestDaemon(udid: udid, connectionIdentity: "adb=A", baseDirectory: tmp)
            defer { task.cancel() }
            let pidBefore = paths.readPidfile()

            // Longer than the 2 s `_ping` timeout, so B's probe is inconclusive.
            SlowCommandState.reset(duration: 3.5)
            let connection = ClientConnection("adb=A")

            try await withClientConnection(connection, udid: udid) {
                let requestA = Task {
                    try await DaemonClient.invoke(command: "fake-slow", args: [], udid: udid, baseDirectory: tmp)
                }
                try await waitUntilCommandStarted()

                connection.identity = "adb=B"
                do {
                    _ = try await DaemonClient.invoke(command: "fake-slow", args: [], udid: udid, baseDirectory: tmp)
                    Issue.record("B's request must not run in A's daemon")
                } catch let error as DaemonClientError {
                    guard case .remote(let message, let kind, let hint) = error else {
                        Issue.record("expected .remote, got \(error)")
                        return
                    }
                    #expect(kind == .permanent)
                    #expect(message.contains("different device connection"))
                    #expect(!message.contains("adb=A") && !message.contains("adb=B"))
                    #expect(hint?.contains("daemon stop --udid \(udid)") == true)
                }

                // A's request was not disturbed.
                _ = try await requestA.value
            }

            #expect(SlowCommandState.executeCount == 1)
            // The probe was inconclusive, so the daemon was not restarted.
            #expect(paths.readPidfile() == pidBefore)

            await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
            _ = try? await task.value
        }
    }

    @Test("The transient_booting retry carries the identity read at invoke entry")
    func retryKeepsEntryIdentity() async throws {
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let udid = "emulator-\(Int.random(in: 5554...5680))"
        try await withExclusiveCommandParser({ _ in FakeSlowCommand() }) {
            let (paths, task) = try await startTestDaemon(udid: udid, connectionIdentity: "adb=A", baseDirectory: tmp)
            defer { task.cancel() }

            SlowCommandState.reset(duration: 0.3, failures: 1)
            let connection = ClientConnection("adb=A")

            try await withClientConnection(connection, udid: udid) {
                let request = Task {
                    try await DaemonClient.invoke(
                        command: "fake-slow",
                        args: [],
                        udid: udid,
                        baseDirectory: tmp,
                        transientRetryDelay: 0.05
                    )
                }
                try await waitUntilCommandStarted()
                // Changing the environment mid-call must not split one
                // invocation across two connections.
                connection.identity = "adb=B"
                _ = try await request.value
            }

            #expect(SlowCommandState.executeCount == 2)

            await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
            _ = try? await task.value
        }
    }
}
