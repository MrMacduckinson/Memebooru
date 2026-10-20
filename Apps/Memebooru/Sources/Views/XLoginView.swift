import SwiftUI
import WebKit
import MemebooruCore

#if os(macOS)
typealias ViewRepresentable = NSViewRepresentable
#else
typealias ViewRepresentable = UIViewRepresentable
#endif

/// Logs into x.com in an embedded web view and harvests the auth_token + ct0 cookies.
struct XLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let onSession: (XSession) -> Void
    @State private var status = "Войдите в x.com. После входа окно закроется автоматически."

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Text("Войти в x.com").dfont(18).foregroundStyle(Theme.headerText)
                Spacer()
                GlassButton(title: "Отмена") { dismiss() }
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
            .background(LinearGradient(colors: [Theme.headerTop, Theme.headerBottom], startPoint: .top, endPoint: .bottom))
            XWebView(url: URL(string: "https://x.com/login")!) { cookies in
                guard let session = XSession.from(cookies: cookies) else { return }
                onSession(session)
                dismiss()
            }
            Text(status).zfont(11).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                .background(Theme.sidebar)
                .overlay(alignment: .top) { Theme.sidebarRule.frame(height: 1) }
        }
        .preferredColorScheme(.light)
        .frame(minWidth: 480, minHeight: 640)
    }
}

struct XWebView: ViewRepresentable {
    let url: URL
    let onCookies: ([String: String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookies: onCookies) }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif

    private func make(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        web.load(URLRequest(url: url))
        context.coordinator.web = web
        return web
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCookies: ([String: String]) -> Void
        weak var web: WKWebView?
        private var done = false
        init(onCookies: @escaping ([String: String]) -> Void) { self.onCookies = onCookies }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check(webView) }

        private func check(_ webView: WKWebView) {
            guard !done else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                var jar: [String: String] = [:]
                for c in cookies where c.domain.contains("x.com") || c.domain.contains("twitter.com") { jar[c.name] = c.value }
                if jar["auth_token"] != nil, jar["ct0"] != nil {
                    self.done = true
                    self.onCookies(jar)
                }
            }
        }
    }
}
