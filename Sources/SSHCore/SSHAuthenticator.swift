import Foundation
import Clibssh2

/// Performs user authentication on an established session.
enum SSHAuthenticator {
    static func authenticate(session: OpaquePointer, username: String, auth: SSHAuthMethod) throws {
        switch auth.kind {
        case .password(let password):
            let result = username.withCString { user in
                password.withCString { pass in
                    libssh2_userauth_password_ex(
                        session,
                        user,
                        UInt32(username.utf8.count),
                        pass,
                        UInt32(password.utf8.count),
                        nil
                    )
                }
            }
            guard result == 0 else {
                throw SSHError.authentication(Libssh2.message(session))
            }

        case .privateKey(let privateKeyPath, let publicKeyPath, let passphrase):
            let result = username.withCString { user in
                privateKeyPath.withCString { privateKey in
                    let perform = { (publicKey: UnsafePointer<CChar>?) -> Int32 in
                        if let passphrase {
                            return passphrase.withCString { pass in
                                libssh2_userauth_publickey_fromfile_ex(
                                    session, user, UInt32(username.utf8.count), publicKey, privateKey, pass
                                )
                            }
                        }
                        return libssh2_userauth_publickey_fromfile_ex(
                            session, user, UInt32(username.utf8.count), publicKey, privateKey, nil
                        )
                    }
                    if let publicKeyPath {
                        return publicKeyPath.withCString { perform($0) }
                    }
                    return perform(nil)
                }
            }
            guard result == 0 else {
                throw SSHError.authentication(Libssh2.message(session))
            }

        case .agent:
            try authenticateWithAgent(session: session, username: username)
        }
    }

    private static func authenticateWithAgent(session: OpaquePointer, username: String) throws {
        guard let agent = libssh2_agent_init(session) else {
            throw SSHError.authentication("could not initialize the SSH agent")
        }
        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }

        guard libssh2_agent_connect(agent) == 0 else {
            throw SSHError.authentication("could not connect to the SSH agent")
        }
        guard libssh2_agent_list_identities(agent) == 0 else {
            throw SSHError.authentication("could not list agent identities")
        }

        var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?

        while libssh2_agent_get_identity(agent, &identity, previous) == 0 {
            guard let identity else { break }
            let result = username.withCString { user in
                libssh2_agent_userauth(agent, user, identity)
            }
            if result == 0 { return }
            previous = identity
        }

        throw SSHError.authentication("no agent identity was accepted")
    }
}
