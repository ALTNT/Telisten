import SwiftUI

struct TelegramProxySettingsView: View {
    @ObservedObject var controller: TelegramProxyController
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TelegramProxyConfiguration()
    @State private var isSaving = false
    @State private var pendingWiFiRuleID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Picker("Mode", selection: $draft.mode) {
                        Text("Direct / System VPN").tag(TelegramProxyConfiguration.Mode.direct)
                        Text("SOCKS5 proxy").tag(TelegramProxyConfiguration.Mode.proxy)
                        Text("Automatic by Wi-Fi").tag(TelegramProxyConfiguration.Mode.automatic)
                    }
                    LabeledContent("Applied connection", value: controller.status)
                    Text("Direct connections follow system routing, including an enabled VPN. Telisten does not turn the system VPN on or off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.mode == .automatic {
                    Section("Wi-Fi detection") {
                        LabeledContent("Current Wi-Fi", value: controller.currentSSID ?? localizedUI("Unavailable"))
                        #if os(iOS)
                        Button("Allow Wi-Fi detection") { controller.requestWiFiAccess() }
                        if let message = controller.wifiDetectionMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Allow precise location to read the Wi-Fi name. If the name is unavailable, the other networks setting applies.")
                            .font(.caption).foregroundStyle(.secondary)
                        #else
                        Text("Wi-Fi name detection is available on iPhone and iPad. Use a fixed proxy or the other networks setting on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                        #endif
                    }
                    ForEach($draft.wifiRules) { $rule in
                        Section("Wi-Fi proxy") {
                            TextField("Wi-Fi name (SSID)", text: $rule.ssid)
                                .autocorrectionDisabled()
                                #if os(iOS) || os(visionOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            if let ssid = controller.currentSSID {
                                Button("Use current Wi-Fi") { rule.ssid = ssid }
                            }
                            proxyFields($rule.proxy)
                            Button("Delete Wi-Fi rule", role: .destructive) {
                                draft.wifiRules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                    Section {
                        Button("Add Wi-Fi rule", systemImage: "plus") {
                            let rule = WiFiProxyRule(ssid: controller.currentSSID ?? "")
                            draft.wifiRules.append(rule)
                            #if os(iOS)
                            if controller.currentSSID == nil {
                                pendingWiFiRuleID = rule.id
                                controller.requestWiFiAccess()
                            }
                            #endif
                        }
                        Toggle("Use SOCKS5 on other networks", isOn: $draft.useProxyForOtherNetworks)
                        Text("Unmatched Wi-Fi and mobile data use this setting. Leave it off to use your phone’s VPN on mobile data.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if draft.mode == .proxy || (draft.mode == .automatic && draft.useProxyForOtherNetworks) {
                    Section("SOCKS5 server") { proxyFields($draft.proxy) }
                }
                if let error = controller.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Save") {
                        isSaving = true
                        Task {
                            let saved = await controller.save(draft)
                            isSaving = false
                            if saved && controller.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(isSaving)
                    if isSaving { ProgressView() }
                } footer: {
                    Text("Proxy settings and credentials are stored in this device’s Keychain. Changes apply to Telegram login, messages, and media transfers.")
                }
            }
            .disabled(isSaving)
            .navigationTitle("Telegram proxy")
            .onChange(of: controller.currentSSID) { ssid in
                guard let ssid, let id = pendingWiFiRuleID else { return }
                // Authorization may finish after the rule was added. Only fill
                // that rule, and preserve any name the user has already typed.
                if let index = draft.wifiRules.firstIndex(where: { $0.id == id }),
                   draft.wifiRules[index].ssid.isEmpty {
                    draft.wifiRules[index].ssid = ssid
                }
                pendingWiFiRuleID = nil
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                draft = controller.configuration
                await controller.refresh()
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 540)
            #endif
        }
    }

    private func proxyFields(_ proxy: Binding<SOCKS5ProxyConfiguration>) -> some View {
        Group {
            TextField("Hostname or IP address", text: proxy.server)
            TextField("Port", text: proxy.port)
                #if os(iOS) || os(visionOS)
                .keyboardType(.numberPad)
                #endif
            TextField("Username (optional)", text: proxy.username)
            SecureField("Password (optional)", text: proxy.password)
        }
        .autocorrectionDisabled()
        #if os(iOS) || os(visionOS)
        .textInputAutocapitalization(.never)
        #endif
    }
}
