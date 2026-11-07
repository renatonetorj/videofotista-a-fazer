// Videofotista A Fazer
// Casca nativa do Mac: ícone na barra de menu, janela com a lista,
// abre sozinho ao ligar o Mac, salva os dados e faz backup diário.

import Cocoa
import WebKit
import UserNotifications

let NOME_APP = "Videofotista A Fazer"
let ID_APP = "br.com.renatoneto.afazer"
let DIAS_DE_BACKUP = 90

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, UNUserNotificationCenterDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    let fm = FileManager.default

    // lembretes vindos da tela: id, texto, quando ("yyyy-MM-dd HH:mm")
    var lembretes: [(id: String, texto: String, quando: Date)] = []
    var notificacoesLiberadas = false
    var pediuPermissao = false
    var disparados = Set<String>()
    var relogio: Timer?

    // ~/Library/Application Support/Videofotista A Fazer/dados.json
    lazy var pastaDados: URL = {
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(NOME_APP, isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    var arquivoDados: URL { pastaDados.appendingPathComponent("dados.json") }

    // ~/Documents/Videofotista A Fazer - Backups/
    lazy var pastaBackups: URL = {
        let u = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(NOME_APP) - Backups", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    // Pasta no Google Drive (Google Drive para computador), se existir:
    // ~/Library/CloudStorage/GoogleDrive-<conta>/Meu Drive/Videofotista A Fazer - Backups/
    lazy var pastaDriveAuto: URL? = {
        let nuvem = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let contas = try? fm.contentsOfDirectory(at: nuvem, includingPropertiesForKeys: nil) else { return nil }
        let drives = contas.filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }
            .sorted { a, b in
                let pa = a.lastPathComponent.lowercased().contains("renatonetorj")
                let pb = b.lastPathComponent.lowercased().contains("renatonetorj")
                return pa && !pb
            }
        for d in drives {
            for nome in ["Meu Drive", "My Drive"] {
                let raiz = d.appendingPathComponent(nome, isDirectory: true)
                var ehPasta: ObjCBool = false
                if fm.fileExists(atPath: raiz.path, isDirectory: &ehPasta), ehPasta.boolValue {
                    let u = raiz.appendingPathComponent("\(NOME_APP) - Backups", isDirectory: true)
                    try? fm.createDirectory(at: u, withIntermediateDirectories: true)
                    return u
                }
            }
        }
        return nil
    }()

    // pasta escolhida em Preferências (se houver) ou o Google Drive automático
    var pastaBackupExtra: URL? {
        if let p = UserDefaults.standard.string(forKey: "pastaBackupEscolhida") {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        return pastaDriveAuto
    }

    var todasPastasBackup: [URL] {
        var l = [pastaBackups]
        if let d = pastaBackupExtra, d.standardizedFileURL != pastaBackups.standardizedFileURL { l.append(d) }
        return l
    }

    func jsonPastaBackup() -> String {
        var obj: [String: Any] = ["escolhida": NSNull(), "drive": NSNull()]
        if let e = UserDefaults.standard.string(forKey: "pastaBackupEscolhida") { obj["escolhida"] = e }
        if let d = pastaDriveAuto { obj["drive"] = d.path }
        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { return s }
        return "null"
    }

    var arquivoAgente: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(ID_APP).plist")
    }

    // MARK: - Início

    func applicationDidFinishLaunching(_ notification: Notification) {
        let def = UserDefaults.standard
        if !def.bool(forKey: "jaConfigurou") {
            ligarAberturaAutomatica()
            def.set(true, forKey: "jaConfigurou")
        } else if fm.fileExists(atPath: arquivoAgente.path) {
            // mantém o caminho certo caso o app tenha mudado de lugar
            ligarAberturaAutomatica()
        }

        montarMenuPrincipal()
        montarBarraDeMenu()
        montarJanela()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(acordou),
            name: NSWorkspace.didWakeNotification, object: nil)

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().getNotificationSettings { cfg in
            DispatchQueue.main.async {
                self.notificacoesLiberadas = cfg.authorizationStatus == .authorized || cfg.authorizationStatus == .provisional
            }
        }
        // plano B: se as notificações estiverem bloqueadas, o próprio app avisa
        relogio = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.conferirLembretes()
        }

        mostrarJanela()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mostrarJanela()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Menu principal (necessário para Copiar/Colar funcionarem nos campos de texto)
    func montarMenuPrincipal() {
        let principal = NSMenu()

        let itemApp = NSMenuItem()
        principal.addItem(itemApp)
        let menuApp = NSMenu(title: NOME_APP)
        menuApp.addItem(withTitle: "Preferências…", action: #selector(abrirPreferencias), keyEquivalent: ",")
        menuApp.addItem(withTitle: "Esconder janela", action: #selector(esconderJanela), keyEquivalent: "w")
        menuApp.addItem(.separator())
        menuApp.addItem(withTitle: "Sair do \(NOME_APP)", action: #selector(sair), keyEquivalent: "q")
        for i in menuApp.items { i.target = self }
        itemApp.submenu = menuApp

        let itemEditar = NSMenuItem()
        principal.addItem(itemEditar)
        let editar = NSMenu(title: "Editar")
        editar.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        editar.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "Z")
        editar.addItem(.separator())
        editar.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editar.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editar.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editar.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        itemEditar.submenu = editar

        NSApp.mainMenu = principal
    }

    // MARK: - Barra de menu

    func montarBarraDeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let botao = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "checklist", accessibilityDescription: NOME_APP)
            ?? NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: NOME_APP)
        img?.isTemplate = true
        botao.image = img
        botao.imagePosition = .imageLeading
        botao.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        botao.target = self
        botao.action = #selector(cliqueNaBarra(_:))
        botao.sendAction(on: [.leftMouseUp, .rightMouseUp])
        botao.toolTip = NOME_APP
    }

    @objc func cliqueNaBarra(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            mostrarMenuDaBarra()
        } else {
            alternarJanela()
        }
    }

    func mostrarMenuDaBarra() {
        let m = NSMenu()
        m.addItem(withTitle: "Abrir", action: #selector(mostrarJanela), keyEquivalent: "")
        m.addItem(withTitle: "Preferências…", action: #selector(abrirPreferencias), keyEquivalent: "")
        let auto = NSMenuItem(title: "Abrir ao ligar o Mac", action: #selector(alternarAbertura), keyEquivalent: "")
        auto.state = fm.fileExists(atPath: arquivoAgente.path) ? .on : .off
        m.addItem(auto)
        m.addItem(withTitle: "Abrir pasta de backups", action: #selector(abrirPastaBackups), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Sair do \(NOME_APP)", action: #selector(sair), keyEquivalent: "")
        for i in m.items { i.target = self }
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func atualizarContador(_ n: Int) {
        statusItem.button?.title = n > 0 ? " \(n)" : ""
    }

    // MARK: - Janela

    func montarJanela() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "app")
        let dados = lerDados()
        let auto = fm.fileExists(atPath: arquivoAgente.path) ? "true" : "false"
        let js = "window.__NATIVO__ = true; window.__DADOS__ = \(dados); window.__PASTA_BACKUP__ = \(jsonPastaBackup()); window.__AUTO__ = \(auto);"
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = NOME_APP
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 420)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.353, alpha: 1)
        window.delegate = self
        window.contentView = webView
        if !window.setFrameUsingName("JanelaPrincipal") { window.center() }
        window.setFrameAutosaveName("JanelaPrincipal")

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // Botão vermelho só esconde. Para fechar de vez: Sair (Cmd+Q ou menu da barra).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func mostrarJanela() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        webView.evaluateJavaScript("window.verificarDia && window.verificarDia(); window.focarEntrada && window.focarEntrada();", completionHandler: nil)
    }

    @objc func abrirPreferencias() {
        mostrarJanela()
        webView.evaluateJavaScript("window.abrirPreferencias && window.abrirPreferencias();", completionHandler: nil)
    }

    @objc func esconderJanela() {
        window.orderOut(nil)
    }

    func alternarJanela() {
        if window.isVisible && window.isKeyWindow && NSApp.isActive {
            esconderJanela()
        } else {
            mostrarJanela()
        }
    }

    @objc func acordou() {
        webView.evaluateJavaScript("window.verificarDia && window.verificarDia();", completionHandler: nil)
    }

    @objc func sair() {
        NSApp.terminate(nil)
    }

    // MARK: - Dados e backup

    func jsonValido(_ s: String) -> Bool {
        guard let d = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) != nil
    }

    func lerDados() -> String {
        if let s = try? String(contentsOf: arquivoDados, encoding: .utf8), jsonValido(s) {
            return s
        }
        // arquivo principal sumiu ou estragou: tenta o backup mais recente
        var backups: [URL] = []
        for pasta in todasPastasBackup {
            if let lista = try? fm.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil) {
                backups += lista.filter { $0.lastPathComponent.hasPrefix("backup-") && $0.pathExtension == "json" }
            }
        }
        backups.sort { $0.lastPathComponent > $1.lastPathComponent }
        for b in backups {
            if let s = try? String(contentsOf: b, encoding: .utf8), jsonValido(s) { return s }
        }
        return "null"
    }

    func hoje() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func salvar(_ json: String) {
        guard jsonValido(json) else { return }
        do {
            try json.write(to: arquivoDados, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Erro ao salvar: \(error)")
        }
        // um arquivo por dia, sempre com o estado mais recente daquele dia,
        // em Documentos e no Google Drive
        for pasta in todasPastasBackup {
            let backup = pasta.appendingPathComponent("backup-\(hoje()).json")
            try? json.write(to: backup, atomically: true, encoding: .utf8)
            limparBackupsAntigos(em: pasta)
        }
    }

    func limparBackupsAntigos(em pasta: URL) {
        guard let lista = try? fm.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil) else { return }
        let backups = lista.filter { $0.lastPathComponent.hasPrefix("backup-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if backups.count > DIAS_DE_BACKUP {
            for b in backups[DIAS_DE_BACKUP...] { try? fm.removeItem(at: b) }
        }
    }

    @objc func abrirPastaBackups() {
        NSWorkspace.shared.open(pastaBackupExtra ?? pastaBackups)
    }

    func exportar(_ json: String) {
        let painel = NSSavePanel()
        painel.nameFieldStringValue = "\(NOME_APP) - backup \(hoje()).json"
        painel.directoryURL = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        if painel.runModal() == .OK, let url = painel.url {
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                avisar("Backup exportado")
            } catch {
                avisar("Não consegui salvar o arquivo")
            }
        }
    }

    func importar() {
        let painel = NSOpenPanel()
        painel.allowsMultipleSelection = false
        painel.canChooseDirectories = false
        painel.directoryURL = pastaBackups
        NSApp.activate(ignoringOtherApps: true)
        guard painel.runModal() == .OK, let url = painel.url else { return }
        guard let s = try? String(contentsOf: url, encoding: .utf8), jsonValido(s) else {
            avisar("Esse arquivo não é um backup válido")
            return
        }
        // guarda uma cópia de segurança do estado atual antes de trocar
        if let atual = try? String(contentsOf: arquivoDados, encoding: .utf8) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH'h'mm"
            let seg = pastaBackups.appendingPathComponent("antes-de-importar \(f.string(from: Date())).json")
            try? atual.write(to: seg, atomically: true, encoding: .utf8)
        }
        webView.evaluateJavaScript("window.receberImportacao(\(s));", completionHandler: nil)
    }

    func escolherPastaBackup() {
        let painel = NSOpenPanel()
        painel.canChooseDirectories = true
        painel.canChooseFiles = false
        painel.canCreateDirectories = true
        painel.allowsMultipleSelection = false
        painel.prompt = "Usar esta pasta"
        painel.message = "Escolha a pasta extra para o backup diário"
        NSApp.activate(ignoringOtherApps: true)
        guard painel.runModal() == .OK, let url = painel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "pastaBackupEscolhida")
        if let atual = try? String(contentsOf: arquivoDados, encoding: .utf8) { salvar(atual) }
        avisarPastaBackup()
        avisar("Pasta de backup trocada")
    }

    func avisarPastaBackup() {
        webView.evaluateJavaScript("window.atualizarPastaBackup && window.atualizarPastaBackup(\(jsonPastaBackup()));", completionHandler: nil)
    }

    func avisar(_ msg: String) {
        let seguro = msg.replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window.avisar && window.avisar('\(seguro)');", completionHandler: nil)
    }

    // MARK: - Conversa com a tela

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let corpo = message.body as? [String: Any], let acao = corpo["acao"] as? String else { return }
        switch acao {
        case "salvar":
            if let json = corpo["json"] as? String { salvar(json) }
        case "contador":
            if let n = corpo["n"] as? NSNumber { atualizarContador(n.intValue) }
        case "exportar":
            if let json = corpo["json"] as? String { exportar(json) }
        case "importar":
            importar()
        case "pastaBackups":
            abrirPastaBackups()
        case "lembretes":
            receberLembretes(corpo["lista"] as? [[String: Any]] ?? [])
        case "config":
            let porCima = (corpo["porCima"] as? NSNumber)?.boolValue ?? false
            window.level = porCima ? .floating : .normal
        case "som":
            NSSound(named: NSSound.Name("Glass"))?.play()
        case "copiar":
            if let t = corpo["texto"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
        case "escolherPastaBackup":
            escolherPastaBackup()
        case "pastaBackupAuto":
            UserDefaults.standard.removeObject(forKey: "pastaBackupEscolhida")
            avisarPastaBackup()
        case "abrirAoLigar":
            let v = (corpo["valor"] as? NSNumber)?.boolValue ?? false
            if v { ligarAberturaAutomatica() } else { try? fm.removeItem(at: arquivoAgente) }
        default:
            break
        }
    }

    // links externos (se houver) abrem no navegador
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - Lembretes

    func formatoLembrete() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }

    func receberLembretes(_ lista: [[String: Any]]) {
        let f = formatoLembrete()
        lembretes = lista.compactMap { item -> (id: String, texto: String, quando: Date)? in
            guard let id = item["id"] as? String, let texto = item["texto"] as? String,
                  let q = item["quando"] as? String, let d = f.date(from: q) else { return nil }
            return (id: id, texto: texto, quando: d)
        }
        let agora = Date()
        if !pediuPermissao && lembretes.contains(where: { $0.quando > agora }) {
            pediuPermissao = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                DispatchQueue.main.async {
                    self.notificacoesLiberadas = ok
                    self.agendarNotificacoes()
                }
            }
        }
        agendarNotificacoes()
    }

    func agendarNotificacoes() {
        let central = UNUserNotificationCenter.current()
        central.removeAllPendingNotificationRequests()
        guard notificacoesLiberadas else { return }
        let agora = Date()
        for l in lembretes where l.quando > agora {
            let conteudo = UNMutableNotificationContent()
            conteudo.title = "⏰ " + NOME_APP
            conteudo.body = l.texto
            conteudo.sound = UNNotificationSound.default
            conteudo.userInfo = ["id": l.id]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: l.quando)
            let gatilho = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let pedido = UNNotificationRequest(identifier: l.id, content: conteudo, trigger: gatilho)
            central.add(pedido, withCompletionHandler: nil)
        }
    }

    // plano B, só quando o Mac não deixa mostrar notificações
    func conferirLembretes() {
        guard !notificacoesLiberadas else { return }
        let agora = Date()
        for l in lembretes {
            let chave = l.id + "\(l.quando.timeIntervalSince1970)"
            let atraso = agora.timeIntervalSince(l.quando)
            if atraso >= 0 && atraso < 180 && !disparados.contains(chave) {
                disparados.insert(chave)
                NSSound(named: NSSound.Name("Glass"))?.play()
                mostrarJanela()
                chamarAlarme(l.id)
            }
        }
    }

    func chamarAlarme(_ id: String) {
        let seguro = id.replacingOccurrences(of: "'", with: "")
        webView.evaluateJavaScript("window.alarme && window.alarme('\(seguro)');", completionHandler: nil)
    }

    // notificação chegando com o app aberto: mostra mesmo assim
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
        if let id = notification.request.content.userInfo["id"] as? String {
            DispatchQueue.main.async { self.chamarAlarme(id) }
        }
    }

    // clicou na notificação: abre a janela na tarefa
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String
        DispatchQueue.main.async {
            self.mostrarJanela()
            if let id = id { self.chamarAlarme(id) }
        }
        completionHandler()
    }

    // MARK: - Abrir ao ligar o Mac

    func ligarAberturaAutomatica() {
        let plist: [String: Any] = [
            "Label": ID_APP,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true
        ]
        try? fm.createDirectory(at: arquivoAgente.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = (plist as NSDictionary).write(to: arquivoAgente, atomically: true)
    }

    @objc func alternarAbertura() {
        if fm.fileExists(atPath: arquivoAgente.path) {
            try? fm.removeItem(at: arquivoAgente)
        } else {
            ligarAberturaAutomatica()
        }
        let v = fm.fileExists(atPath: arquivoAgente.path) ? "true" : "false"
        webView.evaluateJavaScript("window.atualizarAbrirAoLigar && window.atualizarAbrirAoLigar(\(v));", completionHandler: nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
