import Testing
import Foundation
@testable import SSHCore

/// Thread-safe collector for session callbacks, which fire on the session
/// thread.
final class SessionProbe {
    private let lock = NSLock()
    private var output = Data()
    private var states: [SSHSession.State] = []
    private var error: SSHError?

    func append(_ data: Data) {
        lock.lock(); output.append(data); lock.unlock()
    }

    func record(_ state: SSHSession.State) {
        lock.lock(); states.append(state); lock.unlock()
    }

    func record(_ error: SSHError) {
        lock.lock(); self.error = error; lock.unlock()
    }

    /// The most recent state reported.
    func currentState() -> SSHSession.State? {
        lock.lock(); defer { lock.unlock() }
        return states.last
    }

    /// Whether any observed state satisfies `predicate`. Useful for terminal
    /// states that carry an associated value.
    func hasState(where predicate: (SSHSession.State) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return states.contains(where: predicate)
    }

    func waitForState(_ target: SSHSession.State, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let found = states.contains(target); lock.unlock()
            if found { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func waitForOutput(containing needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let text = String(decoding: output, as: UTF8.self)
            lock.unlock()
            if text.contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    var debugDescription: String {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: output, as: UTF8.self)
        return "states=\(states) error=\(String(describing: error)) outputTail=\(text.suffix(300))"
    }
}

@Suite("SSHSession integration", .serialized)
struct SSHSessionIntegrationTests {

    @Test("connects to a local sshd, verifies host keys, and runs a command")
    func connectsAndRunsCommand() throws {
        guard let harness = try SSHDHarness.start() else {
            // sshd or ssh-keygen unavailable; nothing to exercise.
            return
        }
        defer { harness.stop() }

        // --- First connection: unknown host key, accepted and saved. ---
        let first = SessionProbe()
        let firstKey = LockedValue<HostKeyInfo?>(nil)
        let firstSession = SSHSession(
            configuration: configuration(for: harness),
            callbacks: .init(
                onData: { first.append($0) },
                onState: { first.record($0) },
                onError: { first.record($0) },
                verifyHostKey: { info in
                    firstKey.set(info)
                    return .acceptAndSave
                }
            )
        )
        firstSession.start()
        defer { firstSession.disconnect() }

        #expect(first.waitForState(.connected, timeout: 20), "first session failed: \(first.debugDescription)")
        #expect(firstKey.get()?.status == HostKeyStatus.notFound, "expected an unknown host key")

        firstSession.write(Data("echo INTEGRATION_MARKER_OK\n".utf8))
        #expect(
            first.waitForOutput(containing: "INTEGRATION_MARKER_OK", timeout: 20),
            "did not see command output: \(first.debugDescription)"
        )

        let knownHosts = try String(contentsOfFile: harness.knownHostsPath, encoding: .utf8)
        #expect(knownHosts.contains("ssh-ed25519"), "host key was not saved to known_hosts")

        // --- Second connection: the saved key now matches, no prompt. ---
        let second = SessionProbe()
        let secondPrompted = LockedValue(false)
        let secondSession = SSHSession(
            configuration: configuration(for: harness),
            callbacks: .init(
                onData: { second.append($0) },
                onState: { second.record($0) },
                onError: { second.record($0) },
                verifyHostKey: { _ in
                    secondPrompted.set(true)
                    return .reject
                }
            )
        )
        secondSession.start()
        defer { secondSession.disconnect() }

        #expect(second.waitForState(.connected, timeout: 20), "second session failed: \(second.debugDescription)")
        #expect(secondPrompted.get() == false, "known host should not have been prompted for")
    }

    private func configuration(for harness: SSHDHarness) -> SSHConfiguration {
        SSHConfiguration(
            host: "127.0.0.1",
            port: harness.port,
            username: NSUserName(),
            auth: SSHAuthMethod(kind: .privateKey(
                privateKeyPath: harness.clientKeyPath,
                publicKeyPath: nil,
                passphrase: nil
            )),
            terminalType: "xterm-256color",
            columns: 80,
            rows: 24,
            connectTimeout: 10,
            knownHostsPath: harness.knownHostsPath
        )
    }
}

/// Minimal lock-protected box for sharing a value across threads.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}
