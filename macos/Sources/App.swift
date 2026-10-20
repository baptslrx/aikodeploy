import AppKit
import SwiftUI

@main
@MainActor
struct AikoDeployMain {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let test = SelfTest(outDir: URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "screenshots"))
            app.setActivationPolicy(.regular)
            DispatchQueue.main.async { test.run() }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    let store = DeployStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install(appName: "AikoDeploy")
        let w = NSWindow(contentViewController: NSHostingController(rootView: MainView(store: store, deployer: Deployer(store: store))))
        w.title = "AikoDeploy"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 980, height: 680))
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Interface

struct MainView: View {
    @ObservedObject var store: DeployStore
    @ObservedObject var deployer: Deployer
    @State var selection: UUID?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(Theme.line(scheme)).frame(width: 1)
            if let i = store.sites.firstIndex(where: { $0.id == selection }) {
                SiteView(site: $store.sites[i], store: store, deployer: deployer, onDelete: {
                    store.sites.remove(at: i)
                    selection = store.sites.first?.id
                })
                .id(store.sites[i].id)
            } else {
                empty
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.background(scheme))
        .onAppear { if selection == nil { selection = store.sites.first?.id } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.up.fill").foregroundStyle(Theme.accentText(scheme))
                Text("AikoDeploy").font(.system(size: 16, weight: .semibold))
            }
            .padding(14)
            Text("MES SITES").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText(scheme))
                .padding(.horizontal, 14)
            ForEach(store.sites) { s in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.system(size: 13, weight: s.id == selection ? .semibold : .regular))
                        Text(s.host.isEmpty ? "à configurer" : s.host).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(s.id == selection ? Theme.accentUI.opacity(0.18) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { selection = s.id }
                .padding(.horizontal, 6)
            }
            Button { addSite() } label: { Label("Ajouter un site", systemImage: "plus") }
                .buttonStyle(.borderless).padding(14)
            Spacer()
        }
        .background(Theme.surface(scheme).opacity(0.5))
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.and.arrow.up").font(.system(size: 40)).foregroundStyle(Theme.accentText(scheme))
            Text("Mets ton site en ligne en un clic").font(.system(size: 18, weight: .semibold))
            Text("Seuls les fichiers modifiés partent, et chaque mise en ligne peut être annulée.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Ajouter un site") { addSite() }.keyboardShortcut(.defaultAction).tint(Theme.accentUI)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addSite() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Choisir ce dossier"
        p.message = "Choisis le dossier de ton site"
        var s = Site()
        if p.runModal() == .OK, let u = p.url {
            s.folder = u.path
            s.name = u.lastPathComponent
        }
        store.sites.append(s)
        selection = s.id
    }
}

struct SiteView: View {
    @Binding var site: Site
    let store: DeployStore
    @ObservedObject var deployer: Deployer
    var onDelete: () -> Void
    @State private var password = ""
    @State private var changes = Changes()
    @State private var history: [Deployment] = []
    @State private var testResult: (Bool, String)?
    @State private var showSettings = false
    @Environment(\.colorScheme) private var scheme

    private var configured: Bool { !site.host.isEmpty && !site.user.isEmpty && !site.folder.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Nom du site", text: $site.name).textFieldStyle(.plain).font(.system(size: 22, weight: .semibold))
                    Spacer()
                    if !site.siteURL.isEmpty, let u = URL(string: site.siteURL.contains("://") ? site.siteURL : "https://" + site.siteURL) {
                        Button { NSWorkspace.shared.open(u) } label: { Label("Voir le site", systemImage: "safari") }
                    }
                }
                if !configured || showSettings { settings } else {
                    Button { showSettings = true } label: { Label("Réglages de connexion", systemImage: "gearshape") }
                        .buttonStyle(.borderless)
                }
                changesCard
                historyCard
            }
            .padding(22)
        }
        .onAppear {
            password = Keychain.get(site.id.uuidString) ?? ""
            reload()
        }
    }

    private func reload() {
        history = store.history(site)
        guard !site.folder.isEmpty else { return }
        Task { changes = await deployer.changes(site) }
    }

    // MARK: Réglages

    private var settings: some View {
        card("Connexion") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Dossier local")
                    HStack {
                        Text(site.folder.isEmpty ? "—" : site.folder).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choisir…") { pickFolder() }
                    }
                }
                GridRow {
                    label("Connexion")
                    Picker("", selection: Binding(get: { site.proto }, set: { site.proto = $0; site.port = $0.defaultPort })) {
                        ForEach(TransferProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 220)
                }
                GridRow {
                    label("Serveur")
                    HStack {
                        TextField("ftp.monhebergeur.com", text: $site.host)
                        Text("Port").foregroundStyle(.secondary)
                        TextField("21", value: $site.port, format: .number.grouping(.never)).frame(width: 60)
                    }
                }
                GridRow { label("Identifiant"); TextField("", text: $site.user) }
                GridRow {
                    label(site.proto == .sftp && !site.keyFile.isEmpty ? "Clé SSH" : "Mot de passe")
                    if site.proto == .sftp && !site.keyFile.isEmpty {
                        HStack {
                            Text(site.keyFile).font(.system(size: 12))
                            Button("Utiliser un mot de passe") { site.keyFile = "" }
                        }
                    } else {
                        HStack {
                            SecureField("Rangé dans le trousseau du Mac", text: $password)
                                .onChange(of: password) { Keychain.set(site.id.uuidString, $0) }
                            if site.proto == .sftp { Button("Clé SSH…") { pickKey() } }
                        }
                    }
                }
                GridRow { label("Dossier distant"); TextField("/www  ou  /public_html", text: $site.remotePath) }
                GridRow { label("Adresse du site"); TextField("https://monsite.fr (facultatif)", text: $site.siteURL) }
                GridRow {
                    label("Ne pas envoyer")
                    TextField("", text: Binding(get: { site.ignore.joined(separator: ", ") },
                                                set: { site.ignore = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                        .font(.system(size: 12).monospaced())
                }
                GridRow {
                    label("")
                    Toggle("Supprimer sur le serveur les fichiers supprimés ici", isOn: $site.deleteRemoved)
                        .onChange(of: site.deleteRemoved) { _ in reload() }
                }
            }
            HStack {
                Button("Tester la connexion") {
                    Task { testResult = await deployer.test(site) }
                }
                if let t = testResult {
                    Label(t.1, systemImage: t.0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(t.0 ? Theme.accentText(scheme) : .red).font(.system(size: 12))
                }
                Spacer()
                Button("Supprimer ce site", role: .destructive) { onDelete() }
                if configured { Button("OK") { showSettings = false; reload() } }
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        guard p.runModal() == .OK, let u = p.url else { return }
        site.folder = u.path
        reload()
    }

    private func pickKey() {
        let p = NSOpenPanel()
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        p.showsHiddenFiles = true
        guard p.runModal() == .OK, let u = p.url else { return }
        site.keyFile = u.path
    }

    // MARK: Changements

    private var changesCard: some View {
        card("Prochaine mise en ligne") {
            if site.folder.isEmpty {
                Text("Choisis d'abord le dossier du site.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else if changes.isEmpty {
                Label("Le site en ligne est à jour.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accentText(scheme)).font(.system(size: 13, weight: .medium))
            } else {
                HStack(spacing: 14) {
                    stat(changes.added.count, "nouveau", "plus.circle.fill", Theme.accentText(scheme))
                    stat(changes.modified.count, "modifié", "pencil.circle.fill", .orange)
                    if site.deleteRemoved { stat(changes.removed.count, "supprimé", "minus.circle.fill", .red) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array((changes.added.map { ("+", $0) } + changes.modified.map { ("~", $0) }
                                   + changes.removed.map { ("−", $0) }).prefix(14).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(item.0).font(.system(size: 12, weight: .bold).monospaced())
                                .foregroundStyle(item.0 == "+" ? Theme.accentText(scheme) : item.0 == "~" ? .orange : .red)
                            Text(item.1).font(.system(size: 12).monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    let total = changes.added.count + changes.modified.count + changes.removed.count
                    if total > 14 { Text("… et \(total - 14) autres").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button { reload() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                if history.isEmpty && !changes.isEmpty && configured {
                    Button("Le site est déjà en ligne") { Task { await deployer.markAsDeployed(site); reload() } }
                        .help("N'envoie rien maintenant : seules les prochaines modifications partiront")
                }
                Spacer()
                if deployer.busy { ProgressView().controlSize(.small) }
                Text(deployer.status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Button {
                    Task { await deployer.deploy(site); reload() }
                } label: { Label("Mettre en ligne", systemImage: "arrow.up.circle.fill") }
                    .keyboardShortcut(.defaultAction).tint(Theme.accentUI).controlSize(.large)
                    .disabled(!configured || changes.isEmpty || deployer.busy)
            }
        }
    }

    private func stat(_ n: Int, _ word: String, _ icon: String, _ color: Color) -> some View {
        Label("\(n) \(word)\(n > 1 ? "s" : "")", systemImage: icon).foregroundStyle(color).font(.system(size: 13, weight: .medium))
    }

    // MARK: Historique

    private var historyCard: some View {
        card("Historique") {
            if history.isEmpty {
                Text("Aucune mise en ligne pour l'instant.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(history.prefix(20).enumerated()), id: \.element.id) { i, d in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated).year().hour().minute())).font(.system(size: 12, weight: .medium))
                        Text(d.note.isEmpty ? "\(d.uploaded.count) envoyé(s), \(d.deleted.count) supprimé(s)" : d.note)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if i == 0 {
                        Text("En ligne").font(.system(size: 10, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentUI.opacity(0.2))).foregroundStyle(Theme.accentText(scheme))
                    } else {
                        Button("Revenir à cette version") { confirmRollback(d) }.disabled(deployer.busy)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func confirmRollback(_ d: Deployment) {
        let a = NSAlert()
        a.messageText = "Remettre en ligne la version du \(d.date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated).year().hour().minute())) ?"
        a.informativeText = "Les fichiers du serveur reviennent tels qu'ils étaient à ce moment-là. Tes fichiers sur le Mac ne changent pas."
        a.addButton(withTitle: "Revenir")
        a.addButton(withTitle: "Annuler")
        if a.runModal() == .alertFirstButtonReturn {
            Task { await deployer.rollback(site, to: d); reload() }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText(scheme))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line(scheme)))
        }
    }
}
