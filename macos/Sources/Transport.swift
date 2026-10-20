import Foundation
import Security

/// Mots de passe rangés dans le trousseau de macOS (jamais dans un fichier).
enum Keychain {
    static let service = "fr.aikographic.aikodeploy"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ password: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Résultat d'un envoi : ce qui est vraiment parti, ce qui a échoué.
struct TransferReport {
    var uploaded: [String] = []
    var deleted: [String] = []
    var failed: [String: String] = [:]
    var log: [String] = []
}

/// Envoie et supprime des fichiers sur le serveur (FTP/FTPS avec curl, SFTP avec sftp, tous deux fournis avec macOS).
struct Transport {
    let site: Site
    let password: String

    /// Dossier distant. Sans chemin système explicite (/home, /var…), il est pris depuis le dossier de connexion,
    /// comme le font les hébergeurs (« /www » = le dossier www du compte).
    var remoteRoot: String {
        var r = site.remotePath.trimmingCharacters(in: .whitespaces)
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        let absolute = ["/home/", "/var/", "/srv/", "/Users/", "/tmp/", "/private/", "/data/"].contains { r.hasPrefix($0) }
        if !absolute { while r.hasPrefix("/") { r.removeFirst() } }
        return r
    }

    func remote(_ rel: String) -> String { remoteRoot.isEmpty || remoteRoot == "/" ? rel : remoteRoot + "/" + rel }

    // MARK: Commun

    private func run(_ exe: String, _ args: [String], stdin: String? = nil, env: [String: String] = [:]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        e.merge(env) { _, n in n }
        p.environment = e
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func tempFile(_ content: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("aikodeploy-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: u.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600])
        return u
    }

    // MARK: FTP / FTPS (curl)

    private func ftpURL(_ path: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;%"))
        var enc = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        // Chemin absolu : « %2F » au début, sinon depuis le dossier de connexion
        if enc.hasPrefix("/") { enc = "%2F" + enc.dropFirst() }
        return "ftp://\(site.host):\(site.port)/" + enc
    }

    private func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    private var ftpCommon: [String] {
        var lines = ["user = \(q(site.user + ":" + password))", "connect-timeout = 15", "silent", "show-error"]
        if site.proto == .ftps { lines.append("ssl-reqd") }
        return lines
    }

    func test() -> (Bool, String) {
        switch site.proto {
        case .ftp, .ftps:
            let cfg = tempFile((ftpCommon + ["url = \(q(ftpURL(remoteRoot.isEmpty ? "" : remoteRoot + "/")))", "list-only"]).joined(separator: "\n"))
            defer { try? FileManager.default.removeItem(at: cfg) }
            let (code, out) = run("/usr/bin/curl", ["--config", cfg.path])
            return (code == 0, code == 0 ? "Connexion réussie" : Self.curlError(code, out))
        case .sftp:
            let (code, out) = sftp("ls \(sq(remoteRoot.isEmpty ? "." : remoteRoot))\n")
            return (code == 0, code == 0 ? "Connexion réussie" : Self.sshError(out))
        }
    }

    func send(uploads: [(rel: String, local: URL)], deletes: [String]) -> TransferReport {
        switch site.proto {
        case .ftp, .ftps: return ftpSend(uploads, deletes)
        case .sftp: return sftpSend(uploads, deletes)
        }
    }

    private func ftpSend(_ uploads: [(rel: String, local: URL)], _ deletes: [String]) -> TransferReport {
        var r = TransferReport()
        if !uploads.isEmpty {
            var lines: [String] = []
            for (i, u) in uploads.enumerated() {
                if i > 0 { lines.append("next") }
                lines += ftpCommon
                lines += ["ftp-create-dirs", "url = \(q(ftpURL(remote(u.rel))))", "upload-file = \(q(u.local.path))",
                          "write-out = \(q("%{exitcode}\\t\(u.rel)\\n"))"]
            }
            let cfg = tempFile(lines.joined(separator: "\n"))
            defer { try? FileManager.default.removeItem(at: cfg) }
            let (_, out) = run("/usr/bin/curl", ["--config", cfg.path])
            var seen = Set<String>()
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2, let code = Int32(parts[0]) else { r.log.append(String(line)); continue }
                seen.insert(parts[1])
                if code == 0 { r.uploaded.append(parts[1]) } else { r.failed[parts[1]] = Self.curlError(code, "") }
            }
            for u in uploads where !seen.contains(u.rel) { r.failed[u.rel] = "non envoyé" }
        }
        for rel in deletes {
            let cfg = tempFile((ftpCommon + ["url = \(q(ftpURL("")))", "list-only",
                                             "quote = \(q("DELE " + remote(rel)))"]).joined(separator: "\n"))
            let (code, out) = run("/usr/bin/curl", ["--config", cfg.path])
            try? FileManager.default.removeItem(at: cfg)
            if code == 0 { r.deleted.append(rel) } else { r.failed[rel] = Self.curlError(code, out) }
        }
        return r
    }

    static func curlError(_ code: Int32, _ out: String) -> String {
        switch code {
        case 6: return "Serveur introuvable (vérifie l'adresse)"
        case 7, 28: return "Le serveur ne répond pas (adresse, port ou pare-feu)"
        case 9: return "Dossier distant introuvable ou interdit"
        case 67: return "Identifiant ou mot de passe refusé"
        case 25: return "Envoi refusé par le serveur (droits du dossier ?)"
        case 35, 60, 64: return "Connexion sécurisée impossible (essaie FTP ou SFTP)"
        default:
            let detail = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Erreur \(code)" + (detail.isEmpty ? "" : " : " + String(detail.suffix(160)))
        }
    }

    // MARK: SFTP (OpenSSH)

    private func sq(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    private func sftp(_ commands: String) -> (Int32, String) {
        var args = ["-P", "\(site.port)", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15",
                    "-o", "NumberOfPasswordPrompts=1"]
        var env: [String: String] = [:]
        if !site.keyFile.isEmpty {
            args += ["-i", (site.keyFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes",
                     "-o", "PreferredAuthentications=publickey", "-o", "BatchMode=yes"]
        } else {
            // Le mot de passe est donné par un petit script (jamais en clair dans la liste des processus)
            let askpass = tempFile("#!/bin/sh\nprintf '%s\\n' \"$AIKO_SFTP_PW\"\n")
            chmod(askpass.path, 0o700)
            env = ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "AIKO_SFTP_PW": password]
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        args.append("\(site.user)@\(site.host)")
        let result = run("/usr/bin/sftp", args, stdin: commands + "bye\n", env: env)
        if let a = env["SSH_ASKPASS"] { try? FileManager.default.removeItem(atPath: a) }
        return result
    }

    private func sftpSend(_ uploads: [(rel: String, local: URL)], _ deletes: [String]) -> TransferReport {
        var r = TransferReport()
        var dirs = Set<String>()
        for u in uploads {
            var d = (remote(u.rel) as NSString).deletingLastPathComponent
            while !d.isEmpty && d != "/" && d != remoteRoot && !dirs.contains(d) {
                dirs.insert(d)
                d = (d as NSString).deletingLastPathComponent
            }
        }
        var cmds = ""
        for d in dirs.sorted(by: { $0.count < $1.count }) { cmds += "-mkdir \(sq(d))\n" }
        for u in uploads { cmds += "put \(sq(u.local.path)) \(sq(remote(u.rel)))\n" }
        for rel in deletes { cmds += "-rm \(sq(remote(rel)))\n" }
        let (code, out) = sftp(cmds)
        r.log = out.split(separator: "\n").map(String.init)
        if code == 0 {
            r.uploaded = uploads.map(\.rel)
            r.deleted = deletes
        } else {
            let msg = Self.sshError(out)
            for u in uploads { r.failed[u.rel] = msg }
            for d in deletes { r.failed[d] = msg }
        }
        return r
    }

    static func sshError(_ out: String) -> String {
        let o = out.lowercased()
        if o.contains("permission denied") { return "Identifiant, mot de passe ou clé refusé" }
        if o.contains("could not resolve") { return "Serveur introuvable (vérifie l'adresse)" }
        if o.contains("timed out") || o.contains("connection refused") { return "Le serveur ne répond pas (adresse ou port)" }
        if o.contains("no such file") { return "Dossier distant introuvable" }
        return String(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))
    }
}
