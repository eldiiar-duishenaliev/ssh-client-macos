import Foundation
import Darwin

/// Spins up a throwaway `sshd` on a loopback port so the SSH stack can be
/// exercised end to end. Only public-key auth is enabled, against a temporary
/// `authorized_keys` file, so the machine's real SSH configuration is
/// untouched.
final class SSHDHarness {
    let directory: URL
    let port: UInt16
    let hostKeyPath: String
    let clientKeyPath: String
    let knownHostsPath: String

    private let process: Process

    private init(directory: URL, port: UInt16, hostKeyPath: String, clientKeyPath: String, knownHostsPath: String, process: Process) {
        self.directory = directory
        self.port = port
        self.hostKeyPath = hostKeyPath
        self.clientKeyPath = clientKeyPath
        self.knownHostsPath = knownHostsPath
        self.process = process
    }

    /// Returns `nil` when `sshd`/`ssh-keygen` are unavailable.
    static func start() throws -> SSHDHarness? {
        let sshd = "/usr/sbin/sshd"
        let keygen = "/usr/bin/ssh-keygen"
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: sshd),
              fileManager.isExecutableFile(atPath: keygen) else {
            return nil
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("sshclientmac-sshd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let hostKey = directory.appendingPathComponent("host_ed25519").path
        let clientKey = directory.appendingPathComponent("id_ed25519").path
        let authorizedKeys = directory.appendingPathComponent("authorized_keys").path
        let configPath = directory.appendingPathComponent("sshd_config").path

        try run(keygen, ["-t", "ed25519", "-f", hostKey, "-N", "", "-q"])
        try run(keygen, ["-t", "ed25519", "-f", clientKey, "-N", "", "-q"])

        let publicKey = try String(contentsOfFile: clientKey + ".pub", encoding: .utf8)
        try publicKey.write(toFile: authorizedKeys, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeys)

        let port = freePort()
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        AuthorizedKeysFile \(authorizedKeys)
        PubkeyAuthentication yes
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PrintMotd no
        PidFile \(directory.appendingPathComponent("sshd.pid").path)
        """

        guard port > 0 else {
            throw SSHDHarnessError.setup("could not allocate a free port")
        }

        try config.write(toFile: configPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshd)
        process.arguments = ["-f", configPath, "-D", "-e"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let knownHosts = directory.appendingPathComponent("known_hosts").path
        let harness = SSHDHarness(
            directory: directory,
            port: port,
            hostKeyPath: hostKey,
            clientKeyPath: clientKey,
            knownHostsPath: knownHosts,
            process: process
        )

        guard harness.waitForPort(timeout: 10) else {
            harness.stop()
            throw SSHDHarnessError.setup("sshd did not start listening on port \(port)")
        }
        return harness
    }

    func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitForPort(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canConnect() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func canConnect() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SSHDHarnessError.setup("\(executable) failed with status \(process.terminationStatus)")
        }
    }

    private static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 0 }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return 0 }
        return UInt16(bigEndian: address.sin_port)
    }
}

enum SSHDHarnessError: Error {
    case setup(String)
}
