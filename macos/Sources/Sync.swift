import CryptoKit
import Foundation

enum TransferProtocol: String, Codable, CaseIterable {
    case ftp, ftps, sftp

    var label: String {
        switch self {
        case .ftp: return "FTP"
        case .ftps: return "FTPS (FTP sécurisé)"
        case .sftp: return "SFTP (SSH)"
        }
    }
    var defaultPort: Int { self == .sftp ? 22 : 21 }
}

/// Un site à mettre en ligne.
struct Site: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Mon site"
    var folder = ""
    var proto: TransferProtocol = .ftp
    var host = ""
    var port = 21
    var user = ""
    var remotePath = "/www"
    var keyFile = ""               // SFTP : clé SSH (sinon mot de passe)
    var siteURL = ""
    var ignore = Sync.defaultIgnore
    var deleteRemoved = false      // supprimer sur le serveur les fichiers supprimés en local
}

/// État d'un fichier envoyé.
struct FileState: Codable, Equatable {
    let size: Int64
    let hash: String
}

/// Une mise en ligne (pour l'historique et le retour arrière).
struct Deployment: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var manifest: [String: FileState]    // état du serveur après cette mise en ligne
    var uploaded: [String]
    var deleted: [String]
    var note = ""
}

struct Changes: Equatable {
    var added: [String] = []
    var modified: [String] = []
    var removed: [String] = []
    var isEmpty: Bool { added.isEmpty && modified.isEmpty && removed.isEmpty }
    var uploads: [String] { added + modified }
}

enum Sync {
    static let defaultIgnore = [".git", ".gitignore", "node_modules", ".env", ".env.*", ".DS_Store", "*.log", ".idea",
                                ".vscode", "Thumbs.db", ".aikodeploy", "*.swp", ".sass-cache"]

    /// Faut-il ignorer ce chemin (relatif) ? Un motif vise un nom à n'importe quel niveau, ou le chemin entier.
    static func ignored(_ rel: String, _ patterns: [String]) -> Bool {
        let parts = rel.split(separator: "/").map(String.init)
        for raw in patterns {
            let p = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !p.isEmpty, !p.hasPrefix("#") else { continue }
            if p.contains("/") {
                if fnmatch(p, rel, 0) == 0 || rel.hasPrefix(p + "/") { return true }
            } else if parts.contains(where: { fnmatch(p, $0, 0) == 0 }) {
                return true
            }
        }
        return false
    }

    static func hash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// État actuel du dossier local (chemins relatifs).
    static func scan(_ folder: String, ignore: [String]) -> [String: FileState] {
        let root = URL(fileURLWithPath: folder).standardizedFileURL
        var out: [String: FileState] = [:]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                      options: []) else { return out }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in en {
            let rel = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            if ignored(rel, ignore) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { en.skipDescendants() }
                continue
            }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard v?.isDirectory != true, let h = hash(url) else { continue }
            out[rel] = FileState(size: Int64(v?.fileSize ?? 0), hash: h)
        }
        return out
    }

    static func diff(local: [String: FileState], server: [String: FileState], deleteRemoved: Bool) -> Changes {
        var c = Changes()
        for (path, st) in local {
            if let s = server[path] {
                if s.hash != st.hash { c.modified.append(path) }
            } else {
                c.added.append(path)
            }
        }
        if deleteRemoved { c.removed = server.keys.filter { local[$0] == nil } }
        c.added.sort(); c.modified.sort(); c.removed.sort()
        return c
    }
}

// MARK: - Sauvegarde des sites, de l'historique et des versions de fichiers

@MainActor
final class DeployStore: ObservableObject {
    @Published var sites: [Site] { didSet { saveSites() } }
    let dir: URL

    init(dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AikoDeploy", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
        let file = self.dir.appendingPathComponent("sites.json")
        sites = (try? JSONDecoder().decode([Site].self, from: Data(contentsOf: file))) ?? []
    }

    private func saveSites() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(sites).write(to: dir.appendingPathComponent("sites.json"), options: .atomic)
    }

    private func historyURL(_ site: Site) -> URL { dir.appendingPathComponent("historique-\(site.id.uuidString).json") }
    func blobsDir(_ site: Site) -> URL { dir.appendingPathComponent("versions-\(site.id.uuidString)", isDirectory: true) }

    func history(_ site: Site) -> [Deployment] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Deployment].self, from: Data(contentsOf: historyURL(site)))) ?? []
    }

    func append(_ d: Deployment, to site: Site) {
        var h = history(site)
        h.insert(d, at: 0)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(Array(h.prefix(200))).write(to: historyURL(site), options: .atomic)
    }

    /// Dernier état connu du serveur.
    func serverState(_ site: Site) -> [String: FileState] { history(site).first?.manifest ?? [:] }

    /// Garde une copie de chaque version envoyée (rangée par empreinte : pas de doublons).
    func keepVersion(_ site: Site, file: URL, hash: String) {
        let dest = blobsDir(site).appendingPathComponent(hash)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.createDirectory(at: blobsDir(site), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: file, to: dest)
    }

    func versionFile(_ site: Site, hash: String) -> URL? {
        let u = blobsDir(site).appendingPathComponent(hash)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
