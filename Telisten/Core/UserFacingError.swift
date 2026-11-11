import Foundation

enum UserFacingError {
    static func isExpiredTelegramSession(_ error: Error) -> Bool {
        let message = error.localizedDescription.uppercased()
        return ["AUTH_KEY_UNREGISTERED", "SESSION_REVOKED", "SESSION_EXPIRED", "AUTH_KEY_DUPLICATED"]
            .contains(where: message.contains)
    }

    static func message(for error: Error) -> String {
        let message = error.localizedDescription
        let uppercased = message.uppercased()
        if ["AUTH_KEY_UNREGISTERED", "SESSION_REVOKED", "SESSION_EXPIRED", "AUTH_KEY_DUPLICATED"]
            .contains(where: uppercased.contains) {
            return "Your Telegram session expired. Sign in again to continue."
        }
        if uppercased.contains("FILE_REFERENCE_EXPIRED") || uppercased.contains("FILE_REFERENCE_INVALID") {
            return "This track reference expired. Refresh the music list and try again."
        }
        if uppercased.contains("CHAT_ADMIN_REQUIRED") || uppercased.contains("RIGHT_FORBIDDEN") {
            return "Your Telegram admin role does not allow this action."
        }
        return String(format: localizedUI("Telegram error: %@"), message)
    }
}
