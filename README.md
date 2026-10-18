# SSH Client for macOS

[![CI](https://github.com/eldiiar-duishenaliev/ssh-client-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/eldiiar-duishenaliev/ssh-client-macos/actions/workflows/ci.yml)

A native macOS remote-connection manager in the spirit of
[mRemoteNG](https://github.com/mRemoteNG/mRemoteNG): a connection tree with
folder inheritance, tabbed SSH terminals, ProxyJump bastion support, Keychain
credentials, and `confCons.xml` import.

> Status: SSH sessions, the connection manager, mRemoteNG import, jump hosts and
> key passphrases are implemented and covered by tests. SFTP and explicit
> `-L` / `-R` / `-D` forwarding are still to come — see the roadmap.

## Install

Download the latest `SSHClientMac-*.zip` (or `.dmg`) from
[Releases](https://github.com/eldiiar-duishenaliev/ssh-client-macos/releases).

The build is ad-hoc signed rather than notarized, so the first launch is blocked
with *"cannot be opened because the developer cannot be verified"*. Right-click
the app and choose **Open**, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/SSHClientMac.app
```

Requirements: **Apple Silicon**, **macOS 14 or later**. Nothing else — libssh2
and OpenSSL are linked into the binary, so no Homebrew install is needed to run
it.

## Building

Requires macOS 14+, Apple Silicon, [Homebrew](https://brew.sh), and a Swift 6
toolchain (Xcode 16+, or Command Line Tools — see the notes below).

```sh
Scripts/setup-deps.sh      # install libssh2 and pin the matching OpenSSL
swift build                # build
Scripts/test.sh            # run the test suite
Scripts/run.sh             # assemble and launch dist/SSHClientMac.app
Scripts/package.sh 0.2.0   # build release .zip and .dmg into dist/
```

Supporting scripts: `Scripts/bundle.sh` assembles and ad-hoc signs the bundle,
`Scripts/make-icon.sh` regenerates the app icon, and
`Scripts/make-fixtures.py` regenerates the mRemoteNG test fixtures.

## Code signing and the Keychain prompt

`Scripts/bundle.sh` ad-hoc signs the app (`codesign --sign -`) by default. That
is enough to launch it locally, but it has one consequence worth understanding:
macOS binds Keychain access to an application's *designated requirement*, and
for an ad-hoc signature that requirement is **the hash of that exact binary**:

```console
$ codesign -d -r- dist/SSHClientMac.app
# designated => cdhash H"2e065483a72ba10f07df1df9e48a7daaba186de8"
```

So every rebuild is, as far as the Keychain is concerned, a *different
application*. Items written by one build are not trusted by the next, macOS asks
for permission again, and **"Always Allow" cannot help** — it records the
requirement of the build that is about to be replaced.

There is no way around this except a stable signing identity. (Switching to the
modern data-protection keychain, which has no interactive ACLs, is not an
option either: it refuses to serve an ad-hoc signed app at all, with
`errSecMissingEntitlement`, −34018.)

A **downloaded release is a fixed binary**, so its Keychain items stay trusted
across launches. The repeated prompts only affect local development, where the
app is rebuilt between runs.

To fix it, sign with a certificate instead of `-`:

```sh
# Self-signed certificate (free, fine for personal use).
# Keychain Access → Certificate Assistant → Create a Certificate…
#   name "SSH Client Dev", Self Signed Root, certificate type: Code Signing
CODESIGN_IDENTITY="SSH Client Dev" Scripts/package.sh 0.1.0

# Developer ID Application certificate (needed to distribute).
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/package.sh 0.1.0
```

Any non-ad-hoc identity also enables the hardened runtime and a secure
timestamp, which is what notarization requires. In CI, set a
`CODESIGN_IDENTITY` repository secret and the release workflow uses it
automatically.

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
SSH/SFTP/tunnels use `libssh2`, linked statically along with OpenSSL so the
packaged app has no Homebrew dependency.

## Continuous integration and releases

`.github/workflows/ci.yml` builds and tests on every push to `main` and every
pull request. The test suite is not a mock: it starts throwaway `sshd`
instances and connects to them, so a green run covers real handshakes,
key-based auth, host-key verification, ProxyJump tunnelling and passphrase
unlocking.

`.github/workflows/release.yml` runs on a `v*` tag (or manually via
*Run workflow*). It re-runs the tests, then packages the release `.zip` and
`.dmg` and publishes them to a GitHub Release, with checksums appended to the
release notes.

To cut a release:

```sh
git tag v0.2.0
git push origin v0.2.0
```

## Roadmap

- **P0** Scaffold & toolchain ✅
- **P1** SSH terminal core — auth, host-key verification, session tabs ✅
- **P2** Connection tree, properties, quick connect, persistence, `confCons.xml` import ✅
- **P3** Jump hosts (`ProxyJump`) ✅ · key passphrases ✅ · app icon ✅
- **P4** CI, automated releases, self-contained builds ✅
- **P5** SFTP browser, `-L` / `-R` / `-D` forwarding
- **P6** Credentials UI for passwords, SSH key manager, notarized builds

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

1. **Native dependency paths** — the `Clibssh2` system-library modulemap points
   at Homebrew's headers by absolute path, because a system-library target
   cannot inherit include flags from its dependents. `Scripts/setup-deps.sh`
   writes the correct paths and pins `OPENSSL_PREFIX` to the OpenSSL that
   libssh2 was itself built against, so the crypto shim cannot pull in a second
   copy.
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

Also note: Homebrew's libssh2 archive is built for a newer macOS than the
package's 14.0 deployment target, which produces linker warnings during the
build. They are harmless — the linked code paths we use are all older than the
deployment target.
