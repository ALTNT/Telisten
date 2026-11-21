# Telisten

A native Telegram music player for iOS, macOS, visionOS, and Android. Play music from your chats, organize playlists, and keep downloads and lyrics available offline. No Telisten server or bot token required.

## Features

- Music search across chats and through configurable search bots
- Streaming, downloads, a configurable cache, and background playback
- Telegram-backed playlists with a customizable folder name and local ordering
- Timed lyrics, alternative matches, LRC attachments, and offline lyrics caching
- Floating lyrics windows on macOS and visionOS, with an optional always-on-top mode on Mac
- Multiple accounts, favorites, queue controls, and Listen Together

Telegram permissions still apply. Secret chats are not supported. Listen Together is experimental.

## Imported music playlists (Apple)

Open **Library → Imported playlists**, paste a public NetEase Cloud Music or QQ Music playlist link (or its share text), and choose **Read playlist** to preview and save the song list. NetEase short links are supported. The preview shows the number of songs read against the platform's total; incomplete responses are labeled. Importing the same playlist updates its local snapshot and preserves existing audio associations. Snapshots and pending edits are saved locally, separately for each Telegram account. **Playlist sync → Sync using Telegram** is enabled by default and uses a dedicated private **Telisten Sync** channel owned only by that account. Signing in to the same Telegram account on another Apple device restores playlist metadata, order, selected bot configuration and audio-message associations. Downloaded audio remains device-local.

Choose a configured MusicBot that supports `/music <song link>`. Playing an unresolved song requests that track from the bot at its default quality, then uses the normal Telegram streaming and cache path. While a song plays, Telisten prepares and caches the next song. Automatic transitions reuse any match already in progress. Mobile background execution can limit requests for unresolved songs after locking the device.

In an imported playlist, use **Play all** or **Select songs → Play**. Next and previous follow the active selection and playback mode. Use **Add to…** from a song’s context menu or from the selection controls to add audio to Favorites or a Telegram playlist. Telisten prepares unresolved selections one at a time and opens the destination picker with the available audio.

Bot requests allow up to two minutes of foreground waiting, with a fifteen-minute overall ceiling for uninterrupted background polling. Returning to the foreground pauses out the background interval and leaves at least fifteen seconds to check newly delivered audio. The latest bot history is always checked before a timeout is reported. If the bot confirms that a song is unavailable, waiting ends immediately and that entry is marked for explicit retry. Requests without a definitive response, including timeouts and cancellations, have a one-minute retry delay because the bot may still be processing them.

Use a song's context menu to **Choose received audio** if automatic matching cannot confirm a bot response, or **Forget matched audio** to replace an unavailable source. Matched audio is distinct from downloaded audio; only downloaded files are available offline. Platform login and automatic refresh from NetEase/QQ are not included. Telegram synchronization runs after edits, at startup and on returning to the foreground; **Sync now** also retries pending uploads. Turning sync off keeps local edits available for a later retry. Sync records include deletion markers so an old offline copy cannot silently restore a deleted playlist. Concurrent edits of the same item preserve a local draft under **Resolve sync conflicts**, where you can choose which version to keep. Source bindings use Telegram chat/message references; TDLib file IDs are resolved on the receiving device. The sync-channel index is stored in Saved Messages; keep those index messages and the channel to retain the cloud history. If simultaneous setup creates multiple indexed channels, their records are merged. Uploads are acknowledged only after Telegram confirms delivery.

Run `bash Scripts/test-imported-playlists.sh` for importer, playback, sync merge/storage, private-channel validation and sync concurrency tests. These tests use fake transports and send no Telegram messages. Add `--live` to check the two public example playlists over the network; this reads metadata only and sends no Telegram messages.

## Build

Both apps live here: `Telisten/` contains the SwiftUI iOS/macOS/visionOS app; [`android/`](android/README.md) contains the Kotlin/Compose Android app. Apple uses TDLibKit; Android uses TDLib and Media3.

Get a Telegram API ID and hash from [my.telegram.org](https://my.telegram.org), then create your local configuration:

```sh
cp .env.example .env
# Set TELEGRAM_API_ID and TELEGRAM_API_HASH in .env.
```

### iOS, macOS, and visionOS

Use Xcode 16.2 (Swift 6.0). The minimum deployment targets are iOS 16.3, macOS 13, and visionOS 2.

```sh
./Scripts/generate-local-config.sh
open Telisten.xcodeproj
```

Select `Telisten-iOS`, `Telisten-macOS`, or `Telisten-visionOS`, choose your signing team, and run. Review and trust the pinned `TLCodingMacros` macro if prompted. Add `--demo` to a Debug scheme to explore without logging in. XcodeGen is only needed when changing `project.yml`.

To build an iOS 16.3 package for TrollStore, run `./Scripts/build-ios-tipa.sh`. It creates `Telisten-iOS-16.3.tipa` in the repository root. The packaging step embeds and verifies an ad-hoc signature with the Wi-Fi information entitlement so the installer can preserve it.

To build the universal macOS 13 DMG, run `./Scripts/build-macos-dmg.sh`. In addition to Xcode, this requires CMake; the script uses the system Git, Make, Perl, and Python 3 tools. It rebuilds the pinned TDLib and its existing OpenSSL 3.1.5 dependency for macOS 13 instead of linking the upstream archive's macOS 15 objects. The first build downloads OpenSSL sources and compiles both architectures; later builds reuse `/private/tmp/TelistenMacTDLib`. Set `TELISTEN_MAC_TDLIB_BUILD_ROOT` to relocate this cache or `TELISTEN_TDLIB_JOBS` to change its default four build jobs. Each architecture's object deployment versions are checked before packaging; incompatible objects fail the build instead of being hidden.

On visionOS, choose the Apple Vision Pro destination and install the visionOS SDK/simulator in Xcode if needed. The native app opens a resizable library window with a separate lyrics window you can place in your space. Use `--demo --demo-chat --demo-floating-lyrics` in a Debug scheme to preview both windows without signing in.

#### Video playback (Apple platforms)

Video playback is off by default. Enable **Settings → Videos → Enable video playback**, then open **Videos** in the library and choose a Telegram folder (the “影视” folder is selected initially when present). Channel videos and video documents support search, pagination, system playback controls, full screen, and per-account resume positions. On macOS, playback opens in an independent window with a draggable title bar and resizable edges; closing it saves progress and stops playback. In the video window, Left/Right seek backward/forward by 10 seconds and Space toggles video playback.

**Prefer 1080P from comments** is on by default. The video list checks up to four posts concurrently and displays the selected reply’s title, file size, and a “1080P from comments” source label. Pending searches, inaccessible comments, and original-video fallbacks are labeled separately. Before playback, Telisten checks the post’s discussion thread for a matching 1080P video using dimensions, duration, and episode number when available. If no match is found or comments cannot be accessed, it plays the original; **Play original video** also switches back manually. If the supplementary document search times out after the video search succeeds, the loaded videos remain visible with a retry message; the cursor stays at the same page so retrying does not skip document videos. Searches inspect up to 1,000 replies per post. Playback format support depends on the system player.

Videos buffer on demand in TDLib storage with a bounded 32 MB forward download window, without triggering a full-file download fallback or using the music offline cache quota. Buffered ranges are reused across seeks; stalled downloads retry after 15 seconds without progress. The player displays a buffering indicator while waiting for data. Video reads request only the bytes needed by the decoder, and cancelled reads release their download work. The player disables AVPlayer’s automatic network-stall prediction for the custom Telegram transport, so locally supplied bytes can resume playback without waiting for an unrelated network estimate. Use **Settings → Videos → Clear video buffers** to reclaim that storage. Closing the player stops its requests; video buffers are not an offline video library.

#### Telegram proxy (Apple apps)

Open **Settings → Network → Telegram proxy**, or **Telegram proxy** on the login screen. Choose a fixed SOCKS5 server (hostname/IP, port, optional username/password), or **Automatic by Wi-Fi**. Add a rule for each exact Wi-Fi name and its proxy. For example, use `192.168.234.236:7893` on your home Wi-Fi and leave **Use SOCKS5 on other networks** off to use system routing, including your enabled phone VPN, on mobile data. Telisten does not enable the VPN itself. You can also configure a fallback SOCKS5 server for unmatched networks.

On Apple devices, **WEB proxy** uses Telegram's HTTPS relay protocol. Enter the provider's domain name, relay path if supplied, and Secret. For example, enter `proxy.example.com` and `telegram/web` in the two address fields if the provider gives `proxy.example.com/telegram/web`. The Secret field accepts Telegram's WEB share-link secret or its hexadecimal equivalent. **Test saved proxy** checks Telegram connectivity through the relay. The provider's page runs in a dedicated WebView while connected. Use a provider you trust.

Wi-Fi name detection is supported on iPhone/iPad and requires **Allow Wi-Fi detection**, precise location permission, and the Access WiFi Information signing capability included in the iOS entitlements. Existing provisioning profiles may need regeneration. Local proxies also require local-network access when iOS prompts. During a Wi-Fi connection, transient failures to read the name retain the last verified Wi-Fi selection. Reading a different name, leaving Wi-Fi, or losing location permission invalidates it. An unidentified network without a verified name uses the configured fallback. macOS and visionOS support fixed SOCKS5, fixed WEB, and direct connections.

Settings are device-local in Keychain and apply across Telegram accounts, including login and TDLib music/video transfers. Network changes and returning to the foreground re-evaluate the rules; while running, Wi-Fi names are also checked every 15 seconds to detect switches between access points. iOS suspension can delay checks until the app runs again.

Run `bash Scripts/test-telegram-proxy.sh` for routing and validation tests. On a signed iPhone build, verify matching Wi-Fi → mobile data → another Wi-Fi → matching Wi-Fi, including during playback, after relaunch, and with Wi-Fi/location permissions denied. Simulator/type checks cannot verify actual SSID detection, VPN routing, or LAN reachability. For SOCKS5, **Test saved proxy** tests the phone-to-proxy TCP connection (including the iOS local-network permission path), then TDLib’s proxy latency check with a 30-second deadline, without forcing DC2. The probe is independent of chat searches: a timeout does not imply that every account request is failing. The test reports which stage fails and does not change the saved proxy or session. If SSID detection fails, exported diagnostics include `proxy_wifi_detection` events with default-path Wi-Fi status, SSID availability, location authorization, and accuracy authorization; they do not include Wi-Fi names or proxy credentials.

If Telegram reports **Wrong database encryption key**, the local TDLib database cannot open with the currently accessible Keychain key; a proxy change cannot resolve that error. This build does not request access to TrollStore’s shared legacy Keychain group. Use **Add Account** and sign in again with the same phone number. After successful authorization, the existing database for the same Telegram user is renamed to a backup before the new session is installed under the original account ID; account library data and offline audio remain associated with that account. Failed replacement rolls the directory changes back. Run `bash Scripts/test-session-replacement.sh` to verify session replacement, backups after restart, and rollback without Telegram credentials or real Keychain writes. Do not uninstall the app to perform this recovery.

After at least 30 seconds in the background, an authorized Telegram client still connecting gets a five-second grace period on return to the foreground. If it remains stuck, Telisten makes one attempt to reopen the same local session, waiting for TDLib’s actual Closed acknowledgement before opening its database again. Ready/updating connections and offline/login states are left alone; returning to the background or switching accounts cancels pending recovery. Diagnostics record background duration and recovery stages. Run `bash Scripts/test-foreground-connection.sh` for recovery, cancellation, duplicate-trigger, and safe-close regression checks. Actual iPhone suspension and network recovery still require device testing.

#### Floating lyrics

On Mac or Apple Vision Pro, select **Floating Lyrics** (the overlapping windows button) in the player bar or Now Playing. The compact, borderless overlay shows the current and next line, with a transparent background by default. Select a timed line to seek; untimed lyrics have manual paging controls. Opening it again brings the existing window forward. Closing it leaves playback running.

The Mac title and control bar appears only while hovering over the lyrics window and hides when the pointer leaves, without shifting the lyrics. Hover to reveal playback controls, the drag grip, lyric matches, and **Customize Lyrics**. Drag the grip or empty background to move the window. On visionOS the controls stay visible; use the system window bar to reposition the lyrics in your space. Customize single/double lines, alignment, width, font style and size, bold text, outline, current/next colors, text/background opacity, and the optional song title. Color presets and **Reset Appearance** are included; changes persist across launches.

On Mac, **Center Horizontally on Current Screen** in the floating toolbar centers the window on the display it currently occupies without changing its vertical position. **Playback → Floating Lyrics** (⇧⌘L) also opens or unlocks the overlay. **Keep on Top** is enabled by default. The lock button makes the window ignore mouse clicks so you can work through it; reopen Floating Lyrics or use **Playback → Lock Floating Lyrics** to unlock. The existing in-library Lyrics view (⌘L) is still available.

### Android

Use JDK 17 and Android SDK 36. Configure the SDK through Android Studio, `ANDROID_HOME`, or `android/local.properties`.

```sh
cd android
./scripts/setup-tdlib.sh
./gradlew :app:assembleDebug
```

See the [Android README](android/README.md) for installation and tests.

## CI and credentials

GitHub Actions builds both platforms on `master`, tests the offline library, and scans source/history for secrets. Set repository secrets `TELEGRAM_API_ID` and `TELEGRAM_API_HASH`; pull requests receive neither. Xcode Cloud uses its own secret environment variables. See [SECURITY.md](SECURITY.md) for signing secrets and credential handling.

Never commit `.env`, session data, publishing credentials, or signing keys. Native binaries contain the Telegram application ID/hash; keeping them in CI secrets protects source, not distributed binaries.

## License

[BSD 3-Clause](LICENSE). This project is based on [iebb/Telisten](https://github.com/iebb/Telisten) and contains modifications to the upstream project; the upstream copyright notice and license terms are retained in [LICENSE](LICENSE). Third-party dependencies retain their own licenses. Store screenshots and demo song references do not grant rights to the referenced music or lyrics.
