import Foundation
import TDLibKit

enum TelegramMapping {
    static func account(from user: User, accountID: String) -> TelegramAccount {
        let displayName = [user.firstName, user.lastName]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        return TelegramAccount(
            id: accountID,
            userID: user.id,
            displayName: displayName.isEmpty ? "Telegram Account" : displayName,
            username: user.usernames?.activeUsernames.first,
            avatarPhotoID: user.profilePhoto.map { Int64($0.big.id) }
        )
    }

    static func chat(from chat: Chat, username: String? = nil) -> MusicChat? {
        let kind: PeerKind
        let isBroadcast: Bool?
        switch chat.type {
        case .chatTypePrivate:
            kind = .user
            isBroadcast = nil
        case .chatTypeBasicGroup:
            kind = .group
            isBroadcast = false
        case let .chatTypeSupergroup(value):
            kind = .channel
            isBroadcast = value.isChannel
        case .chatTypeSecret:
            return nil
        }
        return MusicChat(
            id: String(chat.id),
            peerID: chat.id,
            accessHash: nil,
            kind: kind,
            title: chat.title,
            username: username,
            avatarPhotoID: chat.photo.map { Int64($0.small.id) },
            isBroadcast: isBroadcast,
            isPinned: chat.positions.contains(where: \.isPinned),
            isAdmin: chat.permissions.canChangeInfo,
            canInviteUsers: chat.permissions.canInviteUsers,
            canManageCalls: chat.permissions.canChangeInfo
        )
    }

    static func track(from message: Message) -> Track? {
        let file: File
        let fileName: String
        let mimeType: String
        let title: String
        let artist: String
        let duration: TimeInterval
        switch message.content {
        case let .messageAudio(value):
            file = value.audio.audio
            fileName = value.audio.fileName
            mimeType = value.audio.mimeType
            title = value.audio.title
            artist = value.audio.performer
            duration = TimeInterval(value.audio.duration)
        case let .messageDocument(value):
            file = value.document.document
            fileName = value.document.fileName
            mimeType = value.document.mimeType
            guard AudioDocumentFormat.isWAV(fileName: fileName, mimeType: mimeType) else { return nil }
            title = fileName.deletingPathExtension
            artist = ""
            duration = 0
        default:
            return nil
        }
        return Track(
            documentID: Int64(file.id),
            accessHash: 0,
            fileReference: Data(),
            dcID: 0,
            messageID: message.id,
            chatID: String(message.chatId),
            title: title,
            artist: artist,
            fileName: fileName,
            mimeType: mimeType,
            duration: duration,
            size: file.size > 0 ? file.size : file.expectedSize,
            date: Date(timeIntervalSince1970: TimeInterval(message.date)),
            remoteUniqueID: file.remote.uniqueId.isEmpty ? nil : file.remote.uniqueId
        )
    }

    static func lyricsAttachment(from message: Message) -> TelegramLyricsAttachment? {
        guard case let .messageDocument(value) = message.content,
              value.document.fileName.lowercased().hasSuffix(".lrc") else { return nil }
        let file = value.document.document
        return TelegramLyricsAttachment(
            documentID: Int64(file.id),
            accessHash: 0,
            fileReference: Data(),
            dcID: 0,
            messageID: message.id,
            chatID: String(message.chatId),
            fileName: value.document.fileName,
            mimeType: value.document.mimeType,
            size: file.size > 0 ? file.size : file.expectedSize,
            date: Date(timeIntervalSince1970: TimeInterval(message.date))
        )
    }

    static func text(from message: Message) -> String {
        switch message.content {
        case let .messageText(value): value.text.text
        case let .messageAudio(value): value.caption.text
        case let .messageDocument(value): value.caption.text
        default: ""
        }
    }

    static func botMessage(from message: Message) -> BotSearchMessage? {
        let text = text(from: message).trimmingCharacters(in: .whitespacesAndNewlines)
        let track = track(from: message)
        let rows = buttonRows(from: message.replyMarkup, chatID: message.chatId, messageID: message.id)
        guard !text.isEmpty || track != nil || !rows.isEmpty else { return nil }
        return BotSearchMessage(
            id: message.id,
            isOutgoing: message.isOutgoing,
            text: text,
            date: Date(timeIntervalSince1970: TimeInterval(max(message.date, message.editDate))),
            buttonRows: rows,
            track: track
        )
    }

    static func comment(from message: Message) -> TrackComment? {
        let text = text(from: message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let author: String
        if !message.authorSignature.isEmpty {
            author = message.authorSignature
        } else {
            switch message.senderId {
            case .messageSenderUser:
                author = "Telegram user"
            case .messageSenderChat:
                author = "Telegram channel"
            }
        }
        return TrackComment(
            id: "\(message.chatId):\(message.id)",
            author: author,
            text: text,
            date: Date(timeIntervalSince1970: TimeInterval(message.date))
        )
    }

    static func chatID(from value: String) -> Int64? {
        Int64(value)
    }

    static func fileID(from value: Int64) -> Int? {
        guard value > 0, value <= Int64(Int.max) else { return nil }
        return Int(value)
    }

    private static func buttonRows(
        from markup: ReplyMarkup?,
        chatID: Int64,
        messageID: Int64
    ) -> [[BotSearchButton]] {
        switch markup {
        case let .replyMarkupInlineKeyboard(value):
            return value.rows.enumerated().map { rowIndex, row in
                row.enumerated().map { buttonIndex, button in
                    let action: BotSearchButtonAction
                    switch button.type {
                    case let .inlineKeyboardButtonTypeCallback(callback):
                        action = .callback(messageID: messageID, data: callback.data)
                    case let .inlineKeyboardButtonTypeUrl(url):
                        action = URL(string: url.url).map(BotSearchButtonAction.openURL) ?? .unsupported
                    default:
                        action = .unsupported
                    }
                    return BotSearchButton(
                        id: "\(chatID):\(messageID):\(rowIndex):\(buttonIndex)",
                        title: button.text,
                        action: action
                    )
                }
            }
        case let .replyMarkupShowKeyboard(value):
            return value.rows.enumerated().map { rowIndex, row in
                row.enumerated().map { buttonIndex, button in
                    BotSearchButton(
                        id: "\(chatID):\(messageID):\(rowIndex):\(buttonIndex)",
                        title: button.text,
                        action: .sendText(button.text)
                    )
                }
            }
        default:
            return []
        }
    }
}
