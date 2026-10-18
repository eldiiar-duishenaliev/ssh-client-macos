// swift-tools-version: 6.0
import PackageDescription

// Homebrew (Apple Silicon) location of libssh2. The headers are referenced by
// the Clibssh2 system-library modulemap; this is only used for linking.
let brewPrefix = "/opt/homebrew"
let libssh2Lib = "\(brewPrefix)/opt/libssh2/lib"

// OpenSSL, used by the CCrypto shim (AES-GCM with arbitrary IV length, which
// CommonCrypto does not provide). libssh2 already links against the same
// openssl@4, so there is a single copy in the process.
let openSSLInclude = "\(brewPrefix)/opt/openssl@4/include"
let openSSLLib = "\(brewPrefix)/opt/openssl@4/lib"

let sshLinker: [LinkerSetting] = [
    .unsafeFlags(["-L\(libssh2Lib)"]),
    .linkedLibrary("ssh2")
]

let cryptoLinker: [LinkerSetting] = [
    .unsafeFlags(["-L\(openSSLLib)"]),
    .linkedLibrary("crypto")
]

let package = Package(
    name: "SSHClientMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SSHClientMac", targets: ["SSHClientApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        // System-library wrapper over Homebrew's libssh2.
        .systemLibrary(
            name: "Clibssh2",
            path: "Sources/Clibssh2",
            providers: [.brew(["libssh2"])]
        ),

        // SSH transport: sessions, auth, known_hosts, PTY, channels.
        .target(
            name: "SSHCore",
            dependencies: ["Clibssh2"],
            linkerSettings: sshLinker
        ),

        // SFTP subsystem client.
        .target(
            name: "SFTPCore",
            dependencies: ["Clibssh2", "SSHCore"],
            linkerSettings: sshLinker
        ),

        // Port forwarding (-L/-R/-D) and jump hosts.
        .target(
            name: "ForwardingKit",
            dependencies: ["Clibssh2", "SSHCore"],
            linkerSettings: sshLinker
        ),

        // Connection/folder models, inheritance, persistence, importers.
        .target(
            name: "ConnectionStore",
            dependencies: ["CredentialKit", "CCrypto"],
            linkerSettings: cryptoLinker
        ),

        // C shim over OpenSSL for AES-GCM / PBKDF2 / MD5.
        .target(
            name: "CCrypto",
            path: "Sources/CCrypto",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(openSSLInclude)"])
            ],
            linkerSettings: cryptoLinker
        ),

        // Keychain-backed secret storage and SSH key management.
        .target(
            name: "CredentialKit"
        ),

        // SwiftTerm bridge: terminal view, keymaps, themes.
        .target(
            name: "TerminalKit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),

        // The app itself.
        .executableTarget(
            name: "SSHClientApp",
            dependencies: [
                "SSHCore",
                "SFTPCore",
                "ForwardingKit",
                "ConnectionStore",
                "CredentialKit",
                "TerminalKit"
            ],
            linkerSettings: sshLinker
        ),

        .testTarget(
            name: "SSHCoreTests",
            dependencies: ["SSHCore"]
        ),

        .testTarget(
            name: "ConnectionStoreTests",
            dependencies: ["ConnectionStore", "CredentialKit"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v5]
)
