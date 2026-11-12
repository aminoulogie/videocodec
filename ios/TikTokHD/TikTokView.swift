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
    static let macUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"

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
    /// A patched video waiting to be put in Studio's upload box.
    @Published var pending: URL?
    /// Shown over the page while a video is being handed to TikTok.
    @Published var status: String?
    private var injecting = false
    private var started = false
    /// What made the page load again (shown in ⋯ → Page report), newest last.
    private var events: [String] = []

    private func note(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        events.append("\(t) \(s)")
        if events.count > 12 { events.removeFirst(events.count - 12) }
    }

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
        ucc.addUserScript(WKUserScript(source: Self.handoverJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        note("reloaded as \(d ? "desktop" : "mobile") site: \(web.url?.path ?? "-")")
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
            note("link opened as \(d ? "desktop" : "mobile") site: \(url.path)")
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

    /// iOS ended the page's process, almost always because it used too much memory
    /// (a big video in the upload box, TikTok making its cover from a 4K/HDR file).
    /// Left to itself WebKit reloads the page without a word and the upload is gone;
    /// here the page is reloaded too, but the user is told why.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        note("page crashed (iOS ended it, usually out of memory) on \(webView.url?.path ?? "-")")
        injecting = false
        status = "TikTok's page crashed: iOS ended it, most likely out of memory with this big video, so the upload was lost. Try again with the app freshly opened, or post a shorter or smaller file. (Tap to hide.)"
        if let u = webView.url { _ = webView.load(URLRequest(url: u)) } else { open(Self.studio) }
    }
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
            return
        }
        if let file = pending, !injecting, !web.isLoading, web.url?.path.hasPrefix("/tiktokstudio") == true {
            pending = nil
            Task { await putInUploadBox(file) }
        }
    }

    // MARK: putting a video in TikTok Studio's upload box

    /// Installed in every frame before the page's own code. While a video is
    /// waiting (window.__thdFile), whatever TikTok does to open the file picker
    /// (input.click(), showPicker(), a tap on the input or its label) puts the
    /// video in instead. Finds inputs inside shadow DOM too, and passes the
    /// video on to frames (postMessage carries the File itself).
    static let handoverJS = """
    (function () {
      if (window.__thdInstalled) return; window.__thdInstalled = true;
      function deep(root) {
        var out = [];
        (function walk(n) {
          if (!n || !n.querySelectorAll) return;
          var all = n.querySelectorAll('*');
          for (var k = 0; k < all.length; k++) {
            var el = all[k];
            if (el.tagName === 'INPUT' && el.type === 'file') out.push(el);
            if (el.shadowRoot) walk(el.shadowRoot);
          }
        })(root);
        out.sort(function (x, y) { return ((y.accept || '').indexOf('video') >= 0) - ((x.accept || '').indexOf('video') >= 0); });
        return out;
      }
      function done() {
        window.__thdFile = null; window.__thdDone = true;
        try { if (window.top !== window) window.top.postMessage({ thd: 'done' }, '*'); } catch (e) {}
      }
      function fill(input, file) {
        try {
          var dt = new DataTransfer(); dt.items.add(file);
          input.files = dt.files;
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          done(); return true;
        } catch (e) { window.__thdError = String(e); return false; }
      }
      function drop(file) {
        var zones = deepAll(document).filter(function (el) {
          var t = (el.innerText || '').toLowerCase();
          return /drag|drop|select video|select file|upload/.test(t) && el.getBoundingClientRect().width > 150 && t.length < 400;
        });
        zones.sort(function (x, y) { return (x.innerText || '').length - (y.innerText || '').length; });
        for (var i = 0; i < zones.length && i < 3; i++) {
          try {
            var dt = new DataTransfer(); dt.items.add(file);
            var taken = false;
            ['dragenter', 'dragover', 'drop'].forEach(function (type) {
              var ok = zones[i].dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt }));
              if (type === 'drop' && !ok) taken = true;   // the page handled the drop
            });
            if (taken) { done(); return zones.length; }
          } catch (e) { window.__thdError = String(e); }
        }
        return zones.length;
      }
      function deepAll(root) {
        var out = [];
        (function walk(n) {
          if (!n || !n.querySelectorAll) return;
          var all = n.querySelectorAll('*');
          for (var k = 0; k < all.length; k++) { out.push(all[k]); if (all[k].shadowRoot) walk(all[k].shadowRoot); }
        })(root);
        return out;
      }
      function clickSelect() {
        var c = deepAll(document).filter(function (el) {
          var t = (el.innerText || '').trim().toLowerCase();
          if (!(t.length > 0 && t.length < 40 && /^(select (video|file)s?|upload( video)?|choose (video|file))$/.test(t)
                && el.getBoundingClientRect().width > 0)) return false;
          // the innermost element with that text (a wrapper's click wouldn't reach the button)
          return !Array.prototype.some.call(el.children, function (ch) { return (ch.innerText || '').trim().toLowerCase() === t; });
        });
        c.sort(function (x, y) {
          var bx = /^(BUTTON|A)$/.test(x.tagName) || x.getAttribute('role') === 'button';
          var by = /^(BUTTON|A)$/.test(y.tagName) || y.getAttribute('role') === 'button';
          return by - bx;
        });
        if (c[0]) { c[0].click(); return true; }
        return false;
      }
      var oc = HTMLInputElement.prototype.click;
      HTMLInputElement.prototype.click = function () {
        if (this.type === 'file' && window.__thdFile && fill(this, window.__thdFile)) return;
        return oc.apply(this, arguments);
      };
      if (HTMLInputElement.prototype.showPicker) {
        var sp = HTMLInputElement.prototype.showPicker;
        HTMLInputElement.prototype.showPicker = function () {
          if (this.type === 'file' && window.__thdFile && fill(this, window.__thdFile)) return;
          return sp.apply(this, arguments);
        };
      }
      document.addEventListener('click', function (e) {
        if (!window.__thdFile) return;
        var t = e.target, inp = null;
        if (t && t.tagName === 'INPUT' && t.type === 'file') inp = t;
        else if (t && t.closest) { var l = t.closest('label'); if (l && l.control && l.control.type === 'file') inp = l.control; }
        if (inp) { e.preventDefault(); fill(inp, window.__thdFile); }
      }, true);
      function offer(file) {
        window.__thdFile = file; window.__thdDone = false;
        for (var i = 0; i < window.frames.length; i++) { try { window.frames[i].postMessage({ thd: 'file', file: file }, '*'); } catch (e) {} }
        var list = deep(document);
        if (list[0] && fill(list[0], file)) return 'filled';
        if (clickSelect() && window.__thdDone) return 'filled';
        return 'armed';
      }
      window.addEventListener('message', function (e) {
        var d = e.data; if (!d || !d.thd) return;
        if (d.thd === 'file' && d.file) offer(d.file);
        if (d.thd === 'done' && window === window.top) { window.__thdFile = null; window.__thdDone = true; }
      });
      window.__thd = { offer: offer, drop: drop, deep: deep, deepAll: deepAll };
    })();
    """

    private func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        // The async form (label contentWorld:) waits for the page's answer;
        // the in:in: form is fire-and-forget and returns nothing.
        let r: Any? = try await web.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        return r
    }

    /// Sends the file into the page in pieces and offers it to TikTok's upload
    /// box: filled directly if the box is on the page, else TikTok's own
    /// "Select video" is pressed (the picker is replaced by the video), else a
    /// drop on the upload area, else it waits for the user to tap Select video.
    /// The bytes are the patched file, unchanged.
    func putInUploadBox(_ file: URL) async {
        guard !injecting else { return }
        injecting = true
        defer { injecting = false }
        do {
            // Studio may still be building its page.
            for _ in 0..<20 {
                let ready = (try? await js("return !!(window.__thd && document.body && document.body.innerText.length > 50);")) as? Bool
                if ready == true { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard (try? await js("return !!window.__thd;")) as? Bool == true else {
                status = "The page isn't ready. Open Upload in TikTok Studio and tap the film button again."
                return
            }
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
                status = "Handing the video to TikTok… \(total > 0 ? sent * 100 / total : 0)%"
            }
            let r = try await js("""
                var f = new File(window.__thdParts, name, { type: 'video/mp4', lastModified: Date.now() });
                window.__thdParts = null;
                if (f.size !== size) return 'size ' + f.size;
                return window.__thd.offer(f);
                """, ["name": file.lastPathComponent, "size": total]) as? String ?? "?"
            if r.hasPrefix("size") {
                status = "The video arrived damaged (\(r)). Pick it from Files → On My iPhone → TikTok HD."
                return
            }
            let ok = "✓ \(file.lastPathComponent) is in the upload box (\(total / 1_000_000) MB, unchanged)."
            if r == "filled" { status = ok; return }
            if (try? await isDone()) == true { status = ok; return }
            // A frame may have taken it, or TikTok opens its picker a moment later.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            if (try? await isDone()) == true { status = ok; return }
            _ = try? await js("if (window.__thdFile) window.__thd.drop(window.__thdFile); return true;")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            if (try? await isDone()) == true { status = ok; return }
            status = "Now tap Select video on TikTok's page: the video goes in instead of the file picker."
            for _ in 0..<120 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if (try? await isDone()) == true { status = ok; return }
            }
            status = "It didn't go in. Tap ⋯ → Page report and send it, or pick the video from Files → On My iPhone → TikTok HD."
        } catch {
            status = "Couldn't hand it over: \(error.localizedDescription). Pick it from Files → On My iPhone → TikTok HD."
        }
    }

    private func isDone() async throws -> Bool {
        (try await js("return window.__thdDone === true;")) as? Bool == true
    }

    /// The film button: put a patched video in the upload box now.
    func upload(_ file: URL) {
        if web.url?.path.hasPrefix("/tiktokstudio") == true, !web.isLoading {
            Task { await putInUploadBox(file) }
        } else {
            pending = file
            openStudio()
        }
    }

    /// The qualities TikTok actually serves for the video open on this page. It
    /// reads TikTok's own page data (the list of streams it offers viewers),
    /// fetched with your login so Only me posts work too, plus the size of the
    /// video that is playing right now. "Save video" downloads are always a
    /// smaller copy, so this is the honest check.
    func qualityReport() async -> String {
        let body = """
        var out = [];
        var m = location.href.match(/\\/video\\/(\\d+)/);
        if (!m) return 'Open your posted video first (the address must contain /video/), then tap Check video quality again.';
        out.push('video id: ' + m[1]);
        var html = null, urls = [location.origin + location.pathname, 'https://www.tiktok.com' + location.pathname];
        for (var u of urls) {
          try { var r = await fetch(u, { credentials: 'include' }); if (r.ok) { html = await r.text(); if (/__UNIVERSAL_DATA_FOR_REHYDRATION__|SIGI_STATE/.test(html)) break; } } catch (e) {}
        }
        var data = null;
        if (html) {
          var mm = html.match(/<script[^>]*id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>([\\s\\S]*?)<\\/script>/) || html.match(/<script[^>]*id="SIGI_STATE"[^>]*>([\\s\\S]*?)<\\/script>/);
          if (mm) { try { data = JSON.parse(mm[1]); } catch (e) {} }
        }
        var video = null, seen = 0;
        (function walk(o, depth) {
          if (!o || typeof o !== 'object' || depth > 14 || seen > 200000) return;
          seen++;
          if (!video && o.id === m[1] && o.video && typeof o.video === 'object') video = o.video;
          for (var k in o) walk(o[k], depth + 1);
        })(data, 0);
        if (!video) (function walk(o, depth) {
          if (!o || typeof o !== 'object' || depth > 14 || video) return;
          if (Array.isArray(o.bitrateInfo) || o.playAddr) { video = o; return; }
          for (var k in o) walk(o[k], depth + 1);
        })(data, 0);
        var best = 0;
        if (video) {
          var w = video.width || 0, h = video.height || 0;
          out.push('post: ' + w + 'x' + h + (video.ratio ? '  (' + video.ratio + ')' : '') + (video.definition ? '  definition ' + video.definition : '') + (video.codecType ? '  ' + video.codecType : '') + (video.bitrate ? '  ' + Math.round(video.bitrate / 1000) + ' kbps' : ''));
          best = Math.min(w, h);
          var list = video.bitrateInfo || [];
          if (list.length) out.push('streams TikTok offers viewers:');
          list.map(function (b) {
            var pa = b.PlayAddr || b.playAddr || {}, bw = pa.Width || pa.width || 0, bh = pa.Height || pa.height || 0;
            best = Math.max(best, Math.min(bw, bh));
            return { s: Math.min(bw, bh), t: '  ' + bw + 'x' + bh + '  ' + (b.CodecType || b.codecType || '?') + '  ' + Math.round((b.Bitrate || b.bitrate || 0) / 1000) + ' kbps  ' + (b.GearName || b.gearName || '') + ((pa.DataSize || pa.dataSize) ? '  ' + ((pa.DataSize || pa.dataSize) / 1e6).toFixed(1) + ' MB' : '') };
          }).sort(function (a, b) { return b.s - a.s; }).forEach(function (x) { out.push(x.t); });
        } else {
          out.push(html ? 'The TikTok page data did not include this video (it may still be processing).' : 'Could not load the video page.');
        }
        var d = window.__thd, vids = d ? d.deepAll(document).filter(function (el) { return el.tagName === 'VIDEO'; }) : Array.from(document.querySelectorAll('video'));
        vids.forEach(function (v, i) { if (v.videoWidth) out.push('playing now: ' + v.videoWidth + 'x' + v.videoHeight); });
        out.unshift(best >= 2160 ? 'RESULT: 4K stream available' : best >= 1440 ? 'RESULT: 1440p stream available' : best >= 1080 ? 'RESULT: 1080p stream available' : best > 0 ? 'RESULT: best stream is ' + best + 'p' : 'RESULT: unknown');
        out.push('', 'Right after posting TikTok often has only low streams; check again after 10 to 30 minutes.');
        return out.join('\\n');
        """
        do {
            return (try await js(body)) as? String ?? "(no answer)"
        } catch {
            return "error: \(error.localizedDescription)\nurl: \(web.url?.absoluteString ?? "-")"
        }
    }

    /// What the page looks like to the app, to send when something fails.
    func pageReport() async -> String {
        let body = """
        var d = window.__thd, ins = d ? d.deep(document) : [];
        var frames = Array.prototype.map.call(document.querySelectorAll('iframe'), function (f) { return (f.src || '(no src)').slice(0, 120); });
        var btn = d ? d.deepAll(document).filter(function (el) {
          var t = (el.innerText || '').trim(); return t.length > 0 && t.length < 40 && /select|upload|choose|drag|drop|app store|download/i.test(t);
        }).slice(0, 12).map(function (el) { return el.tagName.toLowerCase() + ': ' + el.innerText.trim().replace(/\\s+/g, ' '); }) : [];
        return [
          'url: ' + location.href,
          'title: ' + document.title,
          'ua: ' + navigator.userAgent,
          'touch: ' + navigator.maxTouchPoints + ', width: ' + innerWidth + ', screen: ' + screen.width + 'x' + screen.height,
          'helper: ' + (!!d) + ', waiting: ' + (!!window.__thdFile) + ', done: ' + (!!window.__thdDone) + ', error: ' + (window.__thdError || '-'),
          'file inputs: ' + ins.length + ins.map(function (i) { return ' [accept=' + i.accept + ']'; }).join(''),
          'iframes: ' + frames.length + (frames.length ? ' ' + frames.join(' | ') : ''),
          'buttons: ' + btn.join(' | '),
          'text: ' + (document.body ? document.body.innerText.replace(/\\s+/g, ' ').slice(0, 300) : '-')
        ].join('\\n');
        """
        let log = "\n\npage loads by the app:\n" + (events.isEmpty ? "(none)" : events.joined(separator: "\n"))
        do {
            return ((try await js(body)) as? String ?? "(no answer)") + log
        } catch {
            return "error: \(error.localizedDescription)\nurl: \(web.url?.absoluteString ?? "-")" + log
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
    @State private var report: String?
    @State private var reportTitle = "Page report"

    var body: some View {
        VStack(spacing: 0) {
            WebView(web: b.web)
                .overlay(alignment: .top) {
                    if let s = b.status {
                        Text(s).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8).padding(.horizontal, 12)
                            .onTapGesture { b.status = nil }
                    }
                }
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
                Menu {
                    let files = Store.list()
                    if files.isEmpty { Text("No patched videos yet (Patch tab)") }
                    ForEach(files.prefix(15), id: \.self) { u in
                        Button(u.lastPathComponent) { b.upload(u) }
                    }
                } label: { Image(systemName: "film.stack") }
                Button { b.openStudio() } label: { Label("Upload", systemImage: "arrow.up.circle.fill").bold() }
                Menu {
                    Button(b.desktop ? "Switch to mobile version" : "Switch to desktop version") { b.toggleDesktop() }
                    Button("Automatic (desktop only in Studio)") { b.automatic() }
                    Button("Log in page") { b.open(Browser.home) }
                    Button("Check video quality") {
                        Task { reportTitle = "Video quality"; report = await b.qualityReport() }
                    }
                    Button("Page report (to send if upload fails)") {
                        Task { reportTitle = "Page report"; report = await b.pageReport() }
                    }
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
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            NavigationStack {
                ScrollView {
                    Text(report ?? "").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle(reportTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Copy") { UIPasteboard.general.string = report }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { report = nil }
                    }
                }
            }
        }
    }
}
