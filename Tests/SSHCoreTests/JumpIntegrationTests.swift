import Testing
import Foundation
@testable import SSHCore

/// Exercises the bastion ("ProxyJump") path with two real sshd instances: one
/// acting as the bastion, one as the otherwise-ordinary target.
@Suite("SSH jump host integration", .serialized)
struct JumpIntegrationTests {

    @Test("reaches a target through a bastion and opens a direct-tcpip channel")
    func connectsThroughBastion() throws {
        guard let bastion = try SSHDHarness.start(logLevel: "DEBUG3") else { return }
        defer { bastion.stop() }

        guard let target = try SSHDHarness.start() else { return }
        defer { target.stop() }

        // One shared known_hosts file receives both host keys.
        let knownHosts = bastion.knownHostsPath

        let configuration = SSHConfiguration(
            host: "127.0.0.1",
            port: target.port,
            username: NSUserName(),
            auth: keyAuth(privateKeyPath: target.clientKeyPath),
            terminalType: "xterm-256color",
            columns: 80,
            rows: 24,
            connectTimeout: 10,
            knownHostsPath: knownHosts,
            jump: SSHJumpConfiguration(
                host: "127.0.0.1",
                port: bastion.port,
                username: NSUserName(),
                auth: keyAuth(privateKeyPath: bastion.clientKeyPath),
                knownHostsPath: knownHosts,
                connectTimeout: 10
            )
        )

        let probe = SessionProbe()
        let decisions = LockedValue<[HostKeyStatus]>([])
        let session = SSHSession(
            configuration: configuration,
            callbacks: .init(
                onData: { probe.append($0) },
                onState: { probe.record($0) },
                onError: { probe.record($0) },
                verifyHostKey: { info in
                    var list = decisions.get()
                    list.append(info.status)
                    decisions.set(list)
                    return .acceptAndSave
                }
            )
        )
        session.start()
        defer { session.disconnect() }

        #expect(
            probe.waitForState(.connected, timeout: 30),
            "tunnelled session did not connect: \(probe.debugDescription)"
        )

        // Prove the shell really is the target, reached over the tunnel.
        session.write(Data("echo JUMP_MARKER_OK\n".utf8))
        #expect(
            probe.waitForOutput(containing: "JUMP_MARKER_OK", timeout: 20),
            "no output through the tunnel: \(probe.debugDescription)"
        )

        // Both host keys were verified (bastion first, then target).
        #expect(decisions.get().count == 2, "expected the bastion and the target keys")
        #expect(decisions.get() == [.notFound, .notFound])

        // The bastion must have been asked to open the tunnel, which is what
        // distinguishes this from a direct connection.
        let bastionLog = bastion.logContents()
        #expect(
            bastionLog.lowercased().contains("direct-tcpip"),
            "the bastion log shows no direct-tcpip channel request"
        )
        #expect(bastionLog.contains("\(target.port)"), "the bastion did not tunnel to the target port")
    }

    @Test("a failed bastion connection reports an error and does not hang")
    func bastionFailureIsReported() throws {
        // Nothing is listening on this port.
        let configuration = SSHConfiguration(
            host: "127.0.0.1",
            port: 22,
            username: NSUserName(),
            auth: keyAuth(privateKeyPath: "/nonexistent"),
            connectTimeout: 3,
            jump: SSHJumpConfiguration(
                host: "127.0.0.1",
                port: 9,
                username: NSUserName(),
                auth: keyAuth(privateKeyPath: "/nonexistent"),
                connectTimeout: 3
            )
        )

        let probe = SessionProbe()
        let session = SSHSession(
            configuration: configuration,
            callbacks: .init(
                onData: { probe.append($0) },
                onState: { probe.record($0) },
                onError: { probe.record($0) },
                verifyHostKey: { _ in .reject }
            )
        )
        session.start()
        defer { session.disconnect() }

        // Reaching a terminal state within the timeout proves it did not hang.
        #expect(
            probe.waitForState(.closed, timeout: 20),
            "an unreachable bastion should settle rather than hang: \(probe.debugDescription)"
        )
        #expect(
            probe.hasState { if case .failed = $0 { return true } else { return false } },
            "expected a failure to be reported: \(probe.debugDescription)"
        )
    }

    private func keyAuth(privateKeyPath: String) -> SSHAuthMethod {
        SSHAuthMethod(kind: .privateKey(privateKeyPath: privateKeyPath, publicKeyPath: nil, passphrase: nil))
    }
}
