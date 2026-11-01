import SwiftUI
import WebKit

/// TikTok inside the app. tiktok.com opens in its normal mobile version;
/// TikTok Studio (/tiktokstudio) opens as the desktop site, scaled to fit
/// the phone screen (WebKit's own "Request Desktop Website"), so the full
/// desktop upload features are there. Logins are kept between launches.
@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let home = URL(string: "https://www.tiktok.com/login")!
    static let studio = URL(string: "https://www.tiktok.com/tiktokstudio/upload")!

    let web: WKWebView
    @Published var canBack = false
    @Published var canForward = false
    @Published var loading = false
    @Published var desktop = false
    /// nil = automatic (desktop only on TikTok Studio)
    @Published var forced: Bool?
    private var started = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // keeps you logged in
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.minimumZoomScale = 0.25
        web.scrollView.maximumZoomScale = 5
    }

    func start() {
        guard !started else { return }
        started = true
        _ = web.load(URLRequest(url: Self.home))
    }

    func openStudio() {
        started = true
        _ = web.load(URLRequest(url: Self.studio))
    }

    func toggleDesktop() {
        forced = !desktop
        _ = web.reload()
    }

    func automatic() {
        forced = nil
        _ = web.reload()
    }

    private func wantsDesktop(_ url: URL?) -> Bool {
        if let forced { return forced }
        return url?.path.hasPrefix("/tiktokstudio") == true
    }

    // Desktop or mobile is chosen for every page load.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.targetFrame?.isMainFrame != false {
            let d = wantsDesktop(action.request.url)
            preferences.preferredContentMode = d ? .desktop : .mobile
            desktop = d
        }
        return (.allow, preferences)
    }

    // TikTok moves between pages without loading (single-page app): when it
    // lands on Studio in the mobile layout, load it again as desktop.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        update()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { update() }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { update() }

    func update() {
        canBack = web.canGoBack
        canForward = web.canGoForward
        loading = web.isLoading
        if forced == nil, wantsDesktop(web.url) != desktop, !web.isLoading {
            _ = web.reload()
        }
    }

    // Links that open a new window open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { _ = webView.load(action.request) }
        return nil
    }
}

struct WebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

struct TikTokView: View {
    @EnvironmentObject var b: Browser
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            WebView(web: b.web)
            HStack(spacing: 22) {
                Button { _ = b.web.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!b.canBack)
                Button { _ = b.web.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!b.canForward)
                Button { if b.loading { b.web.stopLoading() } else { _ = b.web.reload() } } label: {
                    Image(systemName: b.loading ? "xmark" : "arrow.clockwise")
                }
                Spacer()
                Button { _ = b.web.load(URLRequest(url: URL(string: "https://www.tiktok.com/")!)) } label: {
                    Image(systemName: "house")
                }
                Button { b.openStudio() } label: { Label("Upload", systemImage: "arrow.up.circle.fill").bold() }
                Menu {
                    Button(b.desktop ? "Switch to mobile version" : "Switch to desktop version") { b.toggleDesktop() }
                    Button("Automatic (desktop only in Studio)") { b.automatic() }
                    Button("Log in page") { _ = b.web.load(URLRequest(url: Browser.home)) }
                } label: {
                    Image(systemName: b.desktop ? "desktopcomputer" : "iphone")
                }
            }
            .font(.title3)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear { b.start() }
        .onReceive(timer) { _ in b.update() }   // follows TikTok's in-page navigation
    }
}
