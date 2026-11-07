import SwiftUI
import WebKit

/// Accounts tab: several TikTok accounts at once, each in its own container
/// (separate cookies and storage), so every account stays logged in.
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

@available(iOS 17.0, *)
@MainActor
final class TTAccountStore: ObservableObject {
    @Published var accounts: [TTAccount] = [] { didSet { save() } }
    @Published var selected: UUID?
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

    func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let acc = TTAccount(name: trimmed.isEmpty ? "Account \(accounts.count + 1)" : trimmed)
        accounts.append(acc)
        selected = acc.id
    }

    func remove(_ acc: TTAccount) {
        accounts.removeAll { $0.id == acc.id }
        if selected == acc.id { selected = accounts.first?.id }
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: acc.id) }
    }
}

/// One account = one web view with its own data store.
@available(iOS 17.0, *)
struct TTContainerWebView: UIViewRepresentable {
    let accountID: UUID

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: accountID)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: URL(string: "https://www.tiktok.com/login")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@available(iOS 17.0, *)
struct AccountsContainerView: View {
    @StateObject private var store = TTAccountStore()
    @State private var showAdd = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if store.accounts.isEmpty {
                    Text("Tap + to add an account")
                        .foregroundStyle(.secondary)
                }
                // Every account's page stays alive, so all stay logged in and loaded.
                ForEach(store.accounts) { acc in
                    TTContainerWebView(accountID: acc.id)
                        .opacity(store.selected == acc.id ? 1 : 0)
                        .allowsHitTesting(store.selected == acc.id)
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
