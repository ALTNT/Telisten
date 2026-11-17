import Foundation
import Combine
import Network
#if os(iOS)
import CoreLocation
import NetworkExtension
#endif

@MainActor
final class TelegramProxyController: NSObject, ObservableObject {
    @Published private(set) var configuration: TelegramProxyConfiguration
    @Published private(set) var currentSSID: String?
    @Published private(set) var isWiFi = false
    @Published private(set) var status = localizedUI("Checking network…")
    @Published private(set) var errorMessage: String?
    @Published private(set) var wifiDetectionMessage: String?
    @Published private(set) var isTestingProxy = false
    @Published private(set) var proxyTestResult: String?
    private let telegram: TelegramService
    private let keychain: KeychainStore
    private let monitor = NWPathMonitor()
    private var started = false
    private var refreshRevision = 0
    private var lastProxyDiagnostic: String?
    private var wifiNetworkState = WiFiProxyNetworkState()
    private var pollingTask: Task<Void, Never>?
    #if os(iOS)
    private let locationManager = CLLocationManager()
    private var pendingWiFiAuthorization = false
    private var lastWiFiDiagnostic: String?

    #endif

    init(telegram: TelegramService, keychain: KeychainStore) {
        self.telegram = telegram
        self.keychain = keychain
        configuration = keychain.loadTelegramProxyConfiguration() ?? TelegramProxyConfiguration()
        super.init()
        #if os(iOS)
        locationManager.delegate = self
        #endif
    }

    func start() async {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isWiFi = wifi
                if !wifi {
                    _ = self.wifiNetworkState.update(isWiFi: false, ssid: nil, canReadSSID: true)
                }
                await self.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "Telisten.proxy-network"))
        // Path updates can omit a change between two Wi-Fi access points.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                if self.configuration.mode == .automatic {
                    await self.refresh()
                }
            }
        }
        await refresh()
    }

    func save(_ value: TelegramProxyConfiguration) async -> Bool {
        guard value.isValid else {
            errorMessage = localizedUI("Check proxy hosts, ports (1–65535), and unique Wi-Fi names.")
            return false
        }
        guard keychain.saveTelegramProxyConfiguration(value) else {
            errorMessage = localizedUI("Could not save proxy settings in Keychain.")
            return false
        }
        configuration = value
        proxyTestResult = nil
        await refresh()
        return true
    }

    func testSavedProxy() async {
        guard !isTestingProxy else { return }
        guard let proxy = configuration.selectedProxy(isWiFi: isWiFi || wifiNetworkState.ssid != nil, ssid: wifiNetworkState.ssid) else {
            proxyTestResult = localizedUI("No SOCKS5 proxy is selected for this network. Save a fixed proxy or a matching Wi-Fi rule first.")
            return
        }
        isTestingProxy = true
        defer { isTestingProxy = false }
        proxyTestResult = localizedUI("Testing connection to the proxy…")
        var stage = "tcp"
        do {
            PlaybackDiagnostics.log("proxy_device_test_start target=\(proxy.server):\(proxy.port)")
            try await TelegramProxyTCPProbe(proxy: proxy).run()
            PlaybackDiagnostics.log("proxy_device_tcp_ready")
            stage = "telegram"
            proxyTestResult = localizedUI("Proxy TCP connected. Checking Telegram latency…")
            try await telegram.testConnectionProxy(proxy)
            proxyTestResult = localizedUI("SOCKS5 and Telegram connection succeeded.")
        } catch {
            PlaybackDiagnostics.log("proxy_device_test_failed stage=\(stage)", error: error)
            let format = stage == "tcp" ? "Connection to the proxy failed: %@" : "TCP connected, but the Telegram latency probe failed: %@"
            proxyTestResult = String(format: localizedUI(format), localizedUI(error.localizedDescription))
        }
    }

    func requestWiFiAccess() {
        #if os(iOS)
        pendingWiFiAuthorization = true
        PlaybackDiagnostics.log("proxy_wifi_authorization_requested authorization=\(locationManager.authorizationStatus.rawValue) accuracy=\(locationManager.accuracyAuthorization.rawValue)")
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            completeWiFiAuthorization()
        }
        #else
        Task { await refresh() }
        #endif
    }

    #if os(iOS)
    private func completeWiFiAuthorization() {
        let authorized = locationManager.authorizationStatus == .authorizedWhenInUse
            || locationManager.authorizationStatus == .authorizedAlways
        // The initial location prompt is asynchronous. Request precise access
        // after it completes, rather than only on a second button press.
        if pendingWiFiAuthorization, authorized {
            pendingWiFiAuthorization = false
            if locationManager.accuracyAuthorization == .reducedAccuracy {
                locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WiFiProxy") { error in
                    if let error { PlaybackDiagnostics.log("proxy_wifi_precise_authorization_failed", error: error) }
                    Task { @MainActor [weak self] in await self?.refresh() }
                }
                return
            }
        } else if locationManager.authorizationStatus != .notDetermined {
            pendingWiFiAuthorization = false
        }
        Task { await refresh() }
    }
    #endif

    func refresh() async {
        refreshRevision += 1
        let revision = refreshRevision
        var ssid: String?
        #if os(iOS)
        ssid = await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
        #endif
        guard revision == refreshRevision else { return }
        currentSSID = ssid
        var canReadSSID = false
        #if os(iOS)
        canReadSSID = (locationManager.authorizationStatus == .authorizedWhenInUse
            || locationManager.authorizationStatus == .authorizedAlways)
            && locationManager.accuracyAuthorization == .fullAccuracy
        #endif
        let routingSSID = wifiNetworkState.update(isWiFi: isWiFi, ssid: ssid, canReadSSID: canReadSSID)
        #if os(iOS)
        if ssid != nil {
            wifiDetectionMessage = nil
        } else if routingSSID != nil {
            wifiDetectionMessage = localizedUI("Wi-Fi name is temporarily unavailable. Keeping the last verified Wi-Fi rule until the network can be identified.")
        } else {
            switch locationManager.authorizationStatus {
            case .notDetermined:
                wifiDetectionMessage = localizedUI("Allow location access to read the current Wi-Fi name.")
            case .denied, .restricted:
                wifiDetectionMessage = localizedUI("Location access is denied or restricted. Enable it in iOS Settings to detect Wi-Fi.")
            default:
                wifiDetectionMessage = locationManager.accuracyAuthorization == .reducedAccuracy
                    ? localizedUI("Precise location is off. Allow precise location to detect Wi-Fi.")
                    : localizedUI("iOS returned no Wi-Fi name. Check the Wi-Fi connection, Location Services, and the installed app’s Wi-Fi entitlement.")
            }
        }
        // Log permission states, never the SSID or credentials.
        let diagnostic = "pathWiFi=\(isWiFi) ssidAvailable=\(ssid != nil) authorization=\(locationManager.authorizationStatus.rawValue) accuracy=\(locationManager.accuracyAuthorization.rawValue)"
        if diagnostic != lastWiFiDiagnostic {
            PlaybackDiagnostics.log("proxy_wifi_detection \(diagnostic)")
            lastWiFiDiagnostic = diagnostic
        }
        #endif
        // A VPN can expose a different default path while Wi-Fi is connected.
        let proxy = configuration.selectedProxy(isWiFi: isWiFi || routingSSID != nil, ssid: routingSSID)
        let selection = "mode=\(configuration.mode.rawValue) rules=\(configuration.wifiRules.count) matchedWiFi=\(routingSSID.map { name in configuration.wifiRules.contains { $0.ssid == name } } ?? false) ssidRetained=\(ssid == nil && routingSSID != nil) target=\(proxy.map { "SOCKS5 \($0.server):\($0.port)" } ?? "direct")"
        if selection != lastProxyDiagnostic {
            PlaybackDiagnostics.log("proxy_configuration_selected \(selection)")
            lastProxyDiagnostic = selection
        }
        do {
            try await telegram.setConnectionProxy(proxy)
            let applied = await telegram.connectionProxyIsApplied(proxy)
            guard revision == refreshRevision else { return }
            guard applied else {
                status = localizedUI("Waiting for Telegram connection")
                return
            }
            status = proxy.map { "SOCKS5 · \($0.server):\($0.port)" } ?? localizedUI("Direct / System VPN")
            errorMessage = nil
        } catch {
            guard revision == refreshRevision else { return }
            status = localizedUI("Proxy could not be applied")
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

#if os(iOS)
extension TelegramProxyController: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.completeWiFiAuthorization() }
    }
}
#endif

@MainActor
private final class TelegramProxyTCPProbe {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var localNetworkDenied = false
    private var waitingError: NWError?

    private enum ProbeError: LocalizedError {
        case localNetworkDenied, timeout, invalidConfiguration
        case network(String)
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                localizedUI("Invalid SOCKS5 proxy settings.")
            case let .network(message):
                String(format: localizedUI("Network error: %@"), message)
            case .localNetworkDenied:
                localizedUI("iOS denied local network access. Allow Telisten in Settings → Privacy & Security → Local Network.")
            case .timeout:
                localizedUI("The proxy TCP connection timed out. Check Wi-Fi routing, client isolation, and the proxy firewall.")
            }
        }
    }

    init(proxy: SOCKS5ProxyConfiguration) throws {
        guard proxy.isValid, let value = UInt16(proxy.normalized.port),
              let port = NWEndpoint.Port(rawValue: value) else { throw ProbeError.invalidConfiguration }
        connection = NWConnection(host: NWEndpoint.Host(proxy.normalized.server), port: port, using: .tcp)
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in self?.receive(state) }
            }
            connection.start(queue: DispatchQueue(label: "Telisten.proxy-tcp-test"))
            // Allow time for the first local-network permission prompt. A
            // waiting/denied path may become ready after the user grants it.
            timeoutTask = Task { [self] in
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                if self.localNetworkDenied {
                    self.finish(.failure(ProbeError.localNetworkDenied))
                } else if let error = self.waitingError {
                    self.finish(.failure(ProbeError.network(String(describing: error))))
                } else {
                    self.finish(.failure(ProbeError.timeout))
                }
            }
        }
    }

    private func receive(_ state: NWConnection.State) {
        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
            localNetworkDenied = true
        }
        switch state {
        case .ready: finish(.success(()))
        case let .waiting(error):
            waitingError = error
            // Network.framework can keep refused TCP connections in waiting
            // rather than failed. Report this concrete error without hiding it
            // behind the general test deadline.
            if !localNetworkDenied, case .posix(.ECONNREFUSED) = error {
                finish(.failure(ProbeError.network(String(describing: error))))
            }
        case let .failed(error):
            if localNetworkDenied { finish(.failure(ProbeError.localNetworkDenied)) }
            else { finish(.failure(ProbeError.network(String(describing: error)))) }
        default: break
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
