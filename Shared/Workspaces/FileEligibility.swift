import Foundation

/// File-name and content checks that keep sensitive and non-text files out of a workspace.
enum FileEligibility {
    private static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "p8", "jks", "keystore", "kdbx", "ovpn", "gpg", "tfvars", "tfstate",
    ]
    private static let secretStems: Set<String> = [
        "password", "passwords", "passwd", "secret", "secrets", "credential", "credentials",
        "token", "tokens", "apikey", "apikeys", "api_key", "api_keys", "private_key",
    ]
    private static let secretNames: Set<String> = [
        ".npmrc", ".netrc", ".pgpass", ".htpasswd", ".git-credentials", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    ]

    /// `.env` files, keys, credentials, and password-like names. Matched by whole name or stem,
    /// so a note called "Token economics.md" is not caught.
    static func looksSecret(fileName: String) -> Bool {
        let name = fileName.lowercased()
        if secretNames.contains(name) || name == ".env" || name.hasPrefix(".env.") {
            return true
        }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") {
            return !name.hasSuffix(".pub")
        }
        let ext = (name as NSString).pathExtension
        if secretExtensions.contains(ext) {
            return true
        }
        return secretStems.contains((name as NSString).deletingPathExtension)
    }

    /// `true` if the first 8 KB holds a NUL byte, which text files don't have. Uses plain POSIX
    /// calls: `FileHandle` costs about ten times more per file, which adds up over thousands.
    static func looksBinary(at url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return withUnsafeTemporaryAllocation(byteCount: 8192, alignment: 1) { buffer in
            let count = read(descriptor, buffer.baseAddress, 8192)
            return count > 0 && memchr(buffer.baseAddress, 0, count) != nil
        }
    }
}
