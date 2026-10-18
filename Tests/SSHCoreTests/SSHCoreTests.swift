import Testing
@testable import SSHCore

@Suite("SSHCore")
struct SSHCoreTests {
    @Test("libssh2 is linked and reports a version")
    func libssh2IsLinked() {
        let version = SSHCore.libssh2Version
        #expect(!version.isEmpty)
        #expect(version != "unknown")
    }

    @Test("libssh2 initializes and shuts down")
    func initializeAndShutdown() {
        #expect(SSHCore.initialize() == 0)
        SSHCore.shutdown()
    }
}
