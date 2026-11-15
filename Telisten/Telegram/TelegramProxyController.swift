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
    private let telegram: TelegramService
    private let keychain: KeychainStore
    private let monitor = NWPathMonitor()
    private var started = false
    private var refreshRevision = 0
    private var lastProxyDiagnostic: String?
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
        await refresh()
        return true
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
        #if os(iOS)
        if ssid != nil {
            wifiDetectionMessage = nil
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
        let proxy = configuration.selectedProxy(isWiFi: isWiFi || ssid != nil, ssid: ssid)
        let selection = "mode=\(configuration.mode.rawValue) rules=\(configuration.wifiRules.count) matchedWiFi=\(ssid.map { name in configuration.wifiRules.contains { $0.ssid == name } } ?? false) target=\(proxy.map { "SOCKS5 \($0.server):\($0.port)" } ?? "direct")"
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
