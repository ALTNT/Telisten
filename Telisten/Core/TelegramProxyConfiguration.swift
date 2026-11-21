import Foundation

struct SOCKS5ProxyConfiguration: Codable, Equatable, Sendable {
    var server = ""
    var port = "7893"
    var username = ""
    var password = ""

    var normalized: Self {
        var value = self
        value.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        value.port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    var isValid: Bool {
        let value = normalized
        return !value.server.isEmpty && !value.server.contains("://")
            && !value.server.contains(where: { $0.isWhitespace || $0 == "/" })
            && Int(value.port).map { (1...65535).contains($0) } == true
            && username.utf8.count <= 255 && password.utf8.count <= 255
    }
}

struct WebProxyConfiguration: Codable, Equatable, Sendable {
    var server = ""
    var path = ""
    var secret = ""

    var normalized: Self {
        Self(
            server: server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            path: path.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            secret: secretHex ?? secret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var isValid: Bool {
        let value = normalized
        return Self.isDomain(value.server) && Self.isRelayPath(value.path) && secretHex != nil
    }

    static func isDomain(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 253 && labels.count > 1
            && labels.last?.range(of: "[a-z]", options: .regularExpression) != nil
            && labels.allSatisfy {
                $0.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
            }
    }

    static func isRelayPath(_ value: String) -> Bool {
        value.isEmpty || (value.utf8.count <= 128
            && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*(?:/[A-Za-z0-9][A-Za-z0-9_-]*)*$"#,
                           options: .regularExpression) != nil)
    }

    private var secretHex: String? {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^(?:[0-9A-Fa-f]{32}|[dD]{2}[0-9A-Fa-f]{32})$"#, options: .regularExpression) != nil {
            return value.lowercased()
        }
        // Telegram's WEB share links encode the secret in base64url, optionally with a 0x70 marker.
        guard value.range(of: #"^[A-Za-z0-9_-]{22,24}$"#, options: .regularExpression) != nil else { return nil }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let decoded = Data(base64Encoded: base64 + padding),
              decoded.base64EncodedString() == base64 + padding else { return nil }
        let bytes = decoded.count >= 17 && decoded.first == 0x70 ? decoded.dropFirst() : decoded[...]
        guard bytes.count == 16 || (bytes.count == 17 && bytes.first == 0xdd) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct WiFiProxyRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var ssid = ""
    var proxy = SOCKS5ProxyConfiguration()
}

struct TelegramProxyConfiguration: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case direct, proxy, automatic, web
    }

    var mode = Mode.direct
    var proxy = SOCKS5ProxyConfiguration()
    var useProxyForOtherNetworks = false
    var wifiRules: [WiFiProxyRule] = []
    // Optional so settings saved by earlier versions still decode.
    var webProxy: WebProxyConfiguration?

    var isValid: Bool {
        switch mode {
        case .direct: return true
        case .proxy: return proxy.isValid
        case .web: return webProxy?.isValid == true
        case .automatic:
            let names = wifiRules.map(\.ssid)
            return (!useProxyForOtherNetworks || proxy.isValid)
                && wifiRules.allSatisfy { !$0.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.proxy.isValid }
                && Set(names).count == names.count
        }
    }

    /// An unreadable SSID never matches a LAN rule; the explicit fallback applies.
    func selectedProxy(isWiFi: Bool, ssid: String?) -> SOCKS5ProxyConfiguration? {
        switch mode {
        case .direct, .web: return nil
        case .proxy: return proxy.normalized
        case .automatic:
            if isWiFi, let ssid, let rule = wifiRules.first(where: { $0.ssid == ssid }) {
                return rule.proxy.normalized
            }
            return useProxyForOtherNetworks ? proxy.normalized : nil
        }
    }
}

struct WiFiProxyNetworkState {
    private(set) var ssid: String?

    mutating func update(isWiFi: Bool, ssid: String?, canReadSSID: Bool) -> String? {
        if let ssid {
            self.ssid = ssid
        } else if !isWiFi || !canReadSSID {
            self.ssid = nil
        }
        // A nil read while Wi-Fi is still available is not proof of leaving
        // the matched network. Retain the last verified name until evidence
        // of another network, a non-Wi-Fi path, or a permission change arrives.
        return self.ssid
    }
}
