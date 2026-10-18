import Testing
import Foundation
@testable import SSHCore

/// Verifies that an encrypted private key can be unlocked with a passphrase,
/// and that it is refused without one.
@Suite("Key passphrase integration", .serialized)
struct PassphraseIntegrationTests {

    private let passphrase = "correct horse battery staple"

    @Test("an encrypted key connects with its passphrase")
    func connectsWithPassphrase() throws {
        guard let host = try SSHDHarness.start(keyPassphrase: passphrase) else { return }
        defer { host.stop() }

        let probe = SessionProbe()
        let session = SSHSession(
            configuration: configuration(for: host, passphrase: passphrase),
            callbacks: callbacks(for: probe)
        )
        session.start()
        defer { session.disconnect() }

        #expect(
            probe.waitForState(.connected, timeout: 25),
            "encrypted key did not unlock: \(probe.debugDescription)"
        )

        session.write(Data("echo PASSPHRASE_MARKER_OK\n".utf8))
        #expect(
            probe.waitForOutput(containing: "PASSPHRASE_MARKER_OK", timeout: 20),
            "no shell output: \(probe.debugDescription)"
        )
    }

    @Test("an encrypted key is refused without a passphrase")
    func failsWithoutPassphrase() throws {
        guard let host = try SSHDHarness.start(keyPassphrase: passphrase) else { return }
        defer { host.stop() }

        let probe = SessionProbe()
        let session = SSHSession(
            configuration: configuration(for: host, passphrase: nil),
            callbacks: callbacks(for: probe)
        )
        session.start()
        defer { session.disconnect() }

        // Reaching a terminal state proves it did not hang.
        #expect(
            probe.waitForState(.closed, timeout: 25),
            "session should have settled: \(probe.debugDescription)"
        )
        #expect(
            !probe.hasState { if case .connected = $0 { return true } else { return false } },
            "must not connect without the passphrase"
        )
        #expect(
            probe.hasState { if case .failed = $0 { return true } else { return false } },
            "expected an authentication failure: \(probe.debugDescription)"
        )
    }

    @Test("a wrong passphrase is rejected")
    func rejectsWrongPassphrase() throws {
        guard let host = try SSHDHarness.start(keyPassphrase: passphrase) else { return }
        defer { host.stop() }

        let probe = SessionProbe()
        let session = SSHSession(
            configuration: configuration(for: host, passphrase: "not the passphrase"),
            callbacks: callbacks(for: probe)
        )
        session.start()
        defer { session.disconnect() }

        #expect(probe.waitForState(.closed, timeout: 25), "session should have settled")
        #expect(
            !probe.hasState { if case .connected = $0 { return true } else { return false } },
            "must not connect with the wrong passphrase"
        )
    }

    // MARK: - Helpers

    private func configuration(for host: SSHDHarness, passphrase: String?) -> SSHConfiguration {
        SSHConfiguration(
            host: "127.0.0.1",
            port: host.port,
            username: NSUserName(),
            auth: SSHAuthMethod(kind: .privateKey(
                privateKeyPath: host.clientKeyPath,
                publicKeyPath: nil,
                passphrase: passphrase
            )),
            terminalType: "xterm-256color",
            columns: 80,
            rows: 24,
            connectTimeout: 10,
            knownHostsPath: host.knownHostsPath
        )
    }

    private func callbacks(for probe: SessionProbe) -> SSHSession.Callbacks {
        SSHSession.Callbacks(
            onData: { probe.append($0) },
            onState: { probe.record($0) },
            onError: { probe.record($0) },
            verifyHostKey: { _ in .acceptAndSave }
        )
    }
}
