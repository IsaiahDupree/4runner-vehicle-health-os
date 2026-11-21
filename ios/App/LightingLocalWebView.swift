import SwiftUI
@preconcurrency import WebKit
import VHOSCore

/// The same actual controller-hosted UI used by the Android head unit.
/// Keeping it inside VHOS preserves the foreground BLE-to-Wi-Fi relay task.
struct LightingLocalWebView: UIViewRepresentable {
  let key: String
  let signalChanged: (LightingRelaySignal) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(signalChanged: signalChanged) }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let encoded = String(data: try! JSONEncoder().encode(key), encoding: .utf8)!
    configuration.userContentController.addUserScript(WKUserScript(
      source: "window.vhosNativeKey = \(encoded);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    configuration.userContentController.add(context.coordinator, name: "vhosLighting")
    let web = WKWebView(frame: .zero, configuration: configuration)
    web.navigationDelegate = context.coordinator
    web.isOpaque = false
    web.backgroundColor = UIColor(red: 0.043, green: 0.051, blue: 0.063, alpha: 1)
    web.load(URLRequest(url: LightingRelayCommand.controller.appending(path: "vhos/ui"), timeoutInterval: 5))
    return web
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    uiView.stopLoading()
    uiView.configuration.userContentController.removeScriptMessageHandler(forName: "vhosLighting")
    uiView.configuration.userContentController.removeAllUserScripts()
    uiView.navigationDelegate = nil
  }

  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let signalChanged: (LightingRelaySignal) -> Void
    init(signalChanged: @escaping (LightingRelaySignal) -> Void) { self.signalChanged = signalChanged }

    private func allowed(_ url: URL?) -> Bool {
      url?.scheme == "http" && url?.host == "192.168.88.1" && (url?.port == nil || url?.port == 80)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      decisionHandler(allowed(action.request.url) || action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.frameInfo.isMainFrame, allowed(message.frameInfo.request.url),
            let body = message.body as? [String: Any], let value = body["signal"] as? Int,
            let signal = LightingRelaySignal(rawValue: value) else { return }
      signalChanged(signal)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      showConnectionFailure(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      showConnectionFailure(webView)
    }

    private func showConnectionFailure(_ webView: WKWebView) {
      webView.loadHTMLString("""
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="background:#0b0d10;color:#edf0f3;font:16px -apple-system;padding:30px;line-height:1.7">
        <p style="color:#f59e64;font-size:12px;letter-spacing:2px">4RUNNER LIGHTING</p>
        <h2>Controller unavailable.</h2><p>Join the controller’s private 4Runner-Lighting Wi-Fi and verify its power.
        The new lighting firmware must be installed to serve these controls.</p>
        <a style="color:#f59e64" href="http://192.168.88.1/vhos/ui">Try again</a></body>
        """, baseURL: nil)
    }
  }
}
