import Foundation
import UIKit
import Postbox
import SwiftSignalKit

/// A fake Telegram.
///
/// This is the whole point of this build: there is no real Telegram inside it. No request ever
/// reaches a Telegram server: authorization completes locally (`Authorization.swift`), the
/// account's network is pinned to a closed loopback SOCKS5 proxy (`hermeticProxySettings`), and
/// the postbox is seeded with fake peers, messages and star gifts (`demoSeedPostbox`).
///
/// The fake mode is on by default so that a build installed on a device behaves the same as one
/// started from Xcode. Launch with `--real` to opt out and get the regular Telegram sign-in.
public enum DemoMode {
    public static let isEnabled: Bool = !CommandLine.arguments.contains("--real")

    /// The demo account's own peer. Must not be `777000`: that id is Telegram's own service
    /// account, and the UI special-cases it (it would label the owner "Telegram").
    public static let accountPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(700000000))

    /// Matches what an empty postbox would be opened with in the harness.
    public static let masterDatacenterId: Int32 = 2

    /// The code screen is driven by `SentAuthorizationCodeType.sms(length:)`; any code of this
    /// length signs in.
    public static let codeLength: Int32 = 6

    /// The fake Stars balance the gifts screens start from.
    public static let initialStarsBalance: Int64 = 12500

    private static let starsBalanceKey = "DemoMode.starsBalance"

    /// The fake Stars balance shown by the gifts screens. Gifts paid for in demo mode are
    /// subtracted so the balance behaves like a real wallet, and survives app restarts.
    public static var starsBalance: Int64 {
        if let value = UserDefaults.standard.object(forKey: DemoMode.starsBalanceKey) as? NSNumber {
            return value.int64Value
        }
        return DemoMode.initialStarsBalance
    }

    public static func spendStars(_ amount: Int64) {
        guard amount > 0 else {
            return
        }
        UserDefaults.standard.set(max(0, DemoMode.starsBalance - amount), forKey: DemoMode.starsBalanceKey)
    }

    /// Adds fake Stars bought from the fake top-up screen, so a demo "purchase" grows the
    /// balance exactly like a real one would.
    public static func addStars(_ amount: Int64) {
        guard amount > 0 else {
            return
        }
        DemoMode.setStarsBalance(DemoMode.starsBalance + amount)
    }

    /// Writes the fake Stars balance, clamped at zero like a real wallet. Also used for the
    /// deductions that go through `StarsContext.add` with a negative amount (paid reactions,
    /// paid messages), so those behave in demo mode as they do against a server.
    public static func setStarsBalance(_ value: Int64) {
        UserDefaults.standard.set(max(0, value), forKey: DemoMode.starsBalanceKey)
    }

    private static let deletedStarGiftsKey = "DemoMode.deletedStarGiftMessages"

    /// Profile gifts the demo has been asked to delete.
    ///
    /// A delete takes the gift out of the profile's Gifts tab but leaves the chat message alone,
    /// so the ids are kept here rather than in the postbox and the tab skips them when it
    /// rebuilds. Like the balance, it survives a restart.
    public static var deletedStarGiftMessageIds: Set<Int32> {
        let raw = UserDefaults.standard.array(forKey: DemoMode.deletedStarGiftsKey) as? [Int] ?? []
        return Set(raw.map { Int32($0) })
    }

    public static func markStarGiftDeleted(messageId: Int32) {
        var ids = DemoMode.deletedStarGiftMessageIds
        ids.insert(messageId)
        UserDefaults.standard.set(ids.map { Int($0) }, forKey: DemoMode.deletedStarGiftsKey)
    }

    /// The fake top-up packages shown instead of the ones a server would offer.
    ///
    /// There is no StoreKit product behind them either: the purchase screen formats the price
    /// from these values and grants the Stars locally.
    public static let demoTopUpOptions: [StarsTopUpOption] = [
        StarsTopUpOption(count: 100, storeProductId: "org.telegram.demo.stars.100", currency: "USD", amount: 99, isExtended: false),
        StarsTopUpOption(count: 250, storeProductId: "org.telegram.demo.stars.250", currency: "USD", amount: 249, isExtended: false),
        StarsTopUpOption(count: 500, storeProductId: "org.telegram.demo.stars.500", currency: "USD", amount: 499, isExtended: false),
        StarsTopUpOption(count: 1000, storeProductId: "org.telegram.demo.stars.1000", currency: "USD", amount: 999, isExtended: false),
        StarsTopUpOption(count: 2500, storeProductId: "org.telegram.demo.stars.2500", currency: "USD", amount: 2499, isExtended: false),
        StarsTopUpOption(count: 10000, storeProductId: "org.telegram.demo.stars.10000", currency: "USD", amount: 9999, isExtended: false),
    ]

    /// The fake packages for buying Stars as a gift for someone else.
    public static let demoGiftOptions: [StarsGiftOption] = [
        StarsGiftOption(count: 100, storeProductId: "org.telegram.demo.giftoptions.100", currency: "USD", amount: 99, isExtended: false),
        StarsGiftOption(count: 500, storeProductId: "org.telegram.demo.giftoptions.500", currency: "USD", amount: 499, isExtended: false),
        StarsGiftOption(count: 1000, storeProductId: "org.telegram.demo.giftoptions.1000", currency: "USD", amount: 999, isExtended: false),
        StarsGiftOption(count: 2500, storeProductId: "org.telegram.demo.giftoptions.2500", currency: "USD", amount: 2499, isExtended: false),
        StarsGiftOption(count: 10000, storeProductId: "org.telegram.demo.giftoptions.10000", currency: "USD", amount: 9999, isExtended: false),
    ]

    /// Nothing listens on this port, so every MTProto dial fails locally instead of reaching a
    /// Telegram datacentre. Must be written before the first account is opened.
    public static func hermeticProxySettings() -> ProxySettings {
        let loopback = ProxyServerSettings(host: "127.0.0.1", port: 1, connection: .socks5(username: nil, password: nil))
        return ProxySettings(enabled: true, servers: [loopback], activeServer: loopback, useForCalls: false)
    }
}

// MARK: - Seeding

/// Fills a fresh postbox with the fake account's world: peers, presences, chat list, message
/// histories, read states (unread badges) and the star gifts catalogue.
///
/// Everything happens in the caller's transaction, so it is atomic and takes effect the moment
/// the authorized account opens over the same postbox. Idempotent: it does nothing when the
/// chat list already has entries.
public func demoSeedPostbox(transaction: Transaction, mediaBox: MediaBox, accountPeerId: PeerId) {
    guard transaction.chatListGetAllPeerIds().isEmpty else {
        return
    }

    let now = Int32(Date().timeIntervalSince1970)
    let day: Int32 = 86400

    func cloudUser(_ rawId: Int64, _ firstName: String, _ lastName: String?, username: String?, phone: String?) -> TelegramUser {
        return TelegramUser(
            id: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(rawId)),
            accessHash: nil,
            firstName: firstName,
            lastName: lastName,
            username: username,
            phone: phone,
            photo: [],
            botInfo: nil,
            restrictionInfo: nil,
            flags: [],
            emojiStatus: nil,
            usernames: [],
            storiesHidden: nil,
            nameColor: nil,
            backgroundEmojiId: nil,
            profileColor: nil,
            profileBackgroundEmojiId: nil,
            subscriberCount: nil,
            verificationIconFileId: nil
        )
    }

    // MARK: Peers

    var selfPhone: String? = "+79160000000"
    if let existingSelf = transaction.getPeer(accountPeerId) as? TelegramUser {
        selfPhone = existingSelf.phone
    }
    let selfUser = cloudUser(accountPeerId.id._internalGetInt64Value(), "Александр", "Смирнов", username: "alex_smirnov", phone: selfPhone)

    let annaId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1001))
    let momId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1002))
    let ilyaId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1003))
    let mariaId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1004))
    let dmitryId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1005))

    let designTeamId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(2001))
    let cryptoChatId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(2002))

    let newsId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(3001))
    let cinemaId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(3002))

    let anna = cloudUser(1001, "Анна", "Петрова", username: "anna_petrova", phone: "+79161112233")
    let mom = cloudUser(1002, "Мама", nil, username: nil, phone: "+79031234567")
    let ilya = cloudUser(1003, "Илья", "Соколов", username: "ilya_sokol", phone: "+79165556677")
    let maria = cloudUser(1004, "Мария", "Волкова", username: "maria_volkova", phone: "+79168889900")
    let dmitry = cloudUser(1005, "Дмитрий", "Орлов", username: "d_orlov", phone: "+79163334455")

    let designTeam = TelegramGroup(
        id: designTeamId,
        title: "Дизайн-команда",
        photo: [],
        participantCount: 12,
        role: .member,
        membership: .Member,
        flags: [],
        defaultBannedRights: nil,
        migrationReference: nil,
        creationDate: now - day * 300,
        version: 1
    )

    let cryptoChat = TelegramGroup(
        id: cryptoChatId,
        title: "Крипточат",
        photo: [],
        participantCount: 348,
        role: .member,
        membership: .Member,
        flags: [],
        defaultBannedRights: nil,
        migrationReference: nil,
        creationDate: now - day * 120,
        version: 4
    )

    let news = TelegramChannel(
        id: newsId,
        accessHash: nil,
        title: "Новости Telegram",
        username: "telegram_news",
        photo: [],
        creationDate: now - day * 900,
        version: 1,
        participationStatus: .member,
        info: .broadcast(TelegramChannelBroadcastInfo(flags: [])),
        flags: [.isVerified],
        restrictionInfo: nil,
        adminRights: nil,
        bannedRights: nil,
        defaultBannedRights: nil,
        usernames: [],
        storiesHidden: nil,
        nameColor: nil,
        backgroundEmojiId: nil,
        profileColor: nil,
        profileBackgroundEmojiId: nil,
        emojiStatus: nil,
        approximateBoostLevel: nil,
        subscriptionUntilDate: nil,
        verificationIconFileId: nil,
        sendPaidMessageStars: nil,
        linkedMonoforumId: nil
    )

    let cinema = TelegramChannel(
        id: cinemaId,
        accessHash: nil,
        title: "Киноклуб",
        username: "cinema_club",
        photo: [],
        creationDate: now - day * 450,
        version: 3,
        participationStatus: .member,
        info: .group(TelegramChannelGroupInfo(flags: [])),
        flags: [],
        restrictionInfo: nil,
        adminRights: nil,
        bannedRights: nil,
        defaultBannedRights: nil,
        usernames: [],
        storiesHidden: nil,
        nameColor: nil,
        backgroundEmojiId: nil,
        profileColor: nil,
        profileBackgroundEmojiId: nil,
        emojiStatus: nil,
        approximateBoostLevel: nil,
        subscriptionUntilDate: nil,
        verificationIconFileId: nil,
        sendPaidMessageStars: nil,
        linkedMonoforumId: nil
    )

    let peers: [Peer] = [selfUser, anna, mom, ilya, maria, dmitry, designTeam, cryptoChat, news, cinema]
    transaction.updatePeersInternal(peers, update: { _, updated in updated })

    // MARK: Presences

    transaction.updatePeerPresencesInternal(presences: [
        annaId: TelegramUserPresence(status: .present(until: now + 7200), lastActivity: now),
        ilyaId: TelegramUserPresence(status: .recently(isHidden: false), lastActivity: now - 1800),
        mariaId: TelegramUserPresence(status: .recently(isHidden: false), lastActivity: now - 7200),
        dmitryId: TelegramUserPresence(status: .lastWeek(isHidden: false), lastActivity: now - day * 5),
        momId: TelegramUserPresence(status: .lastMonth(isHidden: false), lastActivity: now - day * 20),
    ], merge: { _, updated in updated })

    // MARK: Cached user data

    // `PeerInfoScreen` only shows a profile's Gifts tab when `starGiftsCount` is greater than
    // zero: the count is normally delivered by the server along with the profile, and there is no
    // server here. The numbers match the gift messages seeded below, so the tab and the gifts
    // inside it always agree.
    for (peerId, count) in [(accountPeerId, Int32(2)), (annaId, Int32(1)), (mariaId, Int32(1))] {
        demoSetCachedUserData(transaction: transaction, peerId: peerId, starGiftsCount: count)
    }

    // MARK: Star gifts

    // The catalogue has to exist before the chats: seeded gift messages reference its pictures.
    let starGifts = demoSeedStarGifts(transaction: transaction, mediaBox: mediaBox)

    func giftAction(_ giftId: Int64, incoming: Bool, senderId: PeerId, text: String?, savedToProfile: Bool) -> TelegramMediaActionType? {
        guard let gift = starGifts.first(where: { $0.id == giftId }) else {
            return nil
        }
        return demoStarGiftAction(gift: gift, incoming: incoming, senderId: senderId, text: text, savedToProfile: savedToProfile)
    }

    // MARK: Chats

    struct DemoMessage {
        let id: Int32
        let incoming: Bool
        let authorId: PeerId
        let text: String
        /// A service action (a gift, a premium gift) carried by the message instead of text.
        var action: TelegramMediaActionType? = nil
    }

    struct DemoChat {
        let peerId: PeerId
        let messages: [DemoMessage]
        /// Messages with a higher incoming id are unread.
        let incomingReadId: Int32
        /// The last outgoing message is marked read when set.
        let outgoingReadId: Int32?
        let pinned: Bool
    }

    let chats: [DemoChat] = [
        DemoChat(
            peerId: annaId,
            messages: [
                DemoMessage(id: 1, incoming: true, authorId: annaId, text: "Привет! Ты уже смотрел новый дизайн?"),
                DemoMessage(id: 2, incoming: false, authorId: accountPeerId, text: "Да, только посмотрел. Очень круто вышло"),
                DemoMessage(id: 3, incoming: true, authorId: annaId, text: "Мне нужно твоё мнение по шапке 🙌"),
                DemoMessage(id: 4, incoming: false, authorId: accountPeerId, text: "Сейчас гляну и напишу"),
                DemoMessage(id: 5, incoming: true, authorId: annaId, text: "Отлично, жду!"),
                DemoMessage(id: 6, incoming: false, authorId: accountPeerId, text: "Готово, отправил в общий чат"),
                DemoMessage(id: 7, incoming: true, authorId: annaId, text: "Супер, спасибо ❤️"),
                DemoMessage(id: 8, incoming: true, authorId: annaId, text: "И ещё одно: можешь проверить экран подарков?"),
                DemoMessage(id: 9, incoming: true, authorId: annaId, text: "", action: giftAction(900002, incoming: true, senderId: annaId, text: "С праздником! 🎁", savedToProfile: true)),
                DemoMessage(id: 10, incoming: false, authorId: accountPeerId, text: "", action: giftAction(900003, incoming: false, senderId: accountPeerId, text: "Спасибо за помощь с макетом 💙", savedToProfile: false)),
                DemoMessage(id: 11, incoming: true, authorId: annaId, text: "", action: .giftPremium(currency: "USD", amount: 1299, days: 90, cryptoCurrency: nil, cryptoAmount: nil, text: "Premium для тебя 😊", entities: nil)),
            ],
            incomingReadId: 4,
            outgoingReadId: 6,
            pinned: true
        ),
        DemoChat(
            peerId: designTeamId,
            messages: [
                DemoMessage(id: 1, incoming: true, authorId: ilyaId, text: "Всем привет! Готовы к демо?"),
                DemoMessage(id: 2, incoming: true, authorId: mariaId, text: "Да, экраны уже собраны"),
                DemoMessage(id: 3, incoming: false, authorId: accountPeerId, text: "Отлично, в 15:00 созваниваемся"),
                DemoMessage(id: 4, incoming: true, authorId: ilyaId, text: "Я подключусь первым"),
                DemoMessage(id: 5, incoming: true, authorId: mariaId, text: "Добавила новые макеты в фигму"),
                DemoMessage(id: 6, incoming: true, authorId: ilyaId, text: "Посмотрите, пожалуйста 🙏"),
            ],
            incomingReadId: 4,
            outgoingReadId: 3,
            pinned: true
        ),
        DemoChat(
            peerId: momId,
            messages: [
                DemoMessage(id: 1, incoming: true, authorId: momId, text: "Сынок, ты поел?"),
                DemoMessage(id: 2, incoming: false, authorId: accountPeerId, text: "Да, мам ❤️"),
                DemoMessage(id: 3, incoming: true, authorId: momId, text: "Позвони вечером"),
                DemoMessage(id: 4, incoming: true, authorId: momId, text: "Целую тебя"),
            ],
            incomingReadId: 4,
            outgoingReadId: 2,
            pinned: false
        ),
        DemoChat(
            peerId: mariaId,
            messages: [
                DemoMessage(id: 1, incoming: true, authorId: mariaId, text: "", action: giftAction(900004, incoming: true, senderId: mariaId, text: "С днём рождения! 🎂", savedToProfile: true)),
                DemoMessage(id: 2, incoming: false, authorId: accountPeerId, text: "", action: giftAction(900005, incoming: false, senderId: accountPeerId, text: "Спасибо большое! 🎈", savedToProfile: false)),
            ],
            incomingReadId: 1,
            outgoingReadId: 2,
            pinned: false
        ),
        DemoChat(
            peerId: newsId,
            messages: [
                DemoMessage(id: 1, incoming: true, authorId: newsId, text: "Вышла новая версия приложения"),
                DemoMessage(id: 2, incoming: true, authorId: newsId, text: "Теперь папки можно переименовывать прямо в списке"),
                DemoMessage(id: 3, incoming: true, authorId: newsId, text: "Подарки теперь можно дарить группам 🎁"),
                DemoMessage(id: 4, incoming: true, authorId: newsId, text: "Ускорили загрузку медиа на медленных сетях"),
                DemoMessage(id: 5, incoming: true, authorId: newsId, text: "Следующее обновление — через две недели"),
            ],
            incomingReadId: 4,
            outgoingReadId: nil,
            pinned: false
        ),
        DemoChat(
            peerId: cryptoChatId,
            messages: [
                DemoMessage(id: 1, incoming: true, authorId: dmitryId, text: "Кто смотрел график сегодня?"),
                DemoMessage(id: 2, incoming: false, authorId: accountPeerId, text: "Смотрел, выглядит оптимистично"),
                DemoMessage(id: 3, incoming: true, authorId: dmitryId, text: "Держим, паники нет"),
                DemoMessage(id: 4, incoming: true, authorId: mariaId, text: "Поддержу 👍"),
            ],
            incomingReadId: 4,
            outgoingReadId: 2,
            pinned: false
        ),
        DemoChat(
            peerId: ilyaId,
            messages: [
                DemoMessage(id: 1, incoming: true, authorId: ilyaId, text: "Скинул макеты, глянь когда будет время"),
                DemoMessage(id: 2, incoming: false, authorId: accountPeerId, text: "Принял"),
                DemoMessage(id: 3, incoming: true, authorId: ilyaId, text: "Спасибо!"),
            ],
            incomingReadId: 3,
            outgoingReadId: 2,
            pinned: false
        ),
        DemoChat(
            peerId: cinemaId,
            messages: [
                DemoMessage(id: 1, incoming: true, authorId: cinemaId, text: "В пятницу показываем классику 90-х"),
                DemoMessage(id: 2, incoming: true, authorId: cinemaId, text: "Начало в 19:30, вход свободный"),
                DemoMessage(id: 3, incoming: true, authorId: cinemaId, text: "Регистрация по ссылке в закрепе"),
            ],
            incomingReadId: 3,
            outgoingReadId: nil,
            pinned: false
        ),
    ]

    var pinnedItemIds: [PinnedItemId] = []

    for (chatIndex, chat) in chats.enumerated() {
        // Messages are one minute apart inside a chat, and chats are offset from each other so
        // the list sorts into a natural order.
        let base = now - Int32(chats.count - chatIndex) * 600

        transaction.updatePeerChatListInclusion(chat.peerId, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))

        var storeMessages: [StoreMessage] = []
        var timestamps: [MessageId.Id: Int32] = [:]
        for (messageIndex, message) in chat.messages.enumerated() {
            let timestamp = base + Int32(messageIndex) * 60
            timestamps[message.id] = timestamp
            let media: [Media] = message.action.map { [TelegramMediaAction(action: $0)] } ?? []
            // Real gift bubbles are service messages, so they carry the same tags a server would
            // give them instead of being bare history entries.
            let (tags, globalTags) = tagsForStoreMessage(incoming: message.incoming, attributes: [], media: media, textEntities: nil, isPinned: false)
            storeMessages.append(StoreMessage(
                id: MessageId(peerId: chat.peerId, namespace: Namespaces.Message.Cloud, id: message.id),
                customStableId: nil,
                globallyUniqueId: nil,
                groupingKey: nil,
                threadId: nil,
                timestamp: timestamp,
                flags: message.incoming ? [.Incoming] : [],
                tags: tags,
                globalTags: globalTags,
                localTags: [],
                forwardInfo: nil,
                authorId: message.authorId,
                text: message.text,
                attributes: [],
                media: media
            ))
        }
        let _ = transaction.addMessages(storeMessages, location: .Random)

        // The dialog must not wait for the server to fill history that is already here.
        transaction.removeHole(peerId: chat.peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere, range: 1 ...(Int32.max - 1))

        transaction.applyIncomingReadMaxId(MessageId(peerId: chat.peerId, namespace: Namespaces.Message.Cloud, id: chat.incomingReadId))
        if let outgoingReadId = chat.outgoingReadId, let timestamp = timestamps[outgoingReadId] {
            let _ = transaction.applyOutgoingReadMaxIndex(MessageIndex(
                id: MessageId(peerId: chat.peerId, namespace: Namespaces.Message.Cloud, id: outgoingReadId),
                timestamp: timestamp
            ))
        }

        if chat.pinned {
            pinnedItemIds.append(.peer(chat.peerId))
        }
    }

    transaction.setPinnedItemIds(groupId: .root, itemIds: pinnedItemIds)
}

// MARK: - Star gifts catalogue

private struct DemoGiftSpec {
    let id: Int64
    let emoji: String
    let title: String
    let price: Int64
    let availability: StarGift.Gift.Availability?
    let upgradeStars: Int64?
    let perUserLimit: StarGift.Gift.PerUserLimit?
    let flags: StarGift.Gift.Flags
}

/// Writes the fake star gifts catalogue into the postbox and returns it, so the chat seeding
/// that follows can reference the gifts it puts into messages.
///
/// The gift pictures are stored in the media box under their own resource ids: the catalogue is
/// only a `PreferencesEntry`, while the images a screen draws always come from the media box.
private func demoSeedStarGifts(transaction: Transaction, mediaBox: MediaBox) -> [StarGift.Gift] {
    let specs: [DemoGiftSpec] = [
        DemoGiftSpec(id: 900001, emoji: "🎁", title: "Подарок", price: 15, availability: nil, upgradeStars: nil, perUserLimit: nil, flags: []),
        DemoGiftSpec(id: 900002, emoji: "🧸", title: "Мишка", price: 25, availability: nil, upgradeStars: nil, perUserLimit: nil, flags: []),
        DemoGiftSpec(id: 900003, emoji: "💍", title: "Кольцо", price: 50, availability: StarGift.Gift.Availability(remains: 43, total: 100, resale: 0, minResaleStars: nil), upgradeStars: 250, perUserLimit: StarGift.Gift.PerUserLimit(total: 1, remains: 1), flags: []),
        DemoGiftSpec(id: 900004, emoji: "🎂", title: "Торт", price: 100, availability: StarGift.Gift.Availability(remains: 7, total: 50, resale: 0, minResaleStars: nil), upgradeStars: 500, perUserLimit: StarGift.Gift.PerUserLimit(total: 1, remains: 1), flags: [.isBirthdayGift]),
        DemoGiftSpec(id: 900005, emoji: "🎈", title: "Шарик", price: 150, availability: nil, upgradeStars: nil, perUserLimit: nil, flags: []),
        DemoGiftSpec(id: 900006, emoji: "🐈", title: "Котёнок", price: 250, availability: nil, upgradeStars: nil, perUserLimit: nil, flags: []),
    ]

    var items: [StarGift] = []
    var gifts: [StarGift.Gift] = []
    for (index, spec) in specs.enumerated() {
        // Two resources per gift: the animation the gift screens draw, and a still picture for
        // the places that render a file as an image rather than as an animation.
        let animationResource = LocalFileMediaResource(fileId: spec.id)
        let previewResource = LocalFileMediaResource(fileId: spec.id + 5_000_000)

        let previewData = demoGiftImageData(emoji: spec.emoji)
        if !previewData.isEmpty {
            mediaBox.storeResourceData(previewResource.id, data: previewData, synchronous: true)
        }

        let animationData = demoGiftAnimationData(index: index)
        if let animationData {
            mediaBox.storeResourceData(animationResource.id, data: animationData, synchronous: true)
        }

        let thumbnailData: Data? = previewData.isEmpty ? nil : previewData

        let imageRepresentation = TelegramMediaImageRepresentation(
            dimensions: PixelDimensions(width: 512, height: 512),
            resource: previewResource,
            progressiveSizes: [],
            immediateThumbnailData: nil
        )
        // `fileName` and this exact mime type are what make `TelegramMediaFile.isAnimatedSticker`
        // true, and that is the switch every gift screen flips on to draw the file as an
        // animation instead of decoding it as an image.
        let file = TelegramMediaFile(
            fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: spec.id),
            partialReference: nil,
            resource: animationResource,
            previewRepresentations: [imageRepresentation],
            videoThumbnails: [],
            immediateThumbnailData: thumbnailData,
            mimeType: "application/x-tgsticker",
            size: animationData.map { Int64($0.count) },
            attributes: [.FileName(fileName: "gift.tgs")],
            alternativeRepresentations: []
        )
        transaction.storeMediaIfNotPresent(media: file)

        let gift = StarGift.Gift(
            id: spec.id,
            title: spec.title,
            file: file,
            price: spec.price,
            convertStars: spec.price * 5,
            availability: spec.availability,
            soldOut: nil,
            flags: spec.flags,
            upgradeStars: spec.upgradeStars,
            releasedBy: nil,
            perUserLimit: spec.perUserLimit,
            lockedUntilDate: nil,
            auctionSlug: nil,
            auctionGiftsPerRound: nil,
            auctionStartDate: nil,
            upgradeVariantsCount: nil,
            background: nil
        )
        gifts.append(gift)
        items.append(.generic(gift))
    }

    transaction.setPreferencesEntry(key: PreferencesKeys.starGifts(), value: PreferencesEntry(StarGiftsList(items: items, hashValue: 1)))

    // MARK: Premium gift options

    // The chat's "gift" button reads the premium options from this cache and does not open the
    // gifts screen while it is empty (`filter { !$0.isEmpty }`), so the demo fills it locally
    // instead of asking a server.
    //
    // Both currencies are needed: the USD options are what the store path prices the gift with,
    // and the matching `XTR` options are the "pay with Stars" ones, which demo mode uses because
    // there is no store to buy from.
    var premiumOptions: [PremiumGiftCodeOption] = []
    let storeOptions: [(Int32, String, Int64)] = [
        (1, "org.telegram.premium.month1", 499),
        (3, "org.telegram.premium.month3", 1299),
        (6, "org.telegram.premium.month6", 2299),
        (12, "org.telegram.premium.month12", 3899),
    ]
    for (months, productId, amount) in storeOptions {
        premiumOptions.append(PremiumGiftCodeOption(users: 1, months: months, storeProductId: productId, storeQuantity: 1, currency: "USD", amount: amount))
    }
    premiumOptions.append(PremiumGiftCodeOption(users: 1, months: 1, storeProductId: nil, storeQuantity: 1, currency: "XTR", amount: 500))
    premiumOptions.append(PremiumGiftCodeOption(users: 1, months: 3, storeProductId: nil, storeQuantity: 1, currency: "XTR", amount: 1500))
    premiumOptions.append(PremiumGiftCodeOption(users: 1, months: 6, storeProductId: nil, storeQuantity: 1, currency: "XTR", amount: 2500))
    premiumOptions.append(PremiumGiftCodeOption(users: 1, months: 12, storeProductId: nil, storeQuantity: 1, currency: "XTR", amount: 5000))
    if let entry = CodableEntry(CachedPremiumGiftCodeOptions(options: premiumOptions)) {
        transaction.putItemCacheEntry(
            id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedPremiumGiftCodeOptions, key: ValueBoxKey(length: 0)),
            entry: entry
        )
    }

    return gifts
}

// MARK: - Cached user data

/// Puts a `CachedUserData` in place for a seeded peer.
///
/// The profile screens read the user's cached data for things a server would normally have sent,
/// most importantly `starGiftsCount`, which is the only thing gating the Gifts tab. Every other
/// field is left at its neutral value: the demo's peers are ordinary users with nothing special
/// about them.
private func demoSetCachedUserData(transaction: Transaction, peerId: PeerId, starGiftsCount: Int32) {
    let cached = CachedUserData(
        about: nil,
        botInfo: nil,
        editableBotInfo: nil,
        peerStatusSettings: nil,
        pinnedMessageId: nil,
        isBlocked: false,
        commonGroupCount: 0,
        voiceCallsAvailable: true,
        videoCallsAvailable: true,
        callsPrivate: false,
        canPinMessages: false,
        hasScheduledMessages: false,
        autoremoveTimeout: .unknown,
        chatTheme: nil,
        photo: .unknown,
        personalPhoto: .unknown,
        fallbackPhoto: .unknown,
        voiceMessagesAvailable: true,
        wallpaper: nil,
        flags: [],
        businessHours: nil,
        businessLocation: nil,
        greetingMessage: nil,
        awayMessage: nil,
        connectedBot: nil,
        businessIntro: .unknown,
        birthday: nil,
        personalChannel: .unknown,
        botPreview: nil,
        starGiftsCount: starGiftsCount,
        starRefProgram: nil,
        verification: nil,
        sendPaidMessageStars: nil,
        disallowedGifts: nil,
        botGroupAdminRights: nil,
        botChannelAdminRights: nil,
        starRating: nil,
        pendingStarRating: nil,
        mainProfileTab: nil,
        savedMusic: nil,
        note: nil,
        myCopyProtectionEnableDate: nil,
        botManagerId: nil
    )
    transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in cached })
}

// MARK: - Gift messages

/// The service message a gift is carried in.
///
/// `senderId` names the sender so the bubble can title it the way Telegram does ("Анна подарила
/// подарок"); `recipientId` is only needed outside a private chat, where the bubble otherwise
/// falls back to the message's own peer.
///
/// `peerId` is deliberately left nil: setting it tells the bubble this is a channel gift and it
/// renders as one.
public func demoStarGiftAction(
    gift: StarGift.Gift,
    incoming: Bool,
    senderId: PeerId,
    recipientId: PeerId? = nil,
    text: String?,
    entities: [MessageTextEntity]? = nil,
    savedToProfile: Bool
) -> TelegramMediaActionType {
    return .starGift(
        gift: .generic(gift),
        convertStars: gift.convertStars,
        text: text,
        entities: text == nil ? nil : (entities ?? []),
        nameHidden: false,
        savedToProfile: savedToProfile,
        converted: false,
        upgraded: false,
        canUpgrade: gift.upgradeStars != nil,
        upgradeStars: gift.upgradeStars,
        isRefunded: false,
        isPrepaidUpgrade: false,
        upgradeMessageId: nil,
        peerId: nil,
        senderId: incoming ? senderId : nil,
        savedId: nil,
        prepaidUpgradeHash: nil,
        giftMessageId: nil,
        upgradeSeparate: false,
        isAuctionAcquired: false,
        toPeerId: incoming ? nil : recipientId,
        number: nil
    )
}

/// The service message a Premium gift is carried in. `days` is what the bubble reads to say
/// "3 месяца Premium".
public func demoPremiumGiftAction(currency: String, amount: Int64, days: Int32, text: String?, entities: [MessageTextEntity]? = nil) -> TelegramMediaActionType {
    return .giftPremium(currency: currency, amount: amount, days: days, cryptoCurrency: nil, cryptoAmount: nil, text: text, entities: text == nil ? nil : (entities ?? []))
}

// MARK: - Profile gifts

/// The gifts a profile's Gifts tab shows, derived offline from the seeded chat histories.
///
/// A real client asks `payments.getSavedStarGifts`, which demo mode has no server for. The
/// underlying truth is the same though: on your own profile you see the gifts you were given, and
/// on someone else's you see the gifts you gave them. Both are just gift service messages in the
/// postbox, so they are read back here.
public func demoProfileGifts(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, sorting: ProfileGiftsContext.Sorting, filter: ProfileGiftsContext.Filters) -> [ProfileGiftsContext.State.StarGift] {
    guard DemoMode.isEnabled else {
        return []
    }

    let isOwnProfile = peerId == accountPeerId

    // Gifts deleted from the profile are gone from the tab but still in the chat history, so the
    // tab skips them here rather than the postbox losing them.
    let deletedMessageIds = DemoMode.deletedStarGiftMessageIds

    // Own profile: every gift sent to you, in any private chat. Another profile: the gifts you
    // sent to that specific peer.
    let chatPeerIds: [PeerId]
    if isOwnProfile {
        chatPeerIds = transaction.chatListGetAllPeerIds()
    } else {
        chatPeerIds = [peerId]
    }

    var gifts: [ProfileGiftsContext.State.StarGift] = []
    for chatPeerId in chatPeerIds {
        guard let peer = transaction.getPeer(chatPeerId), peer is TelegramUser else {
            continue
        }

        // Newest first: `getMessages` walks down from `from` to `to`.
        let messages = transaction.getMessages(
            peerId: chatPeerId,
            namespace: Namespaces.Message.Cloud,
            from: MessageIndex(id: MessageId(peerId: chatPeerId, namespace: Namespaces.Message.Cloud, id: Int32.max), timestamp: Int32.max),
            includeFrom: false,
            to: MessageIndex(id: MessageId(peerId: chatPeerId, namespace: Namespaces.Message.Cloud, id: 1), timestamp: 0),
            limit: 500
        )

        for message in messages {
            guard message.author?.id == (isOwnProfile ? chatPeerId : accountPeerId) else {
                continue
            }
            guard let action = message.media.compactMap({ $0 as? TelegramMediaAction }).first else {
                continue
            }
            if deletedMessageIds.contains(message.id.id) {
                continue
            }

            let fromPeer: EnginePeer?
            if isOwnProfile {
                fromPeer = transaction.getPeer(chatPeerId).flatMap(EnginePeer.init)
            } else {
                fromPeer = transaction.getPeer(accountPeerId).flatMap(EnginePeer.init)
            }

            // Both kinds of gift message belong here: the seeded ones, and the `.starGiftUnique`
            // ones this build writes when a gift is upgraded — otherwise an upgraded gift would
            // fall out of the tab the moment it stops being a `.starGift`.
            let stateGift: ProfileGiftsContext.State.StarGift
            switch action.action {
            case let .starGift(gift, convertStars, text, entities, nameHidden, savedToProfile, converted, _, canUpgrade, upgradeStars, isRefunded, _, _, _, _, _, _, _, _, _, _, number):
                guard case .generic = gift else {
                    continue
                }
                // A converted gift was paid out and left the profile; the message stays in the
                // chat, but the tab must not list it again.
                if converted {
                    continue
                }
                stateGift = ProfileGiftsContext.State.StarGift(
                    gift: gift,
                    reference: .message(messageId: message.id),
                    fromPeer: fromPeer,
                    date: message.timestamp,
                    text: text,
                    entities: entities,
                    nameHidden: nameHidden,
                    savedToProfile: savedToProfile,
                    pinnedToTop: false,
                    convertStars: convertStars,
                    canUpgrade: canUpgrade,
                    canExportDate: nil,
                    upgradeStars: upgradeStars,
                    transferStars: nil,
                    canTransferDate: nil,
                    canResaleDate: nil,
                    collectionIds: nil,
                    prepaidUpgradeHash: nil,
                    upgradeSeparate: false,
                    dropOriginalDetailsStars: nil,
                    number: number,
                    isRefunded: isRefunded,
                    canCraftAt: nil
                )
            case let .starGiftUnique(gift, _, _, savedToProfile, canExportDate, transferStars, isRefunded, _, _, _, _, _, canTransferDate, canResaleDate, dropOriginalDetailsStars, _, _, canCraftAt, _, text, entities, nameHidden):
                guard case let .unique(uniqueGift) = gift else {
                    continue
                }
                stateGift = ProfileGiftsContext.State.StarGift(
                    gift: gift,
                    reference: .message(messageId: message.id),
                    fromPeer: fromPeer,
                    date: message.timestamp,
                    text: text,
                    entities: entities,
                    nameHidden: nameHidden,
                    savedToProfile: savedToProfile,
                    pinnedToTop: false,
                    convertStars: nil,
                    canUpgrade: false,
                    canExportDate: canExportDate,
                    upgradeStars: nil,
                    transferStars: transferStars,
                    canTransferDate: canTransferDate,
                    canResaleDate: canResaleDate,
                    collectionIds: nil,
                    prepaidUpgradeHash: nil,
                    upgradeSeparate: false,
                    dropOriginalDetailsStars: dropOriginalDetailsStars,
                    number: uniqueGift.number,
                    isRefunded: isRefunded,
                    canCraftAt: canCraftAt
                )
            default:
                continue
            }

            gifts.append(stateGift)
        }
    }

    let showsDisplayed = filter.contains(.displayed)
    let showsHidden = filter.contains(.hidden)

    // The filter is the set of categories the tab is asked to show, exactly the flags the real
    // request encodes: `.unlimited`/`.limitedUpgradable`/`.limitedNonUpgradable` pick the generic
    // gifts, `.unique` the NFT ones, and `.displayed`/`.hidden` pick by whether the recipient put
    // the gift on their profile.
    gifts = gifts.filter { gift in
        switch gift.gift {
            case .unique:
                return filter.contains(.unique)
            case let .generic(generic):
                if generic.availability == nil {
                    guard filter.contains(.unlimited) else {
                        return false
                    }
                } else if generic.upgradeStars != nil {
                    guard filter.contains(.limitedUpgradable) else {
                        return false
                    }
                } else {
                    guard filter.contains(.limitedNonUpgradable) else {
                        return false
                    }
                }
                return gift.savedToProfile ? showsDisplayed : showsHidden
        }
    }

    func price(of gift: ProfileGiftsContext.State.StarGift) -> Int64 {
        switch gift.gift {
            case let .generic(generic):
                return generic.price
            case let .unique(unique):
                return unique.valueAmount ?? 0
        }
    }

    switch sorting {
        case .date:
            gifts.sort { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date > rhs.date
                }
                return price(of: lhs) > price(of: rhs)
            }
        case .value:
            gifts.sort { lhs, rhs in
                if price(of: lhs) != price(of: rhs) {
                    return price(of: lhs) > price(of: rhs)
                }
                return lhs.date > rhs.date
            }
    }

    return gifts
}

// MARK: - Upgrading

/// The model, pattern and backdrop attributes a unique gift is made of, read from the seeded
/// catalogue.
///
/// Two real requests are answered by this: `payments.getStarGiftUpgradePreview`, whose sample
/// attributes the gift screen animates before the upgrade, and `payments.getStarGiftUpgrade
/// Attributes`, whose attributes the variants screen offers. Both need more than three entries —
/// that is the count at which the preview starts cycling through them — so three of each are
/// returned, starting with the gift being upgraded. Every file is one the seed wrote into the
/// local media box, so nothing is fetched from anywhere.
public func demoStarGiftUpgradeAttributes(transaction: Transaction, giftId: Int64) -> [StarGift.UniqueGift.Attribute] {
    guard DemoMode.isEnabled else {
        return []
    }
    guard let entry = transaction.getPreferencesEntry(key: PreferencesKeys.starGifts()), let list = entry.get(StarGiftsList.self) else {
        return []
    }

    var gifts: [StarGift.Gift] = []
    for item in list.items {
        if case let .generic(gift) = item {
            gifts.append(gift)
        }
    }
    guard !gifts.isEmpty else {
        return []
    }

    let count = gifts.count
    let start = gifts.firstIndex(where: { $0.id == giftId }) ?? 0

    var files: [TelegramMediaFile] = []
    var names: [String] = []
    for offset in 0 ..< min(3, count) {
        let gift = gifts[(start + offset) % count]
        files.append(gift.file)
        names.append(gift.title ?? "")
    }
    while files.count < 3 {
        files.append(gifts[0].file)
        names.append(gifts[0].title ?? "")
    }

    let modelRarities: [StarGift.UniqueGift.Attribute.Rarity] = [.legendary, .epic, .rare]
    let patternRarities: [StarGift.UniqueGift.Attribute.Rarity] = [.epic, .rare, .uncommon]
    let backdropRarities: [StarGift.UniqueGift.Attribute.Rarity] = [.uncommon, .rare, .epic]
    let backdrops: [(id: Int32, inner: Int32, outer: Int32, pattern: Int32, text: Int32)] = [
        (1, 0x9fe7ff, 0x3fb6e8, 0xffffff, 0x0b5a75),
        (2, 0xffd2e4, 0xff6b9d, 0xffffff, 0x8a1b4a),
        (3, 0xdacbff, 0x8e6bff, 0xffffff, 0x3a1e8a),
    ]

    var attributes: [StarGift.UniqueGift.Attribute] = []
    for index in 0 ..< 3 {
        attributes.append(.model(name: names[index], file: files[index], rarity: modelRarities[index], crafted: false))
    }
    for index in 0 ..< 3 {
        attributes.append(.pattern(name: names[index], file: files[index], rarity: patternRarities[index]))
    }
    for index in 0 ..< 3 {
        let backdrop = backdrops[index]
        attributes.append(.backdrop(name: names[index], id: backdrop.id, innerColor: backdrop.inner, outerColor: backdrop.outer, patternColor: backdrop.pattern, textColor: backdrop.text, rarity: backdropRarities[index]))
    }
    return attributes
}

/// The price of upgrading a gift, taken from the same catalogue: what the upgrade button quotes
/// and what leaves the balance.
public func demoStarGiftUpgradePrice(transaction: Transaction, giftId: Int64) -> Int64? {
    guard DemoMode.isEnabled else {
        return nil
    }
    guard let entry = transaction.getPreferencesEntry(key: PreferencesKeys.starGifts()), let list = entry.get(StarGiftsList.self) else {
        return nil
    }
    for item in list.items {
        if case let .generic(gift) = item, gift.id == giftId {
            return gift.upgradeStars
        }
    }
    return nil
}

/// The upgrade preview: the attributes to animate plus the price.
///
/// The price list holds a single, already-effective entry and `nextPrices` is empty, so the
/// timer that walks a rising price never starts — there is no rise to walk, and the button
/// falls back to the gift's own `upgradeStars`.
public func demoStarGiftUpgradePreview(transaction: Transaction, giftId: Int64) -> StarGiftUpgradePreview? {
    guard DemoMode.isEnabled else {
        return nil
    }
    let attributes = demoStarGiftUpgradeAttributes(transaction: transaction, giftId: giftId)
    guard !attributes.isEmpty else {
        return nil
    }
    // The price only feeds a countdown that is not running here, so a gift without a listed
    // upgrade price still gets a preview — returning nil would leave the gift screen's spinner
    // waiting for a preview that can never arrive.
    let price = demoStarGiftUpgradePrice(transaction: transaction, giftId: giftId) ?? 0
    let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
    return StarGiftUpgradePreview(
        attributes: attributes,
        prices: [StarGiftUpgradePreview.Price(stars: price, date: now)],
        nextPrices: []
    )
}

/// The whole of what `payments.upgradeStarGift` does that is visible offline: mint the
/// collectible from the gift's catalogue entry, rewrite the seeded gift message as a
/// `.starGiftUnique` one, and take the price out of the balance.
///
/// The value returned is the same object the gift screen reveals, so the upgrade animation draws
/// what a real one would, and the postbox rewrite is what keeps the chat bubble and the profile's
/// Gifts tab showing an upgraded gift afterwards.
public func demoUpgradeStarGift(account: Account, reference: StarGiftReference, keepOriginalInfo: Bool) -> Signal<ProfileGiftsContext.State.StarGift, UpgradeStarGiftError> {
    return account.postbox.transaction { transaction -> (ProfileGiftsContext.State.StarGift?, UpgradeStarGiftError?) in
        guard DemoMode.isEnabled else {
            return (nil, .generic)
        }
        guard case let .message(messageId) = reference, let message = transaction.getMessage(messageId) else {
            return (nil, .generic)
        }
        guard let action = message.media.compactMap({ $0 as? TelegramMediaAction }).first else {
            return (nil, .generic)
        }

        let genericGift: StarGift.Gift
        let giftText: String?
        let giftEntities: [MessageTextEntity]?
        let giftNameHidden: Bool
        let giftSavedToProfile: Bool
        let giftSenderId: EnginePeer.Id?
        let giftIsRefunded: Bool
        switch action.action {
        case let .starGift(gift, _, text, entities, nameHidden, savedToProfile, _, _, _, _, isRefunded, _, _, _, senderId, _, _, _, _, _, _, _):
            guard case let .generic(value) = gift else {
                return (nil, .alreadyUpgraded)
            }
            genericGift = value
            giftText = text
            giftEntities = entities
            giftNameHidden = nameHidden
            giftSavedToProfile = savedToProfile
            giftSenderId = senderId
            giftIsRefunded = isRefunded
        case .starGiftUnique:
            return (nil, .alreadyUpgraded)
        default:
            return (nil, .generic)
        }

        guard let upgradeStars = genericGift.upgradeStars, upgradeStars > 0 else {
            return (nil, .generic)
        }
        guard DemoMode.starsBalance >= upgradeStars else {
            return (nil, .generic)
        }
        let attributes = demoStarGiftUpgradeAttributes(transaction: transaction, giftId: genericGift.id)
        guard !attributes.isEmpty else {
            return (nil, .generic)
        }

        let number = Int32(1 + (abs(Int(genericGift.id)) % 10000))
        // What the gift is worth in money, at Telegram's retail star price (a star is sold for
        // about $0.013): the gift's own price plus what the upgrade cost. This is the figure the
        // "~$" row on the gift screen quotes and the stats screen is built around.
        let valueCents = max(1, (genericGift.price + upgradeStars) * 13 / 10)

        let uniqueGift = StarGift.UniqueGift(
            id: genericGift.id,
            giftId: genericGift.id,
            title: genericGift.title ?? "",
            number: number,
            slug: "star:\(genericGift.id):\(number)",
            owner: .peerId(account.peerId),
            attributes: attributes,
            availability: StarGift.UniqueGift.Availability(issued: 1, total: 100),
            giftAddress: nil,
            resellAmounts: nil,
            resellForTonOnly: false,
            releasedBy: nil,
            valueAmount: valueCents,
            valueCurrency: "USD",
            valueUsdAmount: valueCents,
            flags: [],
            themePeerId: nil,
            peerColor: nil,
            hostPeerId: nil,
            minOfferStars: nil,
            craftChancePermille: nil
        )

        DemoMode.spendStars(upgradeStars)

        let upgradedAction = TelegramMediaAction(action: .starGiftUnique(
            gift: .unique(uniqueGift),
            isUpgrade: true,
            isTransferred: false,
            savedToProfile: giftSavedToProfile,
            canExportDate: nil,
            transferStars: nil,
            isRefunded: giftIsRefunded,
            isPrepaidUpgrade: false,
            peerId: nil,
            senderId: giftSenderId,
            savedId: nil,
            resaleAmount: nil,
            canTransferDate: nil,
            canResaleDate: nil,
            dropOriginalDetailsStars: nil,
            assigned: false,
            fromOffer: false,
            canCraftAt: nil,
            isCrafted: false,
            text: giftText,
            entities: giftEntities,
            nameHidden: giftNameHidden
        ))

        var upgradedMedia = message.media
        if let index = upgradedMedia.firstIndex(where: { $0 is TelegramMediaAction }) {
            upgradedMedia[index] = upgradedAction
        } else {
            upgradedMedia.append(upgradedAction)
        }
        demoReplaceMessageMedia(transaction: transaction, messageId: messageId, media: upgradedMedia)

        let stateGift = ProfileGiftsContext.State.StarGift(
            gift: .unique(uniqueGift),
            reference: .message(messageId: messageId),
            fromPeer: message.author.flatMap(EnginePeer.init),
            date: message.timestamp,
            text: giftText,
            entities: giftEntities,
            nameHidden: giftNameHidden,
            savedToProfile: giftSavedToProfile,
            pinnedToTop: false,
            convertStars: nil,
            canUpgrade: false,
            canExportDate: nil,
            upgradeStars: nil,
            transferStars: nil,
            canTransferDate: nil,
            canResaleDate: nil,
            collectionIds: nil,
            prepaidUpgradeHash: nil,
            upgradeSeparate: false,
            dropOriginalDetailsStars: nil,
            number: uniqueGift.number,
            isRefunded: giftIsRefunded,
            canCraftAt: nil
        )
        return (stateGift, nil)
    }
    |> mapToSignalPromotingError { result -> Signal<ProfileGiftsContext.State.StarGift, UpgradeStarGiftError> in
        if let gift = result.0 {
            return .single(gift)
        }
        return .fail(result.1 ?? .generic)
    }
}

/// The payment form the gift screen fetches before an upgrade. There is no payment bot to ask in
/// demo mode, but the form is what carries the price the balance panel quotes, so one is built
/// from the same catalogue the upgrade itself is priced from.
public func demoUpgradePaymentForm(transaction: Transaction, reference: StarGiftReference) -> BotPaymentForm? {
    guard DemoMode.isEnabled, case let .message(messageId) = reference, let message = transaction.getMessage(messageId) else {
        return nil
    }
    guard let action = message.media.compactMap({ $0 as? TelegramMediaAction }).first else {
        return nil
    }
    guard case let .starGift(gift, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = action.action, case let .generic(genericGift) = gift else {
        return nil
    }
    guard let price = demoStarGiftUpgradePrice(transaction: transaction, giftId: genericGift.id) else {
        return nil
    }
    return BotPaymentForm(
        id: genericGift.id,
        canSaveCredentials: false,
        passwordMissing: false,
        invoice: BotPaymentInvoice(
            isTest: true,
            requestedFields: [],
            currency: "XTR",
            prices: [BotPaymentPrice(label: "Upgrade", amount: price)],
            tip: nil,
            termsInfo: nil,
            subscriptionPeriod: nil
        ),
        paymentBotId: nil,
        providerId: nil,
        url: nil,
        nativeProvider: nil,
        savedInfo: nil,
        savedCredentials: [],
        additionalPaymentMethods: []
    )
}

// MARK: - Market value

/// The market statistics behind a collectible's "Learn more" screen.
///
/// The slug the demo mints reads `star:<giftId>:<number>`, which is enough to price the
/// collectible from the seeded catalogue: what the base gift cost, what the upgrade cost, and
/// from that the sale history the screen lists. The gift was sold a month before it was given
/// away, which is why the initial sale predates the gift message in the chat.
public func demoStarGiftValueInfo(transaction: Transaction, slug: String) -> StarGift.UniqueGift.ValueInfo? {
    guard DemoMode.isEnabled else {
        return nil
    }
    let parts = slug.split(separator: ":")
    guard parts.count == 3, parts[0] == "star", let giftId = Int64(parts[1]) else {
        return nil
    }
    guard let entry = transaction.getPreferencesEntry(key: PreferencesKeys.starGifts()), let list = entry.get(StarGiftsList.self) else {
        return nil
    }

    var price: Int64 = 0
    var upgradeStars: Int64 = 0
    for item in list.items {
        if case let .generic(gift) = item, gift.id == giftId {
            price = gift.price
            upgradeStars = gift.upgradeStars ?? 0
            break
        }
    }
    guard price > 0 else {
        return nil
    }

    let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
    let initialSaleDate = now - 30 * 86400
    let initialSalePrice = max(1, price * 13 / 10)
    return StarGift.UniqueGift.ValueInfo(
        isLastSaleOnFragment: false,
        valueIsAverage: false,
        value: max(1, (price + upgradeStars) * 13 / 10),
        currency: "USD",
        initialSaleDate: initialSaleDate,
        initialSaleStars: price,
        initialSalePrice: initialSalePrice,
        lastSaleDate: initialSaleDate,
        lastSalePrice: initialSalePrice,
        floorPrice: initialSalePrice,
        averagePrice: initialSalePrice,
        listedCount: nil,
        fragmentListedCount: nil,
        fragmentListedUrl: nil
    )
}

// MARK: - Profile gift changes

/// The changes a profile's Gifts tab can make to a gift. Each has to survive the tab being
/// rebuilt from the postbox the next time it opens, so each is written back into the gift's own
/// service message — the thing both the tab and the chat bubble read.
public enum DemoStarGiftChange {
    /// Show the gift on the profile (`true`) or hide it again (`false`).
    case savedToProfile(Bool)
    /// Convert the gift into stars: it stops being a profile gift and pays out its value.
    case converted
    /// Take the gift out of the tab. The chat message is left alone — deleting a gift from a
    /// profile does not unsend it — so the id is recorded and the tab skips it instead.
    case deleted
}

public func demoChangeStarGiftMessage(transaction: Transaction, reference: StarGiftReference, change: DemoStarGiftChange) -> Bool {
    guard DemoMode.isEnabled, case let .message(messageId) = reference else {
        return false
    }
    if case .deleted = change {
        DemoMode.markStarGiftDeleted(messageId: messageId.id)
        return true
    }

    guard let message = transaction.getMessage(messageId) else {
        return false
    }
    guard let index = message.media.firstIndex(where: { $0 is TelegramMediaAction }), let action = message.media[index] as? TelegramMediaAction else {
        return false
    }

    let updatedAction: TelegramMediaActionType
    switch action.action {
    case let .starGift(gift, convertStars, text, entities, nameHidden, savedToProfile, converted, upgraded, canUpgrade, upgradeStars, isRefunded, isPrepaidUpgrade, upgradeMessageId, peerId, senderId, savedId, prepaidUpgradeHash, giftMessageId, upgradeSeparate, isAuctionAcquired, toPeerId, number):
        var updatedSavedToProfile = savedToProfile
        var updatedConverted = converted
        switch change {
        case let .savedToProfile(added):
            updatedSavedToProfile = added
        case .converted:
            updatedConverted = true
        case .deleted:
            return false
        }
        updatedAction = .starGift(gift: gift, convertStars: convertStars, text: text, entities: entities, nameHidden: nameHidden, savedToProfile: updatedSavedToProfile, converted: updatedConverted, upgraded: upgraded, canUpgrade: canUpgrade, upgradeStars: upgradeStars, isRefunded: isRefunded, isPrepaidUpgrade: isPrepaidUpgrade, upgradeMessageId: upgradeMessageId, peerId: peerId, senderId: senderId, savedId: savedId, prepaidUpgradeHash: prepaidUpgradeHash, giftMessageId: giftMessageId, upgradeSeparate: upgradeSeparate, isAuctionAcquired: isAuctionAcquired, toPeerId: toPeerId, number: number)
        if case .converted = change, !converted {
            // Converting pays the gift's conversion value out once, not on every later reload.
            DemoMode.addStars(convertStars ?? 0)
        }
    case let .starGiftUnique(gift, isUpgrade, isTransferred, savedToProfile, canExportDate, transferStars, isRefunded, isPrepaidUpgrade, peerId, senderId, savedId, resaleAmount, canTransferDate, canResaleDate, dropOriginalDetailsStars, assigned, fromOffer, canCraftAt, isCrafted, text, entities, nameHidden):
        // A unique gift cannot be converted, and deleting one is handled above.
        guard case let .savedToProfile(added) = change else {
            return false
        }
        updatedAction = .starGiftUnique(gift: gift, isUpgrade: isUpgrade, isTransferred: isTransferred, savedToProfile: added, canExportDate: canExportDate, transferStars: transferStars, isRefunded: isRefunded, isPrepaidUpgrade: isPrepaidUpgrade, peerId: peerId, senderId: senderId, savedId: savedId, resaleAmount: resaleAmount, canTransferDate: canTransferDate, canResaleDate: canResaleDate, dropOriginalDetailsStars: dropOriginalDetailsStars, assigned: assigned, fromOffer: fromOffer, canCraftAt: canCraftAt, isCrafted: isCrafted, text: text, entities: entities, nameHidden: nameHidden)
    default:
        return false
    }

    var media = message.media
    media[index] = TelegramMediaAction(action: updatedAction)
    demoReplaceMessageMedia(transaction: transaction, messageId: messageId, media: media)
    return true
}

/// Writes a message back with a new media list, keeping everything else about it — the forward
/// info, the attributes, the tags — exactly as it was.
private func demoReplaceMessageMedia(transaction: Transaction, messageId: MessageId, media: [Media]) {
    transaction.updateMessage(messageId, update: { currentMessage in
        var storeForwardInfo: StoreMessageForwardInfo?
        if let forwardInfo = currentMessage.forwardInfo {
            storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
        }
        return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: currentMessage.attributes, media: media))
    })
}

/// Lists a gift for resale at `price`, or takes it off the market when `price` is nil.
///
/// Both the asking price on the collectible and the `resaleAmount` the message carries are
/// written back, so the Sell button flips to Unlist, the price row shows what it is listed for,
/// and all of it is still there when the gift screen is opened again.
public func demoChangeStarGiftResalePrice(transaction: Transaction, reference: StarGiftReference, price: CurrencyAmount?) -> Bool {
    guard DemoMode.isEnabled, case let .message(messageId) = reference else {
        return false
    }
    guard let message = transaction.getMessage(messageId) else {
        return false
    }
    guard let index = message.media.firstIndex(where: { $0 is TelegramMediaAction }), let action = message.media[index] as? TelegramMediaAction else {
        return false
    }
    guard case let .starGiftUnique(gift, isUpgrade, isTransferred, savedToProfile, canExportDate, transferStars, isRefunded, isPrepaidUpgrade, peerId, senderId, savedId, _, canTransferDate, canResaleDate, dropOriginalDetailsStars, assigned, fromOffer, canCraftAt, isCrafted, text, entities, nameHidden) = action.action, case let .unique(uniqueGift) = gift else {
        return false
    }
    
    let updatedAction = TelegramMediaAction(action: .starGiftUnique(
        gift: .unique(uniqueGift.withResellAmounts(price.map { [$0] }).withResellForTonOnly(false)),
        isUpgrade: isUpgrade,
        isTransferred: isTransferred,
        savedToProfile: savedToProfile,
        canExportDate: canExportDate,
        transferStars: transferStars,
        isRefunded: isRefunded,
        isPrepaidUpgrade: isPrepaidUpgrade,
        peerId: peerId,
        senderId: senderId,
        savedId: savedId,
        resaleAmount: price,
        canTransferDate: canTransferDate,
        canResaleDate: canResaleDate,
        dropOriginalDetailsStars: dropOriginalDetailsStars,
        assigned: assigned,
        fromOffer: fromOffer,
        canCraftAt: canCraftAt,
        isCrafted: isCrafted,
        text: text,
        entities: entities,
        nameHidden: nameHidden
    ))
    
    var media = message.media
    media[index] = updatedAction
    demoReplaceMessageMedia(transaction: transaction, messageId: messageId, media: media)
    return true
}

// MARK: - Transfer

/// The whole of what `payments.transferStarGift` does that is visible offline: the collectible
/// leaves your profile and turns up in the recipient's, written into the chat with them the same
/// way a real transfer lands — which is exactly where their Gifts tab reads it back from.
///
/// `prepaid` is deliberately ignored: with no payment form to fetch, every transfer in the demo
/// costs nothing, the way a gift between friends does.
public func demoTransferStarGift(account: Account, reference: StarGiftReference, peerId: EnginePeer.Id) -> Signal<Never, TransferStarGiftError> {
    return account.postbox.transaction { transaction -> TelegramMediaActionType? in
        guard DemoMode.isEnabled else {
            return nil
        }
        guard case let .message(messageId) = reference, let message = transaction.getMessage(messageId) else {
            return nil
        }
        guard let index = message.media.firstIndex(where: { $0 is TelegramMediaAction }), let action = message.media[index] as? TelegramMediaAction else {
            return nil
        }
        guard case let .starGiftUnique(gift, isUpgrade, _, _, canExportDate, transferStars, isRefunded, isPrepaidUpgrade, _, senderId, savedId, resaleAmount, canTransferDate, canResaleDate, dropOriginalDetailsStars, assigned, fromOffer, canCraftAt, isCrafted, text, entities, nameHidden) = action.action else {
            return nil
        }

        // Out of your profile: from here the tab skips the message, exactly as it skips a deleted
        // or converted one. The chat history keeps its bubble — a transfer does not unsend it.
        DemoMode.markStarGiftDeleted(messageId: messageId.id)

        // ...and their profile's Gifts tab only opens while `starGiftsCount` says there is
        // something in it, so the count travels with the gift.
        if let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedUserData {
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, _ in
                cached.withUpdatedStarGiftsCount((cached.starGiftsCount ?? 0) + 1)
            })
        } else if transaction.getPeer(peerId) != nil {
            demoSetCachedUserData(transaction: transaction, peerId: peerId, starGiftsCount: 1)
        }

        let transferred: TelegramMediaActionType = .starGiftUnique(
            gift: gift,
            isUpgrade: isUpgrade,
            isTransferred: true,
            savedToProfile: true,
            canExportDate: canExportDate,
            transferStars: transferStars,
            isRefunded: isRefunded,
            isPrepaidUpgrade: isPrepaidUpgrade,
            peerId: nil,
            senderId: senderId,
            savedId: savedId,
            resaleAmount: resaleAmount,
            canTransferDate: canTransferDate,
            canResaleDate: canResaleDate,
            dropOriginalDetailsStars: dropOriginalDetailsStars,
            assigned: assigned,
            fromOffer: fromOffer,
            canCraftAt: canCraftAt,
            isCrafted: isCrafted,
            text: text,
            entities: entities,
            nameHidden: nameHidden
        )
        return transferred
    }
    |> castError(TransferStarGiftError.self)
    |> mapToSignal { transferredAction -> Signal<Never, TransferStarGiftError> in
        guard let transferredAction else {
            // Nothing to move. Completing is right either way: the profile context has already
            // taken the gift out of its list, and leaving the signal pending would strand it.
            return .complete()
        }
        return demoEnqueueGift(account: account, peerId: peerId, action: transferredAction)
        |> ignoreValues
        |> castError(TransferStarGiftError.self)
    }
}

// MARK: - Sending

/// Demo mode has no server to hand out message ids, so an outgoing message is written straight
/// into the cloud history as delivered: the attributes, tags and read state a sent message gets,
/// with no pending queue and nothing that can fail or show as "sending".
public func demoEnqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {
    return account.postbox.transaction { transaction -> [MessageId?] in
        guard let peer = transaction.getPeer(peerId) else {
            return messages.map { _ in nil }
        }

        var timestamp = Int32(Date().timeIntervalSince1970)
        var nextId: Int32 = 1
        if let topIndex = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud) {
            timestamp = max(timestamp, topIndex.timestamp)
            nextId = topIndex.id.id + 1
        }

        var storeMessages: [StoreMessage] = []
        var storedTimestamps: [MessageId.Id: Int32] = [:]
        var uniqueIds: [Int64] = []
        var resultIndices: [Int] = []
        var resultIds = Array<MessageId?>(repeating: nil, count: messages.count)

        for (messageIndex, message) in messages.enumerated() {
            var text = ""
            var mediaList: [Media] = []
            var attributes: [MessageAttribute] = []
            var forwardInfo: StoreMessageForwardInfo?
            var threadId: Int64?
            var groupingKey: Int64?
            var mediaReference: AnyMediaReference?
            var inlineStickers: [MediaId: Media] = [:]
            var correlationId: Int64?
            var bubbleUpEmojiOrStickersets: [ItemCollectionId] = []

            switch message {
                case let .message(messageText, requestedAttributes, stickers, reference, messageThreadId, replyToMessageId, replyToStoryId, messageGroupingKey, messageCorrelationId, messageBubbleUp):
                    text = messageText
                    inlineStickers = stickers
                    mediaReference = reference
                    threadId = messageThreadId
                    groupingKey = messageGroupingKey
                    correlationId = messageCorrelationId
                    bubbleUpEmojiOrStickersets = messageBubbleUp

                    // Scheduling, quick replies and message TTLs are server features: the demo
                    // sends everything immediately, as an ordinary cloud message.
                    let requested = requestedAttributes.filter { attribute in
                        !(attribute is EphemeralOutgoingMessageAttribute)
                            && !(attribute is OutgoingScheduleInfoMessageAttribute)
                            && !(attribute is OutgoingQuickReplyMessageAttribute)
                    }
                    attributes = outgoingMessageAttributes(requestedAttributes: requested, isSecretChat: false, peerAutoremoveTimeout: nil)

                    if let replyToMessageId {
                        attributes.append(ReplyMessageAttribute(messageId: replyToMessageId.messageId, threadMessageId: nil, quote: replyToMessageId.quote, isQuote: replyToMessageId.quote != nil, innerSubject: replyToMessageId.innerSubject))
                    }
                    if let replyToStoryId {
                        attributes.append(ReplyStoryAttribute(storyId: replyToStoryId))
                    }
                    if let mediaReference {
                        mediaList.append(augmentMediaWithReference(mediaReference))
                    }
                    for (_, file) in inlineStickers {
                        transaction.storeMediaIfNotPresent(media: file)
                    }
                case let .forward(source, messageThreadId, _, requestedAttributes, messageCorrelationId):
                    guard let sourceMessage = transaction.getMessage(source) else {
                        continue
                    }
                    text = sourceMessage.text
                    mediaList = sourceMessage.media
                    threadId = messageThreadId
                    groupingKey = sourceMessage.groupingKey
                    correlationId = messageCorrelationId
                    attributes = forwardedMessageAttributes(requestedAttributes: requestedAttributes, sourceAttributes: sourceMessage.attributes, forwardedMessageIds: [])
                    attributes.append(ForwardSourceInfoAttribute(messageId: sourceMessage.id))
                    if let author = sourceMessage.author {
                        forwardInfo = StoreMessageForwardInfo(authorId: author.id, sourceId: sourceMessage.id.peerId, sourceMessageId: sourceMessage.id, date: sourceMessage.timestamp, authorSignature: nil, psaType: nil, flags: [])
                    }
            }

            var randomId: Int64 = 0
            arc4random_buf(&randomId, 8)
            attributes.insert(OutgoingMessageInfoAttribute(uniqueId: randomId, flags: OutgoingMessageInfoFlags(), acknowledged: true, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets, partialReference: mediaReference?.partial), at: 0)
            uniqueIds.append(randomId)
            resultIndices.append(messageIndex)

            var authorId = account.peerId
            if let channel = peer as? TelegramChannel, case .broadcast = channel.info {
                authorId = channel.id
            } else if let sendAs = attributes.compactMap({ $0 as? SendAsMessageAttribute }).first, transaction.getPeer(sendAs.peerId) != nil {
                authorId = sendAs.peerId
            }

            let entities = attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first
            let (tags, globalTags) = tagsForStoreMessage(incoming: false, attributes: attributes, media: mediaList, textEntities: entities?.entities, isPinned: false)

            let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: nextId)
            nextId += 1
            storedTimestamps[messageId.id] = timestamp

            storeMessages.append(StoreMessage(
                id: messageId,
                customStableId: nil,
                globallyUniqueId: randomId,
                groupingKey: groupingKey,
                threadId: threadId,
                timestamp: timestamp,
                flags: [],
                tags: tags,
                globalTags: globalTags,
                localTags: [],
                forwardInfo: forwardInfo,
                authorId: authorId,
                text: text,
                attributes: attributes,
                media: mediaList
            ))
            timestamp += 1
        }

        if !storeMessages.isEmpty {
            let added = transaction.addMessages(storeMessages, location: .UpperHistoryBlock)
            for (index, uniqueId) in uniqueIds.enumerated() {
                guard let messageId = added[uniqueId] else {
                    continue
                }
                resultIds[resultIndices[index]] = messageId
                if let storedTimestamp = storedTimestamps[messageId.id] {
                    // The chat's own read index moves with the sent message, so the new bubble
                    // settles into the same read state as the seeded ones.
                    transaction.applyOutgoingReadMaxIndex(MessageIndex(id: messageId, timestamp: storedTimestamp))
                }
            }
        }

        return resultIds
    }
}

/// Writes an outgoing gift service message straight into the chat history.
///
/// This is the demo's answer to `payments.sendStarsPaymentForm`: with no server to charge Stars
/// from, the purchase is just the message appearing, already delivered, the same way
/// `demoEnqueueMessages` handles ordinary text.
///
/// Returns the id of the message it wrote, so the caller can show a preview of it.
public func demoEnqueueGift(account: Account, peerId: PeerId, action: TelegramMediaActionType) -> Signal<MessageId?, NoError> {
    return account.postbox.transaction { transaction -> MessageId? in
        guard transaction.getPeer(peerId) != nil else {
            return nil
        }

        var timestamp = Int32(Date().timeIntervalSince1970)
        var nextId: Int32 = 1
        if let topIndex = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud) {
            timestamp = max(timestamp, topIndex.timestamp)
            nextId = topIndex.id.id + 1
        }

        let media: [Media] = [TelegramMediaAction(action: action)]

        var randomId: Int64 = 0
        arc4random_buf(&randomId, 8)

        var attributes = outgoingMessageAttributes(requestedAttributes: [], isSecretChat: false, peerAutoremoveTimeout: nil)
        attributes.insert(OutgoingMessageInfoAttribute(uniqueId: randomId, flags: OutgoingMessageInfoFlags(), acknowledged: true, correlationId: nil, bubbleUpEmojiOrStickersets: [], partialReference: nil), at: 0)

        let (tags, globalTags) = tagsForStoreMessage(incoming: false, attributes: attributes, media: media, textEntities: nil, isPinned: false)

        let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: nextId)
        let storeMessage = StoreMessage(
            id: messageId,
            customStableId: nil,
            globallyUniqueId: randomId,
            groupingKey: nil,
            threadId: nil,
            timestamp: timestamp,
            flags: [],
            tags: tags,
            globalTags: globalTags,
            localTags: [],
            forwardInfo: nil,
            authorId: account.peerId,
            text: "",
            attributes: attributes,
            media: media
        )

        let _ = transaction.addMessages([storeMessage], location: .UpperHistoryBlock)
        transaction.applyOutgoingReadMaxIndex(MessageIndex(id: messageId, timestamp: timestamp))
        return messageId
    }
}

// MARK: - Gift pictures

/// The seeded gifts' pictures: the app's own gift-box animation, base64-encoded.
///
/// Every gift screen draws a gift file with an animated sticker node, and each of its paths
/// unzips the data before parsing it, so the picture has to be a gzipped Lottie -- a PNG, or a
/// plain JSON, draws nothing. These are `TabGift.tgs` with the box painted in the gift's colour
/// and the ribbon and bow left white, gzipped and base64-encoded so that seeding needs neither
/// a bundle lookup nor a decompressor of its own.
private let demoGiftAnimationBase64: [String] = [
    """
H4sIAAAAAAAC/+1c2W7cRhb9laCfSaL2RY8ZIMG8DZC8GXrQxHLsiWwZkpJMEPjf55x7i2yy1a3IEjWW4kbgqFmsjecudTfyz83N
z9ebE9ttftucbOIQB7fpNm+uNifJdJt3Hzcn+HOJPz52m983J9G6bvO2/f3wHmO+/+d3P37jMej169fS++z6+vwGc7467TYXZ3+c
X/H3n9Ptdx9ey3o3f2xOQpvjX2c3P73FFNdXcusXjPhzc8n/nWmDzHCDXaAPfltjTmUb9lMn7Vnbd1ptPtDd2Z3+p5+6zce2ntH1
XEwd/5nTT7h5dik3rt+efTzX5+H+Nz9fYdfvbqRBHszog6HjZnyO+SO8Y8N/0W0oHs/yR/uFBS6nOzbldge/cGf72DL+1SuDPXWv
7JBc7Ho3FOtw2Wf+6DDIRVxqnx6zB9u5wcSolz5E9Im2nJ7KmuNsvU43zuYHkzC5GUyo02x2KLl0fRhiyWwcpEeOnOo3TpVD11sf
2hYSfhT0tw49E2fNprVYP7CHtdhQjtpQsjZhFct5bB6CsdKUOSOnNlzqp83JzdWv56TZgwENewGNNQig/iCedjDOA6VQwl/gSQRd
F4fgyyE83eCK73oIXUh78UxxkMdObROxEEhiUwkkMTatxXCGGonieGWNH1z07G6HnHIDvEEp9F4LzrgXTuKHp6uCwCE8A5gmD77Y
hqe16BOw2x08zVBD6fxgTT7Mn9ZVrpjiXjhjUjjrIFsIlVsjPCPXs4OiGbRLYVe5JrppqMLhgBP4CcJudSjTYShTI/oKUFpPKO2D
oQyj4Loskuxdw9LUIckmgXLQFqtY5izoG9u2XXDUOMJpCjqQYVVZOLm/EprjCbCAE1Bl3JjwhKLZAdMOvqYJSzO4GvdCiT0AuxFJ
qI5q/C6U1BlpiyXukk5LOHsfsWeKqiuCZ4+/1gpzmgZoD8XqVLqdItpDn3qvDba15CGFrHRQUPuC7efEqf2qyJYHIYujyLmu4OHT
Gsg6amwga/xBaCHmCm2QmYJrwLpRh/ahNGCdjCRmbshm0VJdA9abEdgaGrBhVQVg6wsBNuYhi8hGS2XAfvjlgldwlSEjdyo4NjMF
KjXEJbQV0raEllqiGkts/Vq4OvNCcE1+CNYvcS1DGplWcYVxlUeebcji9DdlDqw1UTa/RBZq2KX9yM4s4+ePEoR2h/sIXF1wX8Jp
tAMSDv0l+1FVll3+g0kQ9vIfHYXRZXn7jYWR/xZW/5uzi+tzQZC2/5uLjQyZexM4BLrZv9ORW6ce8FHQpv7Pv99Lq6zz3buLiwPr
3ND52PFaCCHdlb2t1zt7MtiLkTtXizvmwO6uf7nV7frsVpNs+8ersw/Xby6v3m8+nbamH+g7yaO059s+0am6ml5dTVsoqjfSR7ry
iRfuo1u6j99e/k4kzq7OPzRnae5H7iBEbqOc4MitqRyAC3Z1sPEL+H7arhprqbB62FgRR5CIUefhQYmVT8shhMkELODtEMC8Wa2y
7Yh+GtJPY0bhnE2y7LidgFJYnUzuTVzMstzPOGRyYsKQfGiI0raCaeMI/JDlRIaTk3Hm9VMHXQhqqqgMQ+vAydre73dn6JdLqLw2
xlrNqenpj8bSQaO40Mw6KBKqmsRrB/fRxcnANnVGB0tPI07wwoHOqmYCOooP78NWU1L3iLVf5OlgL0doIngZ1Ym5MpuNVj7V1JYo
s22AKONKGJKAKb0nu7XhCXHpYmi4ZvUusRlxdwK1IR24NJhGF6410SXQ7YW2pdb1VYzP5p6ioxPFDcPIcAVseEW62F25GGwe2ZDk
kEMDm3IT4wr/BDg6Lbax7U9ijOZ1GzHJxDQDuk3zzlaTY4vxEEd/aj5Fw745Qm3AJA+A0c/FAYIDjOC5c3MJLMM5wWw+COhcA6sH
YTrcpijQ23IqCjIaiBeVhPnkdwCucNu/hHppDeCU926LdGMEGNS14TkYnr9A2puqt7YDCHURDMcBI9LzGQRqnXg2GL+szOvsbHyD
WSed1toa/miIW6D7Ino/wi9W/oUwcLMwrWqjJhYpsAW4RlAHWJibSOtgPmCWu7Opb8HMM2gZYIJSDPmW6qYGNXIEUcpDsTOV0S+G
9HN1r0Mm8GaTLDrOxkOhzpXEYsRC2euIrY2F3dQ5hHT3a3UzzYsIFWOC2y662KgloLwNUZ6x+3KG5RJLKO9ja92832ztmltH7StR
KKfC1u33jOVfCadPd/m7sf0YHZ4LzQPnaqHbtMZcYQxnrzFZXHOytOJT5hXRt6tO1kIeOEXWmK2uOdvo3a40m12TOeAZzriDDWmi
Cruc73E1Lm+5Fe9FLptz8e79N1QK1we0ApyHh3pgv99Tl9Sadx4+jPdOF+Z7uIXhOIm9Az0Do3J5BiODs3O4hIbfxU/iEV38R/7M
nccfbq4ufzn/e7iPpPcdvqO5r+/ol77jPy5/O7+aeY/hbu+RzmPVuHcQN2cfWgh6mc9IHH4Jb7KFWhIcJ08HxKkR5BEdkbAH4p9O
zZIosevgxY9gO4JH6CYBG9vGI0YtdhEcZ1hGZRvKgT3KJISBRzG5Nwjv0EoexEeQGZmMaBPKeuNyuk6nqzZztwbxY9QVggtPKw2y
59K0KJejkTxIjsbMDBrEfGrC45E+4uMkWoO4hhXjsybQAg1sh7+a89EGXMtutT+6a0qrcH3fwUMqslaPFFEMXcCgXLfXPRpcDG2E
5eYwJJX8lOk3YBclOg1E0wNIC0O4ZPHlathHWY/4Y2IUME6UpaNYJDD4+ZQFReAl0cdtPkURtor2HmSFm+npiAFUTdg8kqzgMp9I
VRNL86kNfGpQMQpybAiMPZKu6umCqSttbAxiCHGtVIB5AsIiQ5TjnYR1yS4JCzYXwqqSeCRhQwh7KBsOUTYXFZeYHk9Z5CQLQhq4
LMWpj+ThCIGMXvQHYyygAunqa9UYCOPeWJ5e4FpUtU+giZGrrHcpYgiUiU+oiZEe83GfJnZPqIlnMosEnuSxOaENmkEFllaomzQ+
NbaQvqZqpyz4KocpNKuQ2B9J/PJIfN+gWDgSd33iMjqFjAuIlJPSDYm90LRzqfMW0c8aD0W2GTgrcXMM+zKaPhwN3+dt+D40p4qH
8mKVdFIH85RpVQuCBye5DWPtS3ORuy/qY87Y0k28SgZKysDkKNR/ZjCY17z9Le6H2G9lY0dyaHsjlgY+cGnming7pgjMJJ8aw2Y1
qVAyFzfNp7ItRqkuN4k+m2eKAXyQpErUlR0hExYPyuK1aMFg9FWlIIVtA8UkFS2Bq7imGLkWTR+VYm4VHaMQ2jprEDHVI7ANEUkO
qklnsm7Dk7qYXwtlbW65TpJWnsMWPzT9JpXNvC5JNWAS9Z6RbhQN6WN+5rS1B8U23CauFM89FXHRGQXL+4kbtNpsdeI65G+jb06m
PCqKpoeUkpDXCvA4xGB6ZgkBZJKP5kq2JG949tS1h6jrdqkraWVNRz6csGaWnKTVmvbTE2EI+2BqwlZ0rNiC9OUdcjIdD+9eZTXY
VjhLWw6ZXq+lG9qA66BpanKAELPk9aiJqgfbggcxlqf1LI/UfDbUfJQTeaTjF6bjQX/xaMQ+GyP2BbiL/egvmpfqKr6w5PD3V5e/
flwjOxx2K4tvbi7fb+7OCTvwLWuaQmKeIBxAqULCrVuCta/IgBEi+TdWCXT4b6dSgHws/8Z6ga5RYeuDNwI0Iqy6wli4An2DOrw9
C8grkfz3wAXGYhZU5fPdpjytMVPPi+d7zpl2BKChc/QtB9MqTZkSQwEiQnpatQe9nMrsWIGTwXe4GNqUczUz2BdoHGjWyhY5pV3J
O7FaHhBpGYXUMKSfThXsRiPJujgTc9CFRcJ84zmDAuukcVFUsSYpxg56bHl5Y0NeKI3juWh1sVlMMu4LIUvpJzY4YuHn77k61pZD
RIxNWopseLIWus96zfAnX2/zKW0bKuqLeYLA2ebriKjWlAJHHPIRZ29huaZt75kAcZleKJBodERtyK10mfPlSsdv1tCjJWpLAggm
c5NPE1M58smz4xO8g4nele/LpjF5LUwSU9xe98I1WfpXJnGo6Y19oujMKmzC1MXIJmZuYcIIFeYwcW3m4Ou0MXplAMf6Crzeledf
KjBVCgOcs1+eK7A/cIWV7w8EvkSGyvDcuALXGS/0YvZS23UAoGSL6vUaroWwRZYJktnyhU9PFNf5P6kPvKwT+FmDmu1RffzVMeNQ
XB9EgZSs7yjEKHHEwgIifQOSr980JZJr68TXOXSfNrknihwd+eXr45eHxaaOhskz5BR8JkMsWIp+4x03mrAjq7QWYZWgBgtfD1Qj
drD3iX4daf/3dl5eQCytFjnnCEc8Fl7cL+TAOhwW7Opnt24nF+I8hO2d8v3UJq/rdrZ9DIHsnRGoVp+Ahbip40dpYp2kbWbGUy+w
8+6HH2TVmafRTyIfZh9+QPW0ESfAtjeK0UkC7EVVGqLeQV0X0S39rrKZxJa90FmKePm1CQ12u7rN+uLjJRZT07mT+DwlZNFAIYoi
Q0FsF72mLtVKZEghaKNRPc3SAJjpkq9l+oxPYsjL2rJX1G3zBVO+bq0P56X6GHJvwyS2kGs4nWV7SbXhZAM9ChldwZNwzlKeKApx
ZJ3PZh1LK01a5EUBKQ/UF7XFJ9xeU0MLWBxBIlXxDF8y99ij5nks+yDlx5yosI+T3KjzMCGy8k+RIMnYQm0kHOZc+xyF4Xs4L5qD
9tWn3MU4e/6PR6WFoOYXZLDQyAumfA6f8JN/NC1tzXfyymKDWVLpzLrKEo9gC6Y6I6xv8kXL6UbmYqu06OcmUf+cfdYzqcwaeCg1
tqRtK0TOZfwiF2NVUFCaRI/6eU00hPaBLidfNuDX+DRf+1zYwh/Z4utgi8dUzBwZQr+xNzFEfbkcsSf6cLQmvjY/5iUU9zAiId/Y
Otb2POvantNP/wNeiJyL3l4AAA==
""",
    """
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
tT3Purbn9NP/AHWXcRXeXgAA
""",
    """
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
z7Ou6zn99D/iUCtQ1l4AAA==
""",
    """
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
sudZV/acfvofpBJ3XtpeAAA=
""",
    """
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
2/Osa3tOP/0PrUg6YN5eAAA=
""",
    """
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
1rG251nX9px++h+Z/GBH3l4AAA==
""",
]

/// Decodes one of the seeded gift animations, or `nil` when there is no animation for the
/// index it was asked for.
private func demoGiftAnimationData(index: Int) -> Data? {
    guard index >= 0, index < demoGiftAnimationBase64.count else {
        return nil
    }
    let base64 = demoGiftAnimationBase64[index].components(separatedBy: .whitespacesAndNewlines).joined()
    return Data(base64Encoded: base64)
}

/// A gift picture for the catalogue: the gift emoji over a gradient, rendered locally so the
/// gifts screens have something to draw without a network.
private func demoGiftImageData(emoji: String) -> Data {
    let size = CGSize(width: 512.0, height: 512.0)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { context in
        let cgContext = context.cgContext
        let colors = [
            UIColor(red: 0.35, green: 0.33, blue: 0.94, alpha: 1.0).cgColor,
            UIColor(red: 0.94, green: 0.35, blue: 0.62, alpha: 1.0).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
            cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: [])
        }

        let font = UIFont.systemFont(ofSize: 300.0, weight: .regular)
        let attributedString = NSAttributedString(string: emoji, attributes: [.font: font])
        let textSize = attributedString.size()
        attributedString.draw(at: CGPoint(x: (size.width - textSize.width) / 2.0, y: (size.height - textSize.height) / 2.0))
    }
    return image.pngData() ?? Data()
}
