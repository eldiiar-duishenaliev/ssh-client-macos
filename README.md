# SSH Client for macOS

A native macOS remote-connection manager in the spirit of
[mRemoteNG](https://github.com/mRemoteNG/mRemoteNG): a connection tree with
folders, tabbed sessions, credentials in the Keychain, SFTP, and port
forwarding.

> Status: **Phase 0 (scaffold) complete.** The toolchain builds, links
> libssh2, passes tests, and produces a launchable `.app`. SSH sessions arrive
> in phase 1.

## Requirements

- macOS 14 or later (developed on macOS 26)
- Apple Silicon (Homebrew prefix `/opt/homebrew`)
- Homebrew `libssh2`:
  ```sh
  brew install libssh2
  ```
- **Xcode** (recommended). SwiftUI previews, the `.xcodeproj`, and `XCTest`
  require a full Xcode install. The project also builds with Command Line
  Tools alone — see *Command Line Tools notes* below.

## Build, test, run

```sh
Scripts/bundle.sh          # build + assemble + ad-hoc sign dist/SSHClientMac.app
Scripts/run.sh             # bundle and launch
Scripts/test.sh            # run the test suite
swift build                # plain SwiftPM build
```

## Architecture

| Target | Responsibility |
|---|---|
| `Clibssh2` | `systemLibrary` modulemap over Homebrew's libssh2 |
| `SSHCore` | sessions, auth, known_hosts, PTY, channels |
| `SFTPCore` | SFTP subsystem client |
| `ForwardingKit` | `-L` / `-R` / `-D` forwarding, jump hosts |
| `ConnectionStore` | connection/folder models, inheritance, persistence, importers |
| `CredentialKit` | Keychain secrets, SSH key management |
| `TerminalKit` | SwiftTerm terminal bridge |
| `SSHClientApp` | SwiftUI application shell |

Terminal emulation uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
SSH/SFTP/tunnels use `libssh2`.

## Roadmap

- **P0** Scaffold & toolchain ✅
- **P1** SSH terminal core — auth, host-key verification, session tabs
- **P2** Connection tree, properties, quick connect, persistence, `confCons.xml` import
- **P3** Keychain credentials, folder inheritance, SSH key manager
- **P4** SFTP browser, port forwarding, jump hosts, logging, snippets
- **P5** Polish, signing, tests

## Command Line Tools notes

Building without Xcode works, with three caveats that the scripts handle:

1. **`libssh2` header path** — the `Clibssh2` system-library modulemap points at
   `/opt/homebrew/opt/libssh2/include`. Homebrew's libssh2 is built against
   `openssl@4`, whose dylibs must be present.
2. **Swift Testing macros** — SwiftPM does not add the testing macro plugin
   path under CLT. `Scripts/test.sh` passes `-external-plugin-path`
   automatically when the directory exists.
3. **`#Preview`** — the preview macro plugin ships only with Xcode, so preview
   blocks are omitted for now. Re-add them after installing Xcode.

Also note: Homebrew's libssh2 bottle is built for a newer macOS than the
package's 14.0 deployment target, which produces a linker warning. This is
harmless on this machine.
