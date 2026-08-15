import SwiftUI
import WebKit

/// The app's single screen: the HTML page, edge to edge, plus the native
/// folder picker whenever the page asks for it.
struct ContentView: View {
    let bridge: WebBridge

    var body: some View {
        WebPage(bridge: bridge).ignoresSafeArea()
    }
}

// MARK: - The page

#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// SwiftUI wrapper around the `WKWebView` that shows `duel-crpe-2027.html`.
private struct WebPage: PlatformViewRepresentable {
    let bridge: WebBridge

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(
            bridge, contentWorld: .page, name: WebBridge.handlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = bridge      // makes `confirm()` and `alert()` work
        webView.isInspectable = true     // Safari → Develop → inspect
        #if !os(macOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif

        let page = Self.pageURL()
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        bridge.webView = webView
        return webView
    }

    /// The app copies the page from the bundle into `Documents` to make it
    /// readable from the Files app (`UIFileSharingEnabled`), and refreshes it
    /// on every app update.
    ///
    /// If the copy fails, the bundled one is shown: never a blank screen.
    static func pageURL() -> URL {
        let manager = FileManager.default
        let destination = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("duel-crpe-2027.html")

        guard let bundled = Bundle.main.url(forResource: "duel-crpe-2027", withExtension: "html")
        else { return destination }

        let bundledContent = try? Data(contentsOf: bundled)
        if bundledContent != (try? Data(contentsOf: destination)) {
            try? manager.removeItem(at: destination)
            try? manager.copyItem(at: bundled, to: destination)
        }
        return manager.fileExists(atPath: destination.path) ? destination : bundled
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #endif
}
