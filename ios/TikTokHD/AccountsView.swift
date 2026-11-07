import SwiftUI
import WebKit

/// Accounts tab: several TikTok accounts at once, each in its own container
/// (separate cookies and storage), so every account stays logged in.
/// The top bar acts on all accounts at once: open one link everywhere, or
/// hand one patched video to every account's TikTok Studio upload box.
/// Containers need iOS 17; on iOS 16 the tab just says so.
struct AccountsView: View {
    var body: some View {
        if #available(iOS 17.0, *) {
            AccountsContainerView()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.2.slash").font(.largeTitle)
                Text("Multiple accounts needs iOS 17 or newer.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

struct TTAccount: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

/// One account: its own web view with its own data store.
@available(iOS 17.0, *)
@MainActor
final class TTContainer: NSObject, WKUIDelegate {
    let id: UUID
    let web: WKWebView
    var onStatus: ((String) -> Void)?
    private var busy = false

    init(id: UUID) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        self.id = id
        self.web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        apply(desktop: false)
        _ = web.load(URLRequest(url: Browser.home))
    }

    private func say(_ s: String) { onStatus?(s) }

    /// Mobile site normally; TikTok Studio needs the desktop site.
    private func apply(desktop d: Bool) {
        web.customUserAgent = d ? Browser.macUA : nil
        web.configuration.defaultWebpagePreferences.preferredContentMode = d ? .desktop : .mobile
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: Browser.handoverJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if d {
            ucc.addUserScript(WKUserScript(source: Browser.desktopJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    func open(_ url: URL) {
        apply(desktop: url.path.hasPrefix("/tiktokstudio"))
        _ = web.load(URLRequest(url: url))
    }

    // Links that open a new window open in the same page instead.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url {
            DispatchQueue.main.async { _ = webView.load(URLRequest(url: url)) }
        }
        return nil
    }

    private func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        let r: Any? = try await web.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        return r
    }

    private func isDone() async -> Bool {
        ((try? await js("return window.__thdDone === true;")) as? Bool) == true
    }

    /// Opens TikTok Studio in this account and puts the video in its upload box.
    func upload(_ file: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        say("Opening Studio…")
        open(Browser.studio)

        var ready = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let s = (try? await js("return location.pathname + '|' + (!!(window.__thd && document.body && document.body.innerText.length > 50));")) as? String ?? ""
            if s.hasPrefix("/tiktokstudio") && s.hasSuffix("|true") { ready = true; break }
        }
        guard ready else {
            say("Studio did not open. Log in to this account first, then try again.")
            return
        }

        do {
            let total = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            let fh = try FileHandle(forReadingFrom: file)
            defer { try? fh.close() }
            _ = try await js("window.__thdParts = []; return true;")
            var sent = 0
            while let chunk = try fh.read(upToCount: 3 << 20), !chunk.isEmpty {
                _ = try await js("""
                    var bin = atob(b64), a = new Uint8Array(bin.length);
                    for (var i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
                    window.__thdParts.push(new Blob([a]));
                    return a.length;
                    """, ["b64": chunk.base64EncodedString()])
                sent += chunk.count
                say("Handing the video over… \(total > 0 ? sent * 100 / total : 0)%")
            }
            let r = try await js("""
                var f = new File(window.__thdParts, name, { type: 'video/mp4', lastModified: Date.now() });
                window.__thdParts = null;
                if (f.size !== size) return 'size ' + f.size;
                return window.__thd.offer(f);
                """, ["name": file.lastPathComponent, "size": total]) as? String ?? "?"
            if r.hasPrefix("size") {
                say("The video arrived damaged (\(r)). Try again.")
                return
            }
            let ok = "Video is in the upload box (\(total / 1_000_000) MB, unchanged)."
            if r == "filled" { say(ok); return }
            if await isDone() { say(ok); return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if await isDone() { say(ok); return }
            _ = try? await js("if (window.__thdFile) window.__thd.drop(window.__thdFile); return true;")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if await isDone() { say(ok); return }
            say("Open this account and tap Select video: the video goes in instead of the file picker.")
        } catch {
            say("Could not hand it over: \(error.localizedDescription)")
        }
    }
}

@available(iOS 17.0, *)
@MainActor
final class TTAccountStore: ObservableObject {
    @Published var accounts: [TTAccount] = [] { didSet { save() } }
    @Published var selected: UUID?
    @Published var statuses: [UUID: String] = [:]
    private var containers: [UUID: TTContainer] = [:]
    private let key = "tiktokAccounts"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([TTAccount].self, from: data) {
            accounts = saved
        }
        selected = accounts.first?.id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func container(for acc: TTAccount) -> TTContainer {
        if let c = containers[acc.id] { return c }
        let c = TTContainer(id: acc.id)
        c.onStatus = { [weak self] s in self?.statuses[acc.id] = s }
        containers[acc.id] = c
        return c
    }

    func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let acc = TTAccount(name: trimmed.isEmpty ? "Account \(accounts.count + 1)" : trimmed)
        accounts.append(acc)
        selected = acc.id
    }

    func remove(_ acc: TTAccount) {
        accounts.removeAll { $0.id == acc.id }
        containers[acc.id] = nil
        statuses[acc.id] = nil
        if selected == acc.id { selected = accounts.first?.id }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? await WKWebsiteDataStore.remove(forIdentifier: acc.id)
        }
    }

    // MARK: all accounts at once

    func openInAll(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        guard let url = URL(string: t) else { return }
        for acc in accounts { container(for: acc).open(url) }
    }

    func uploadToAll(_ file: URL) {
        let list = accounts.map { container(for: $0) }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for c in list { group.addTask { await c.upload(file) } }
            }
        }
    }
}

@available(iOS 17.0, *)
struct TTWebHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

@available(iOS 17.0, *)
struct AccountsContainerView: View {
    @StateObject private var store = TTAccountStore()
    @State private var showAdd = false
    @State private var newName = ""
    @State private var showLink = false
    @State private var link = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Text("All accounts")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    link = ""
                    showLink = true
                } label: { Image(systemName: "link") }
                .disabled(store.accounts.isEmpty)
                Menu {
                    let files = Store.list()
                    if files.isEmpty { Text("No patched videos yet (Patch tab)") }
                    ForEach(files.prefix(15), id: \.self) { u in
                        Button(u.lastPathComponent) { store.uploadToAll(u) }
                    }
                } label: { Image(systemName: "film.stack") }
                .disabled(store.accounts.isEmpty)
            }
            .font(.title3)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
            .alert("Open link in all accounts", isPresented: $showLink) {
                TextField("tiktok.com/@name/video/…", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open") { store.openInAll(link) }
                Button("Cancel", role: .cancel) {}
            }

            ZStack {
                if store.accounts.isEmpty {
                    Text("Tap + to add an account")
                        .foregroundStyle(.secondary)
                }
                // Every account's page stays alive, so all stay logged in and loaded.
                ForEach(store.accounts) { acc in
                    TTWebHost(web: store.container(for: acc).web)
                        .opacity(store.selected == acc.id ? 1 : 0)
                        .allowsHitTesting(store.selected == acc.id)
                }
            }
            .overlay(alignment: .top) {
                if !store.statuses.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.accounts) { acc in
                            if let s = store.statuses[acc.id] {
                                Text("\(acc.name): \(s)")
                            }
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    .onTapGesture { store.statuses = [:] }
                }
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.accounts) { acc in
                        Text(acc.name)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(store.selected == acc.id ? Color.accentColor : Color.gray.opacity(0.25))
                            .foregroundStyle(store.selected == acc.id ? Color.white : Color.primary)
                            .clipShape(Capsule())
                            .onTapGesture { store.selected = acc.id }
                            .contextMenu {
                                Button("Delete account and login", role: .destructive) { store.remove(acc) }
                            }
                    }
                    Button {
                        newName = ""
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .padding(10)
                            .background(Color.gray.opacity(0.25))
                            .clipShape(Circle())
                    }
                }
                .padding(10)
            }
            .background(.bar)
        }
        .alert("New account", isPresented: $showAdd) {
            TextField("Name", text: $newName)
            Button("Add") { store.add(newName) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
