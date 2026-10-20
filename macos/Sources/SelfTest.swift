import AppKit
import SwiftUI

/// `AikoDeploy --selftest <dossier>` : vraie mise en ligne vers un serveur FTP (et SFTP) local, modifications,
/// suppression, retour arrière. Le serveur de test est lancé par le workflow (variables AIKO_*).
@MainActor
final class SelfTest {
    let outDir: URL
    private var failures: [String] = []
    private var report: [String] = []
    private let ci = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil
    private let env = ProcessInfo.processInfo.environment

    init(outDir: URL) { self.outDir = outDir }

    func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            await steps()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { [weak self] in
            MainActor.assumeIsolated { self?.check(false, "le test a dépassé 4 minutes"); self?.finish() }
        }
    }

    private func log(_ s: String) { print(s); fflush(stdout); report.append(s) }
    private func check(_ ok: Bool, _ what: String) {
        log((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { failures.append(what); if ci { print("::error title=Test::\(what)") } }
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func write(_ path: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Fichiers présents sur le « serveur » (on lit directement son dossier).
    private func serverFiles(_ root: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let en = FileManager.default.enumerator(atPath: root) else { return out }
        for case let rel as String in en {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root + "/" + rel, isDirectory: &isDir), !isDir.boolValue {
                out[rel] = (try? String(contentsOfFile: root + "/" + rel, encoding: .utf8)) ?? ""
            }
        }
        return out
    }

    private func steps() async {
        log("== Règles « ne pas envoyer »")
        let ig = Sync.defaultIgnore
        check(Sync.ignored("node_modules/x/y.js", ig) && Sync.ignored(".env.production", ig) && Sync.ignored("a/.DS_Store", ig)
              && Sync.ignored(".git/config", ig), "node_modules, .env, .git, .DS_Store ignorés")
        check(!Sync.ignored("index.php", ig) && !Sync.ignored("css/style.css", ig) && !Sync.ignored("environment.php", ig),
              "les vrais fichiers du site partent")
        check(Sync.ignored("uploads/photo.jpg", ["uploads/"]) && !Sync.ignored("img/uploads.png", ["uploads/"]),
              "motif de dossier")

        var targets: [(String, Site, String)] = []
        if let port = env["AIKO_FTP_PORT"].flatMap(Int.init), let root = env["AIKO_FTP_ROOT"] {
            var s = Site()
            s.name = "Test FTP"; s.proto = .ftp; s.host = "127.0.0.1"; s.port = port; s.user = "aiko"; s.remotePath = "/www"
            targets.append(("FTP", s, root + "/www"))
            Keychain.set(s.id.uuidString, "motdepasse-test")
        }
        if let user = env["AIKO_SFTP_USER"], let key = env["AIKO_SFTP_KEY"], let root = env["AIKO_SFTP_ROOT"] {
            var s = Site()
            s.name = "Test SFTP"; s.proto = .sftp; s.host = "127.0.0.1"; s.port = 22; s.user = user; s.keyFile = key
            s.remotePath = root
            targets.append(("SFTP", s, root))
        }
        if targets.isEmpty { check(false, "aucun serveur de test disponible") }

        for (label, base, serverRoot) in targets {
            log("== \(label)")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aikodeploy-\(UUID().uuidString)")
            let local = tmp.appendingPathComponent("site").path
            write(local + "/index.php", "<?php echo 'v1';")
            write(local + "/css/style.css", "h1{color:#7DC8FF}")
            write(local + "/img/mon logo é.svg", "<svg/>")
            write(local + "/a supprimer.html", "bientôt supprimé")
            write(local + "/node_modules/lib/index.js", "ne doit pas partir")
            write(local + "/.env", "DB_PASSWORD=secret")
            write(local + "/.git/config", "x")
            try? FileManager.default.createDirectory(atPath: serverRoot, withIntermediateDirectories: true)

            let store = DeployStore(dir: tmp.appendingPathComponent("donnees"))
            var site = base
            site.folder = local
            site.deleteRemoved = true
            store.sites = [site]
            let dep = Deployer(store: store)

            let t = await dep.test(site)
            check(t.0, "\(label) : tester la connexion → \(t.1)")
            var ch = await dep.changes(site)
            check(ch.added.count == 4 && ch.modified.isEmpty, "\(label) : 1re fois, 4 fichiers à envoyer (\(ch.added))")
            var msg = await dep.deploy(site)
            log("   \(msg)")
            var files = serverFiles(serverRoot)
            check(files["index.php"] == "<?php echo 'v1';" && files["img/mon logo é.svg"] == "<svg/>" && files.count == 4,
                  "\(label) : site en ligne, accents et espaces compris (\(files.keys.sorted()))")
            check(files.keys.allSatisfy { !$0.contains("node_modules") && !$0.contains(".env") && !$0.contains(".git") },
                  "\(label) : rien de privé envoyé")
            ch = await dep.changes(site)
            check(ch.isEmpty, "\(label) : juste après, plus rien à envoyer")

            // Modifications
            write(local + "/index.php", "<?php echo 'v2';")
            write(local + "/contact.php", "<?php // nouveau")
            try? FileManager.default.removeItem(atPath: local + "/a supprimer.html")
            ch = await dep.changes(site)
            check(ch.modified == ["index.php"] && ch.added == ["contact.php"] && ch.removed == ["a supprimer.html"],
                  "\(label) : 1 modifié, 1 nouveau, 1 supprimé détectés")
            msg = await dep.deploy(site)
            log("   \(msg)")
            files = serverFiles(serverRoot)
            check(files["index.php"] == "<?php echo 'v2';" && files["contact.php"] != nil && files["a supprimer.html"] == nil,
                  "\(label) : seules les modifications sont parties")
            check((dep.lastReport?.uploaded.count ?? 0) == 2, "\(label) : 2 fichiers envoyés, pas tout le site")

            // Retour arrière vers la première version
            let history = store.history(site)
            check(history.count == 2, "\(label) : 2 mises en ligne dans l'historique")
            if let first = history.last {
                msg = await dep.rollback(site, to: first)
                log("   \(msg)")
                files = serverFiles(serverRoot)
                check(files["index.php"] == "<?php echo 'v1';" && files["a supprimer.html"] == "bientôt supprimé"
                      && files["contact.php"] == nil, "\(label) : retour arrière, le serveur est revenu à la 1re version")
            }
            if label == "FTP" {
                await snapshot(MainView(store: store, deployer: dep, selection: store.sites.first?.id), name: "site")
                var bad = site
                bad.port = 1
                let t2 = await Deployer(store: store).test(bad)
                check(!t2.0 && t2.1.contains("ne répond pas"), "mauvais port : message clair (« \(t2.1) »)")
            }
            Keychain.set(site.id.uuidString, "")
            try? FileManager.default.removeItem(at: tmp)
        }
        let emptyStore = DeployStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("aikodeploy-vide-\(UUID().uuidString)"))
        await snapshot(MainView(store: emptyStore, deployer: Deployer(store: emptyStore)), name: "accueil")
    }

    private func snapshot<V: View>(_ view: V, name: String) async {
        for dark in [true, false] {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 980, height: 680)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = host
            w.orderFrontRegardless()
            await sleep(1.2)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = "\(name)-\(dark ? "sombre" : "clair").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(file))
                log("   capture \(file)")
            }
            w.orderOut(nil)
        }
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        log(failures.isEmpty ? "\nTout est OK" : "\nÉCHECS :\n" + failures.joined(separator: "\n"))
        try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("rapport.txt"), atomically: true, encoding: .utf8)
        exit(failures.isEmpty ? 0 : 1)
    }
}
