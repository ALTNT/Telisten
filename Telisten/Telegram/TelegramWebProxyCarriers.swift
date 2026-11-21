import Foundation
import WebKit
@preconcurrency import TDLibKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class TelegramWebProxyCarriers {
    private struct Key: Hashable {
        let clientID: Int32
        let carrierID: Int
    }

    private var carriers: [Key: TelegramWebProxyCarrier] = [:]

    nonisolated init() {}

    func open(_ configuration: WebProxyCarrier, client: TDLibClient) {
        let key = Key(clientID: client.id, carrierID: configuration.id)
        guard carriers[key] == nil else { return }
        guard let carrier = TelegramWebProxyCarrier(configuration: configuration, client: client) else {
            try? client.reportWebProxyCarrierError(
                carrierId: configuration.id,
                error: .webProxyCarrierErrorLoadFailed(WebProxyCarrierErrorLoadFailed(message: "Invalid relay address"))
            ) { _ in }
            return
        }
        carriers[key] = carrier
        carrier.start()
    }

    func deliver(_ data: Data, carrierID: Int, clientID: Int32) {
        carriers[Key(clientID: clientID, carrierID: carrierID)]?.deliver(data)
    }

    func close(carrierID: Int, clientID: Int32) {
        carriers.removeValue(forKey: Key(clientID: clientID, carrierID: carrierID))?.close()
    }

    func closeAll(clientID: Int32) {
        for key in carriers.keys.filter({ $0.clientID == clientID }) {
            carriers.removeValue(forKey: key)?.close()
        }
    }
}

@MainActor
private final class TelegramWebProxyCarrier: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private enum Delivery: Sendable {
        case data(Data)
        case close
    }

    private enum SetupError: Swift.Error {
        case contentRuleStoreUnavailable
    }

    // The protocol permits a 1 MiB payload plus its frame header.
    private static let maximumFrameSize = (1 << 20) + 8
    private static let maximumControlSize = 16 * 1024

    private let relayURL: URL
    private let origin: String
    private let host: String
    private let pathPrefix: String
    private let carrierID: Int
    private let client: TDLibClient
    private let handlerName = "relay" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let messages = AsyncStream<WebProxyCarrierMessage>.makeStream(bufferingPolicy: .bufferingOldest(128))
    private let deliveries = AsyncStream<Delivery>.makeStream(bufferingPolicy: .bufferingOldest(128))
    private var webView: WKWebView?
    private var startupTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var navigationStarted = false
    private var receivedMessage = false
    private var closing = false

    init?(configuration: WebProxyCarrier, client: TDLibClient) {
        guard configuration.bridgeObjectName == "TelegramWebProxy",
              let originURL = URL(string: configuration.origin), let host = originURL.host,
              WebProxyConfiguration.isDomain(host), configuration.origin == "https://\(host)",
              let url = URL(string: configuration.url), url.scheme == "https", url.host == host,
              url.port == nil, url.user == nil, url.password == nil,
              url.query != nil, url.fragment != nil,
              configuration.pathPrefix.hasPrefix("/"), configuration.pathPrefix.hasSuffix("/"),
              WebProxyConfiguration.isRelayPath(configuration.pathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              url.path(percentEncoded: true).hasPrefix(configuration.pathPrefix) else { return nil }

        relayURL = url
        origin = configuration.origin
        self.host = host
        pathPrefix = configuration.pathPrefix
        carrierID = configuration.id
        self.client = client
        super.init()
    }

    func start() {
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ruleList = try await self.makeRuleList()
                guard !self.closing else { return }
                self.load(ruleList)
                // WebKit may wait indefinitely for a server that never responds.
                try await Task.sleep(for: .seconds(25))
                if !self.receivedMessage { self.failLoading("Relay page did not initialize") }
            } catch is CancellationError {
                return
            } catch {
                self.failLoading("Could not restrict the relay page")
            }
        }
    }

    private func makeRuleList() async throws -> WKContentRuleList {
        // Filter HTTP(S) resources in WebKit as well as enforcing the page CSP.
        let relayPrefix = NSRegularExpression.escapedPattern(for: origin + pathPrefix)
        let rules: [[String: [String: Any]]] = [
            ["trigger": ["url-filter": "^https?://"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^\(relayPrefix)", "url-filter-is-case-sensitive": true],
             "action": ["type": "ignore-previous-rules"]]
        ]
        let encodedRules = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        guard let store = WKContentRuleListStore.default(),
              let list = try await store.compileContentRuleList(forIdentifier: handlerName, encodedContentRuleList: encodedRules) else {
            throw SetupError.contentRuleStoreUnavailable
        }
        // The compiled object remains usable and the temporary rule need not stay on disk.
        try? await store.removeContentRuleList(forIdentifier: handlerName)
        return list
    }

    private func load(_ ruleList: WKContentRuleList) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.add(ruleList)
        configuration.userContentController.add(self, name: handlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView = view
        view.navigationDelegate = self
        view.uiDelegate = self
        // Attaching an unobtrusive view lets WebKit run the relay as a window-backed page.
        #if os(macOS)
        view.alphaValue = 0.01
        NSApp.keyWindow?.contentView?.addSubview(view, positioned: .below, relativeTo: nil)
        #else
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        windows.first(where: \.isKeyWindow)?.insertSubview(view, at: 0)
        #endif

        // TDLibKit uses a concurrent request queue. Wait for each acknowledgement
        // before sending the next page message to preserve wire order.
        messageTask = Task { [weak self] in
            guard let stream = self?.messages.stream else { return }
            for await message in stream {
                guard let self, !self.closing else { return }
                do {
                    try await self.client.processWebProxyCarrierMessage(carrierId: self.carrierID, message: message)
                } catch {
                    self.fail(.webProxyCarrierErrorTerminated)
                    return
                }
            }
        }

        deliveryTask = Task { [weak self] in
            guard let stream = self?.deliveries.stream else { return }
            for await delivery in stream {
                guard let self, let view = self.webView else { return }
                do {
                    switch delivery {
                    case let .data(data):
                        _ = try await view.callAsyncJavaScript(
                            """
                            const bytes = Uint8Array.from(atob(encoded), character => character.charCodeAt(0));
                            globalThis.TelegramWebProxy.onmessage({data: bytes.buffer});
                            """,
                            arguments: ["encoded": data.base64EncodedString()], contentWorld: .page
                        )
                    case .close:
                        _ = try await view.callAsyncJavaScript(
                            #"globalThis.TelegramWebProxy.onmessage({data: '{"t":"close"}'});"#,
                            contentWorld: .page
                        )
                    }
                } catch {
                    self.fail(.webProxyCarrierErrorTerminated)
                    return
                }
            }
        }

        view.load(URLRequest(url: relayURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    private var bridgeScript: String {
        // These values have already been restricted to ASCII domain and relay-path characters.
        let secureWebSocketOrigin = "wss://\(host)"
        return """
        (() => {
            if (location.origin !== '\(origin)' || !location.pathname.startsWith('\(pathPrefix)')) return;
            // At document start the HTML parser may not have created the head yet.
            let head = document.head;
            if (!head && document.documentElement) {
                head = document.createElement('head');
                document.documentElement.prepend(head);
            }
            if (!head) return;
            const csp = document.createElement('meta');
            csp.httpEquiv = 'Content-Security-Policy';
            csp.content = "default-src 'none'; base-uri 'none'; form-action 'none'; " +
                "script-src 'unsafe-inline'; connect-src \(origin)\(pathPrefix) \(secureWebSocketOrigin)\(pathPrefix)";
            head.prepend(csp);
            const dns = document.createElement('meta');
            dns.httpEquiv = 'x-dns-prefetch-control';
            dns.content = 'off';
            head.prepend(dns);
            for (const name of [
                'localStorage', 'sessionStorage', 'indexedDB', 'caches', 'Worker', 'SharedWorker',
                'BroadcastChannel', 'RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel',
                'WebTransport', 'AudioContext', 'webkitAudioContext', 'Notification',
                'open', 'print', 'alert', 'confirm', 'prompt'
            ]) {
                Object.defineProperty(globalThis, name, {value: undefined, configurable: false});
            }
            for (const name of ['mediaDevices', 'clipboard', 'geolocation', 'serviceWorker']) {
                Object.defineProperty(navigator, name, {value: undefined, configurable: false});
            }
            Object.defineProperty(document, 'cookie', {value: '', configurable: false});
            const handler = webkit.messageHandlers.\(handlerName);
            const post = handler.postMessage.bind(handler);
            const encode = btoa.bind(globalThis);
            let callback = null;
            const bridge = Object.freeze({
                get onmessage() { return callback; },
                set onmessage(value) { callback = typeof value === 'function' ? value : null; },
                postMessage(value) {
                    if (typeof value === 'string') {
                        if (value.length <= \(Self.maximumControlSize)) post({kind: 'text', value});
                        return;
                    }
                    if (!(value instanceof ArrayBuffer) && !ArrayBuffer.isView(value)) return;
                    const bytes = value instanceof ArrayBuffer
                        ? new Uint8Array(value)
                        : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
                    if (bytes.length > \(Self.maximumFrameSize)) return;
                    let binary = '';
                    for (let offset = 0; offset < bytes.length; offset += 8192) {
                        binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
                    }
                    post({kind: 'binary', value: encode(binary)});
                }
            });
            Object.defineProperty(globalThis, 'TelegramWebProxy', {value: bridge, configurable: false});
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        guard !closing, message.webView === webView, message.name == handlerName,
              frame.isMainFrame, frame.securityOrigin.protocol == "https",
              frame.securityOrigin.host == host, [0, 443].contains(frame.securityOrigin.port),
              let url = frame.request.url, isRelayURL(url),
              let body = message.body as? [String: String], let value = body["value"] else { return }

        let carrierMessage: WebProxyCarrierMessage
        switch body["kind"] {
        case "text" where value.utf8.count <= Self.maximumControlSize:
            carrierMessage = .webProxyCarrierMessageText(WebProxyCarrierMessageText(text: value))
        case "binary" where value.utf8.count <= ((Self.maximumFrameSize + 2) / 3) * 4:
            guard let data = Data(base64Encoded: value), data.count <= Self.maximumFrameSize else { return }
            carrierMessage = .webProxyCarrierMessageBinary(WebProxyCarrierMessageBinary(data: data))
        default:
            return
        }
        receivedMessage = true
        startupTask?.cancel()
        if case .dropped = messages.continuation.yield(carrierMessage) {
            fail(.webProxyCarrierErrorTerminated)
        }
    }

    func deliver(_ data: Data) {
        guard !closing else { return }
        guard data.count <= Self.maximumFrameSize else {
            fail(.webProxyCarrierErrorTerminated)
            return
        }
        if case .dropped = deliveries.continuation.yield(.data(data)) {
            fail(.webProxyCarrierErrorTerminated)
        }
    }

    func close() {
        guard !closing else { return }
        closing = true
        startupTask?.cancel()
        messages.continuation.finish()
        messageTask?.cancel()
        if receivedMessage, case .enqueued = deliveries.continuation.yield(.close) {
            // Give the page a short chance to end its relay session.
            deliveries.continuation.finish()
            Task { [self] in
                try? await Task.sleep(for: .milliseconds(200))
                destroyView()
            }
        } else {
            destroyView()
        }
    }

    private func failLoading(_ reason: String) {
        fail(.webProxyCarrierErrorLoadFailed(WebProxyCarrierErrorLoadFailed(message: reason)))
    }

    private func fail(_ error: WebProxyCarrierError) {
        guard !closing else { return }
        closing = true
        destroyView()
        // Only fixed reason strings go to TDLib. WebKit errors can contain the
        // capability-bearing URL in their description or metadata.
        try? client.reportWebProxyCarrierError(carrierId: carrierID, error: error) { _ in }
    }

    private func destroyView() {
        startupTask?.cancel()
        messages.continuation.finish()
        deliveries.continuation.finish()
        messageTask?.cancel()
        deliveryTask?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private func isRelayURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == host && url.port == nil && url.user == nil
            && url.password == nil && url.path(percentEncoded: true).hasPrefix(pathPrefix)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !closing, !navigationStarted, action.targetFrame?.isMainFrame == true,
              action.request.url == relayURL else { return .cancel }
        navigationStarted = true
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !closing, response.isForMainFrame, let http = response.response as? HTTPURLResponse,
              let url = http.url, isRelayURL(url), url.path(percentEncoded: true) == relayURL.path(percentEncoded: true),
              url.query == relayURL.query,
              http.statusCode == 200, http.mimeType == "text/html", response.canShowMIMEType else {
            failLoading("Relay returned an unexpected response")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        failLoading("Relay redirected the bridge page")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Swift.Error) {
        failLoading("Could not load the relay page")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Swift.Error) {
        failLoading("Could not load the relay page")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(.webProxyCarrierErrorTerminated)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
         ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    #if !os(macOS)
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
    #endif
}
