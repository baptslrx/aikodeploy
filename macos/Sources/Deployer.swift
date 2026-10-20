import Foundation

/// Calcule ce qui doit partir, l'envoie, et tient l'historique (avec retour arrière).
@MainActor
final class Deployer: ObservableObject {
    let store: DeployStore
    @Published var busy = false
    @Published var status = ""
    @Published var lastReport: TransferReport?

    init(store: DeployStore) { self.store = store }

    func password(_ site: Site) -> String { Keychain.get(site.id.uuidString) ?? "" }

    func changes(_ site: Site) async -> Changes {
        let server = store.serverState(site)
        return await Task.detached {
            Sync.diff(local: Sync.scan(site.folder, ignore: site.ignore), server: server, deleteRemoved: site.deleteRemoved)
        }.value
    }

    func test(_ site: Site) async -> (Bool, String) {
        let t = Transport(site: site, password: password(site))
        return await Task.detached { t.test() }.value
    }

    /// Mise en ligne des fichiers modifiés. Renvoie un message à afficher.
    @discardableResult
    func deploy(_ site: Site, note: String = "") async -> String {
        busy = true
        defer { busy = false }
        status = "Analyse du dossier…"
        let server = store.serverState(site)
        let t = Transport(site: site, password: password(site))
        let (local, changes) = await Task.detached { () -> ([String: FileState], Changes) in
            let local = Sync.scan(site.folder, ignore: site.ignore)
            return (local, Sync.diff(local: local, server: server, deleteRemoved: site.deleteRemoved))
        }.value
        guard !changes.isEmpty else { status = "Rien à envoyer : le site est à jour."; return status }
        status = "Envoi de \(changes.uploads.count) fichier\(changes.uploads.count > 1 ? "s" : "")…"
        let root = URL(fileURLWithPath: site.folder)
        let uploads = changes.uploads.map { (rel: $0, local: root.appendingPathComponent($0)) }
        let removed = changes.removed
        let report = await Task.detached { t.send(uploads: uploads, deletes: removed) }.value
        lastReport = report
        return record(site, before: server, local: local, report: report, note: note)
    }

    private func record(_ site: Site, before: [String: FileState], local: [String: FileState],
                        report: TransferReport, note: String) -> String {
        var manifest = before
        let root = URL(fileURLWithPath: site.folder)
        for rel in report.uploaded {
            if let st = local[rel] {
                manifest[rel] = st
                store.keepVersion(site, file: root.appendingPathComponent(rel), hash: st.hash)
            }
        }
        for rel in report.deleted { manifest[rel] = nil }
        if !report.uploaded.isEmpty || !report.deleted.isEmpty {
            store.append(Deployment(manifest: manifest, uploaded: report.uploaded, deleted: report.deleted, note: note), to: site)
        }
        var msg = "\(report.uploaded.count) fichier\(report.uploaded.count > 1 ? "s" : "") envoyé\(report.uploaded.count > 1 ? "s" : "")"
        if !report.deleted.isEmpty { msg += ", \(report.deleted.count) supprimé\(report.deleted.count > 1 ? "s" : "")" }
        if !report.failed.isEmpty {
            msg += " — \(report.failed.count) échec\(report.failed.count > 1 ? "s" : "") : " + (report.failed.values.first ?? "")
        }
        status = msg
        return msg
    }

    /// Remet le serveur dans l'état d'une mise en ligne précédente.
    @discardableResult
    func rollback(_ site: Site, to target: Deployment) async -> String {
        busy = true
        defer { busy = false }
        let current = store.serverState(site)
        var uploads: [(rel: String, local: URL)] = []
        var missing: [String] = []
        for (rel, st) in target.manifest where current[rel]?.hash != st.hash {
            if let f = store.versionFile(site, hash: st.hash) { uploads.append((rel, f)) } else { missing.append(rel) }
        }
        let deletes = current.keys.filter { target.manifest[$0] == nil }.sorted()
        guard !uploads.isEmpty || !deletes.isEmpty else { status = "Le serveur est déjà dans cet état."; return status }
        status = "Retour en arrière…"
        let t = Transport(site: site, password: password(site))
        let ups = uploads
        let report = await Task.detached { t.send(uploads: ups, deletes: deletes) }.value
        lastReport = report
        var manifest = current
        for rel in report.uploaded { manifest[rel] = target.manifest[rel] }
        for rel in report.deleted { manifest[rel] = nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMMM 'à' HH:mm"
        store.append(Deployment(manifest: manifest, uploaded: report.uploaded, deleted: report.deleted,
                                note: "Retour à la version du \(f.string(from: target.date))"), to: site)
        status = "Version du \(f.string(from: target.date)) remise en ligne"
            + (report.failed.isEmpty ? "" : " — \(report.failed.count) échec(s)")
            + (missing.isEmpty ? "" : " — \(missing.count) fichier(s) sans copie")
        return status
    }

    /// Le site est déjà en ligne : on considère l'état actuel comme envoyé, sans rien transférer.
    func markAsDeployed(_ site: Site) async {
        let local = await Task.detached { Sync.scan(site.folder, ignore: site.ignore) }.value
        let root = URL(fileURLWithPath: site.folder)
        for (rel, st) in local { store.keepVersion(site, file: root.appendingPathComponent(rel), hash: st.hash) }
        store.append(Deployment(manifest: local, uploaded: [], deleted: [], note: "Déjà en ligne (rien envoyé)"), to: site)
        status = "C'est noté : seules les prochaines modifications partiront."
    }
}
