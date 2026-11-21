import Foundation

@main
enum TelegramProxyTests {
    static func main() throws {
        let lan = SOCKS5ProxyConfiguration(server: "192.168.234.236", port: "7893")
        let remote = SOCKS5ProxyConfiguration(server: "proxy.example.org", port: "1080", username: "user", password: "secret")
        var settings = TelegramProxyConfiguration()
        settings.proxy = remote
        settings.wifiRules = [WiFiProxyRule(ssid: "Home", proxy: lan)]
        precondition(settings.selectedProxy(isWiFi: true, ssid: "Home") == nil)
        settings.mode = .proxy
        precondition(settings.selectedProxy(isWiFi: false, ssid: nil) == remote)
        settings.mode = .automatic
        precondition(settings.isValid)
        precondition(settings.selectedProxy(isWiFi: true, ssid: "Home") == lan)
        precondition(settings.selectedProxy(isWiFi: true, ssid: "Cafe") == nil)
        precondition(settings.selectedProxy(isWiFi: false, ssid: "Home") == nil)
        precondition(settings.selectedProxy(isWiFi: true, ssid: nil) == nil)
        settings.useProxyForOtherNetworks = true
        precondition(settings.selectedProxy(isWiFi: false, ssid: nil) == remote)
        precondition(settings.selectedProxy(isWiFi: true, ssid: nil) == remote)
        precondition(settings.selectedProxy(isWiFi: true, ssid: "home") == remote)
        precondition(settings.selectedProxy(isWiFi: true, ssid: "Home") == lan)
        settings.wifiRules.append(WiFiProxyRule(ssid: "Office", proxy: remote))
        precondition(settings.selectedProxy(isWiFi: true, ssid: "Office") == remote)
        let restored = try JSONDecoder().decode(TelegramProxyConfiguration.self, from: JSONEncoder().encode(settings))
        precondition(restored == settings)
        let legacy = try JSONEncoder().encode(settings)
        precondition(!String(decoding: legacy, as: UTF8.self).contains("webProxy"))
        precondition(restored.webProxy == nil)
        let webProxy = WebProxyConfiguration(
            server: " Proxy.Example.Org ", path: " /telegram/web/ ", secret: "cAABAgMEBQYHCAkKCwwNDg8"
        )
        let normalizedWebProxy = WebProxyConfiguration(
            server: "proxy.example.org", path: "telegram/web", secret: "000102030405060708090a0b0c0d0e0f"
        )
        var webSettings = settings
        webSettings.mode = .web
        precondition(!webSettings.isValid)
        webSettings.webProxy = webProxy
        precondition(webSettings.isValid && webProxy.normalized == normalizedWebProxy)
        precondition(webSettings.selectedProxy(isWiFi: true, ssid: "Home") == nil)
        let restoredWeb = try JSONDecoder().decode(TelegramProxyConfiguration.self, from: JSONEncoder().encode(webSettings))
        precondition(restoredWeb == webSettings)
        let paddedSalt = Data([0x70, 0xdd] + Array(0..<16)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        precondition(WebProxyConfiguration(server: webProxy.server, secret: paddedSalt).normalized.secret
                     == "dd" + normalizedWebProxy.secret)
        for invalid in ["127.0.0.1", "https://proxy.example.org", "proxy.example.org:443", "proxy..example.org"] {
            precondition(!WebProxyConfiguration(server: invalid, secret: webProxy.secret).isValid)
        }
        for invalid in ["a/../b", "a//b", "a/%2f", "a?b", String(repeating: "a", count: 129)] {
            precondition(!WebProxyConfiguration(server: webProxy.server, path: invalid, secret: webProxy.secret).isValid)
        }
        for invalid in ["", "0011", "cAABAgMEBQYHCAkKCwwNDg9", "ee" + normalizedWebProxy.secret] {
            precondition(!WebProxyConfiguration(server: webProxy.server, secret: invalid).isValid)
        }
        settings.wifiRules.append(WiFiProxyRule(ssid: "Home", proxy: remote))
        precondition(!settings.isValid)
        settings.wifiRules = [WiFiProxyRule(ssid: " ", proxy: lan)]
        precondition(!settings.isValid)
        for port in ["0", "65536", "-1", "abc", ""] {
            precondition(!SOCKS5ProxyConfiguration(server: "localhost", port: port).isValid)
        }
        for host in ["", "socks5://localhost", "host/path", "bad host"] {
            precondition(!SOCKS5ProxyConfiguration(server: host, port: "1080").isValid)
        }
        precondition(SOCKS5ProxyConfiguration(server: " ::1 ", port: " 1080 ").isValid)
        precondition(SOCKS5ProxyConfiguration(server: "localhost", port: "65535").isValid)
        precondition(!SOCKS5ProxyConfiguration(server: "localhost", username: String(repeating: "x", count: 256)).isValid)
        var network = WiFiProxyNetworkState()
        var stableSettings = TelegramProxyConfiguration()
        stableSettings.mode = .automatic
        stableSettings.wifiRules = [WiFiProxyRule(ssid: "Home", proxy: lan)]
        precondition(network.update(isWiFi: true, ssid: nil, canReadSSID: true) == nil)
        precondition(network.update(isWiFi: true, ssid: "Home", canReadSSID: true) == "Home")
        for _ in 0..<100 {
            let name = network.update(isWiFi: true, ssid: nil, canReadSSID: true)
            precondition(stableSettings.selectedProxy(isWiFi: true, ssid: name) == lan)
        }
        let cafe = network.update(isWiFi: true, ssid: "Cafe", canReadSSID: true)
        precondition(stableSettings.selectedProxy(isWiFi: true, ssid: cafe) == nil)
        precondition(network.update(isWiFi: true, ssid: nil, canReadSSID: true) == "Cafe")
        _ = network.update(isWiFi: true, ssid: "Home", canReadSSID: true)
        precondition(network.update(isWiFi: false, ssid: nil, canReadSSID: true) == nil)
        precondition(network.update(isWiFi: true, ssid: nil, canReadSSID: true) == nil)
        _ = network.update(isWiFi: true, ssid: "Home", canReadSSID: true)
        precondition(network.update(isWiFi: true, ssid: nil, canReadSSID: false) == nil)
        precondition(network.update(isWiFi: true, ssid: nil, canReadSSID: true) == nil)
        // A real SSID read is stronger evidence than a VPN's default path type.
        precondition(network.update(isWiFi: false, ssid: "Home", canReadSSID: true) == "Home")
        print("Telegram proxy rules, WEB credentials, persisted settings, and transient SSID handling passed")
    }
}
