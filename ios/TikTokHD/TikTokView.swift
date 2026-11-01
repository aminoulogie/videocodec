import SwiftUI
import WebKit

/// TikTok inside the app. tiktok.com opens in its normal mobile version;
/// TikTok Studio (/tiktokstudio) opens as the desktop site, scaled to fit
/// the phone screen, so the full desktop upload features are there.
/// TikTok shows "download the app" to anything that looks like a phone, so
/// in desktop mode the app presents itself as Safari on a Mac: Mac user
/// agent, no touch, a desktop-size screen, and a 1280 px wide layout.
/// Logins are kept between launches.
@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let home = URL(string: "https://www.tiktok.com/login")!
    static let studio = URL(string: "https://www.tiktok.com/tiktokstudio/upload")!
    static let macUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Runs before TikTok's own code in every frame (desktop mode only).
    static let desktopJS = """
    (function () {
      var UA = "\(macUA)";
      function def(o, k, v) { try { Object.defineProperty(o, k, { get: function () { return v; }, configurable: true }); } catch (e) {} }
      def(Navigator.prototype, 'userAgent', UA);
      def(Navigator.prototype, 'appVersion', UA.slice(8));
      def(Navigator.prototype, 'platform', 'MacIntel');
      def(Navigator.prototype, 'maxTouchPoints', 0);
      def(Screen.prototype, 'width', 1920); def(Screen.prototype, 'height', 1080);
      def(Screen.prototype, 'availWidth', 1920); def(Screen.prototype, 'availHeight', 1055);
      [window, Window.prototype, Document.prototype, Element.prototype, HTMLElement.prototype].forEach(function (o) {
        ['ontouchstart', 'ontouchmove', 'ontouchend', 'ontouchcancel'].forEach(function (k) { try { delete o[k]; } catch (e) {} });
      });
      try { delete window.TouchEvent; } catch (e) {}
      try { delete window.Touch; } catch (e) {}
      var mm = window.matchMedia.bind(window);
      window.matchMedia = function (q) {
        var s = String(q).replace(/\\s+/g, '');
        var fake = null;
        if (/(any-)?pointer:coarse|(any-)?hover:none/.test(s)) fake = false;
        else if (/(any-)?pointer:fine|(any-)?hover:hover/.test(s)) fake = true;
        var r = mm(q);
        if (fake === null) return r;
        return { matches: fake, media: r.media, onchange: null,
                 addListener: function () {}, removeListener: function () {},
                 addEventListener: function () {}, removeEventListener: function () {},
                 dispatchEvent: function () { return false; } };
      };
      function viewport() {
        var m = document.querySelector('meta[name=viewport]');
        if (!m) { m = document.createElement('meta'); m.name = 'viewport'; (document.head || document.documentElement).appendChild(m); }
        if (m.content !== 'width=1280') m.content = 'width=1280';
      }
      document.addEventListener('DOMContentLoaded', viewport);
      new MutationObserver(function () { if (document.head) viewport(); }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    let web: WKWebView
    @Published var canBack = false
    @Published var canForward = false
    @Published var loading = false
    /// The mode the page on show was loaded in.
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
        apply(desktop: false)
    }

    /// Switches how the app presents itself; takes effect on the next page load.
    private func apply(desktop d: Bool) {
        desktop = d
        web.customUserAgent = d ? Self.macUA : nil
        web.configuration.defaultWebpagePreferences.preferredContentMode = d ? .desktop : .mobile
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        if d {
            ucc.addUserScript(WKUserScript(source: Self.desktopJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    private func wantsDesktop(_ url: URL?) -> Bool {
        if let forced { return forced }
        return url?.path.hasPrefix("/tiktokstudio") == true
    }

    func open(_ url: URL) {
        started = true
        let d = wantsDesktop(url)
        if d != desktop { apply(desktop: d) }
        _ = web.load(URLRequest(url: url))
    }

    func start() {
        guard !started else { return }
        open(Self.home)
    }

    func openStudio() { open(Self.studio) }

    private func reloadInMode(_ d: Bool) {
        apply(desktop: d)
        if let u = web.url { _ = web.load(URLRequest(url: u)) }
    }

    func toggleDesktop() {
        forced = !desktop
        reloadInMode(!desktop)
    }

    func automatic() {
        forced = nil
        reloadInMode(wantsDesktop(web.url))
    }

    // A link into or out of Studio: load it again in the right mode.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let main = action.targetFrame?.isMainFrame != false
        if main, let url = action.request.url, action.request.httpMethod ?? "GET" == "GET",
           wantsDesktop(url) != desktop {
            let d = wantsDesktop(url)
            DispatchQueue.main.async {
                self.apply(desktop: d)
                _ = self.web.load(URLRequest(url: url))
            }
            return (.cancel, preferences)
        }
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { update() }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { update() }

    // TikTok moves between pages without loading (single-page app): when it
    // lands on Studio in the mobile mode (or leaves it), load it again.
    func update() {
        canBack = web.canGoBack
        canForward = web.canGoForward
        loading = web.isLoading
        if forced == nil, !web.isLoading, wantsDesktop(web.url) != desktop {
            reloadInMode(wantsDesktop(web.url))
        }
    }

    // Links that open a new window open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url { open(url) }
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
                Button { b.open(URL(string: "https://www.tiktok.com/")!) } label: {
                    Image(systemName: "house")
                }
                Button { b.openStudio() } label: { Label("Upload", systemImage: "arrow.up.circle.fill").bold() }
                Menu {
                    Button(b.desktop ? "Switch to mobile version" : "Switch to desktop version") { b.toggleDesktop() }
                    Button("Automatic (desktop only in Studio)") { b.automatic() }
                    Button("Log in page") { b.open(Browser.home) }
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
