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
- Homebrew packages:
  ```sh
  brew install libssh2 openssl@4
  ```
  (`libssh2` pulls in `openssl@4` automatically; it is listed because the
  crypto shim links it directly.)
- **Xcode** (recommended). SwiftUI previews, the `.xcodeproj`, and `XCTest`
  require a full Xcode install. The project also builds with Command Line
  Tools alone — see *Command Line Tools notes* below.

## Build, test, run

```sh
Scripts/bundle.sh          # build + assemble + ad-hoc sign dist/SSHClientMac.app
Scripts/run.sh             # bundle and launch
Scripts/test.sh            # run the test suite
Scripts/make-icon.sh       # regenerate Resources/AppIcon.icns
Scripts/make-fixtures.py   # regenerate the mRemoteNG test fixtures
swift build                # plain SwiftPM build
```

## Architecture

| Target | Responsibility |
|---|---|
| `Clibssh2` | `systemLibrary` modulemap over Homebrew's libssh2 |
| `CCrypto` | C shim over OpenSSL (AES-GCM, PBKDF2, MD5) for the importer |
| `SSHCore` | sessions, auth, known_hosts, PTY, channels, jump hosts |
| `SFTPCore` | SFTP subsystem client |
| `ForwardingKit` | `-L` / `-R` / `-D` forwarding |
| `ConnectionStore` | connection/folder models, inheritance, persistence, importers |
| `CredentialKit` | Keychain secrets, SSH key management |
| `TerminalKit` | SwiftTerm terminal bridge |
| `SSHClientApp` | SwiftUI application shell |

Terminal emulation uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
SSH/SFTP/tunnels use `libssh2`.

## Roadmap

- **P0** Scaffold & toolchain ✅
- **P1** SSH terminal core — auth, host-key verification, session tabs ✅
- **P2** Connection tree, properties, quick connect, persistence, `confCons.xml` import ✅
- **P3** Jump hosts (`ProxyJump`) ✅ · app icon ✅
- **P4** Keychain credential UI, SSH key manager
- **P5** SFTP browser, `-L` / `-R` / `-D` forwarding
- **P6** Polish, signing, release

## Usage

**Connections.** The left sidebar holds the connection tree. Right-click to add
folders and connections, or to delete a node. Folder properties are inherited
by their contents — set a username or port once on a folder and every
connection beneath it picks it up, unless it overrides the value. Select a node
and use the properties inspector (toolbar, right side) to edit it.

Connection details are stored as JSON in
`~/Library/Application Support/SSHClientMac/connections.json`. Passwords never
go in that file; they live in the macOS Keychain.

**Importing mRemoteNG.** Use the Import toolbar button and choose a
`confCons.xml`. Modern (PBKDF2 + AES-GCM) and legacy (MD5 + AES-CBC) files are
supported, as is full-file encryption. If the file has a master password you
are prompted for it. Decrypted passwords are moved into the Keychain, so the
imported connections can be opened directly.

**Keys and passphrases.** Each connection and each jump host has its own key
path (*Private key* / *Jump key*) and its own passphrase. Passphrases are
secrets, so the inspector shows a **Set… / Clear** control rather than a text
field, and the value goes into the macOS Keychain — the connections file only
ever stores a reference. Like every other property, a passphrase can be set
once on a folder and inherited.

**Jump hosts (ProxyJump).** A connection can be tunnelled through a bastion by
filling in *Jump host* / *Jump port* / *Jump user* / *Jump key* in the
properties inspector. Jump settings are inherited like every other property, so
the usual arrangement is one folder holding the bastion and its children
pointing at internal hosts — the equivalent of `ssh -J root@bastion host`.

The client opens a `direct-tcpip` channel on the bastion and runs the real
session over it, so the bastion sees an ordinary port-forward. Both the
bastion's and the target's host keys are verified against `known_hosts`.

**Example file.** `Examples/jump-host.json` holds a worked jump-host setup
(a documentation IP range, not a real host). Import it with
**Import → Connections JSON…** in the toolbar.

**Sessions.** Double-click a connection to open a terminal tab, or press **⌘N**
to quick-connect to a host without saving it. Host keys are verified against
`~/.ssh/known_hosts`; an unknown or changed key prompts before connecting.

## App icon

`Resources/AppIcon.icns` is generated, not hand-drawn: run
`Scripts/make-icon.sh` to rebuild it. The artwork is a rounded tile with an
indigo→cyan gradient carrying a white `>_` terminal prompt, with a dotted hop
arc and two nodes above it standing for reaching a host through a bastion.
`Scripts/make-icon.swift` draws it with Core Graphics at 1024px, and `sips` +
`iconutil` pack the required sizes.

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
4. **SwiftUI `@State`** — in the Command Line Tools SDK 27.0, `@State` is
   implemented as a macro whose plugin ships only with Xcode. Local view state
   therefore lives in small `ObservableObject` view models (an ordinary MVVM
   pattern) rather than `@State`. `@StateObject`, `@ObservedObject`,
   `@Environment`, `@Published` and friends all work. Installing Xcode lifts
   this limitation entirely.

Also note: Homebrew's libssh2 bottle is built for a newer macOS than the
package's 14.0 deployment target, which produces a linker warning. This is
harmless on this machine.
