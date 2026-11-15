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

struct WiFiProxyRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var ssid = ""
    var proxy = SOCKS5ProxyConfiguration()
}

struct TelegramProxyConfiguration: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case direct, proxy, automatic
    }

    var mode = Mode.direct
    var proxy = SOCKS5ProxyConfiguration()
    var useProxyForOtherNetworks = false
    var wifiRules: [WiFiProxyRule] = []

    var isValid: Bool {
        switch mode {
        case .direct: return true
        case .proxy: return proxy.isValid
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
        case .direct: return nil
        case .proxy: return proxy.normalized
        case .automatic:
            if isWiFi, let ssid, let rule = wifiRules.first(where: { $0.ssid == ssid }) {
                return rule.proxy.normalized
            }
            return useProxyForOtherNetworks ? proxy.normalized : nil
        }
    }
}
