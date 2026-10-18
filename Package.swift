// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Homebrew prefix for this architecture: /opt/homebrew on Apple Silicon,
// /usr/local on Intel.
let brewPrefix = FileManager.default.fileExists(atPath: "/opt/homebrew/opt")
    ? "/opt/homebrew"
    : "/usr/local"

// MARK: - libssh2

let libssh2Prefix = "\(brewPrefix)/opt/libssh2"
let libssh2Lib = "\(libssh2Prefix)/lib"

// MARK: - OpenSSL

// The CCrypto shim needs AES-GCM with an arbitrary IV length, which CommonCrypto
// does not offer, so it uses OpenSSL. It must be the *same* OpenSSL that libssh2
// was built against, or two copies end up in the process. CI pins
// OPENSSL_PREFIX from libssh2's own linkage; see Scripts/setup-deps.sh.
let openSSLPrefix: String = {
    if let override = ProcessInfo.processInfo.environment["OPENSSL_PREFIX"], !override.isEmpty {
        return override
    }
    for name in ["openssl@4", "openssl@3", "openssl"] {
        let prefix = "\(brewPrefix)/opt/\(name)"
        if FileManager.default.fileExists(atPath: "\(prefix)/include/openssl/evp.h") {
            return prefix
        }
    }
    return "\(brewPrefix)/opt/openssl"
}()
let openSSLLib = "\(openSSLPrefix)/lib"

// MARK: - Linking

// Static archives rather than dylibs, so a packaged app runs on a machine with
// no Homebrew installed. Because the archives are static, every transitive
// dependency has to be listed explicitly — a dylib would have carried its own
// dependencies. Order matters: the linker resolves left to right, so providers
// come after consumers. zlib is the one remaining dependency, and macOS ships
// it in /usr/lib.
let nativeLinker: [LinkerSetting] = [
    .unsafeFlags([
        "\(libssh2Lib)/libssh2.a",
        "\(openSSLLib)/libssl.a",
        "\(openSSLLib)/libcrypto.a",
        "-lz"
    ])
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

        // SSH transport: sessions, auth, known_hosts, PTY, channels, jump hosts.
        .target(
            name: "SSHCore",
            dependencies: ["Clibssh2"],
            linkerSettings: nativeLinker
        ),

        // SFTP subsystem client.
        .target(
            name: "SFTPCore",
            dependencies: ["Clibssh2", "SSHCore"],
            linkerSettings: nativeLinker
        ),

        // Port forwarding (-L/-R/-D).
        .target(
            name: "ForwardingKit",
            dependencies: ["Clibssh2", "SSHCore"],
            linkerSettings: nativeLinker
        ),

        // Connection/folder models, inheritance, persistence, importers.
        .target(
            name: "ConnectionStore",
            dependencies: ["CredentialKit", "CCrypto"],
            linkerSettings: nativeLinker
        ),

        // Keychain-backed secret storage and SSH key management.
        .target(
            name: "CredentialKit"
        ),

        // C shim over OpenSSL for AES-GCM / PBKDF2 / MD5.
        .target(
            name: "CCrypto",
            path: "Sources/CCrypto",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(openSSLPrefix)/include"])
            ],
            linkerSettings: nativeLinker
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
            linkerSettings: nativeLinker
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
