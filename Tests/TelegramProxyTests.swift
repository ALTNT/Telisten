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
        print("Telegram proxy rules, validation, and transient SSID handling passed")
    }
}
