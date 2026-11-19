import Foundation

enum AppLanguage: String, CaseIterable {
    static let storageKey = "app.language"

    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case vietnamese = "vi"
    case french = "fr"
    case spanish = "es"
    case korean = "ko"

    var nativeName: String {
        switch self {
        case .system: return ""
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .vietnamese: return "Tiếng Việt"
        case .french: return "Français"
        case .spanish: return "Español"
        case .korean: return "한국어"
        }
    }

    var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    func localized(_ text: String) -> String {
        // Dynamic strings do not receive SwiftUI's locale environment.
        let bundle = self == .system ? Bundle.main
            : Bundle.main.path(forResource: rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: text, value: text, table: "Localizable")
    }
}

func localizedUI(_ text: String) -> String {
    let selection = UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? ""
    return (AppLanguage(rawValue: selection) ?? .system).localized(text)
}

@MainActor
enum DisplayFormat {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    static func fileSize(_ value: Int64) -> String {
        bytes.string(fromByteCount: value)
    }
}
