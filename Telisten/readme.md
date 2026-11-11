根目录里的 [project.yml](../project.yml) 描述 Xcode 项目怎么生成、有哪些 Apple 平台目标和依赖；你在 Xcode 里打开的 [Telisten.xcodeproj](../Telisten.xcodeproj) 才是实际使用的 Xcode 工程。Telisten-iOS、Telisten-macOS 和 Telisten-visionOS 是不同的构建目标。

你打开的 [telegram-methods.txt](../telegram-methods.txt) 列出要生成的 Telegram API 方法；[.env.example](../.env.example) 是本地配置的示例文件。

用“点一首歌”看代码怎么流动

1. [LibraryView.swift](../Telisten/Views/LibraryView.swift) 显示歌曲列表。点击歌曲后，界面把操作交给 AppModel。
2. [AppModel.swift](../Telisten/App/AppModel.swift) 更新播放队列，并决定接下来如何准备歌曲。
3. 如果歌曲已经缓存，就从本地播放；否则由 TelegramService 取音频数据，同时可以边下载边播放。
4. [AudioPlayer.swift](../Telisten/Player/AudioPlayer.swift) 使用 Apple 的 AVPlayer 播放音频，并更新进度、播放和加载状态。
5. AppModel 的状态变化会通知 SwiftUI，界面随之更新；歌词则由 LyricsService 另外加载。
   先认识几个 SwiftUI 术语

- View：一块界面，比如登录页或歌曲列表。
- @StateObject：创建并持有一份会持续存在的状态对象。入口 [TelistenApp.swift](../Telisten/App/TelistenApp.swift) 用它创建 AppModel。
- @ObservedObject：让某个界面观察已有的状态对象。比如 [RootView.swift](../Telisten/Views/RootView.swift) 接收 AppModel。
- @Published：标记状态属性；值变化时，观察它的界面会刷新。
- async / await：用于等待网络请求等耗时工作，避免界面卡住。
- #if os(iOS)：根据平台选择性编译代码。同一批 Swift 文件能为 iOS、Mac 和 visionOS 做不同处理。
  建议的阅读顺序
  先看 TelistenApp.swift → RootView.swift → LibraryView.swift，了解应用怎么启动、怎么选页面。然后在 AppModel.swift 里搜索 func play 和 func loadTracks，跟着看一次“播放歌曲”和“加载歌曲列表”；最后再读 AudioPlayer.swift、TelegramService.swift 和存储代码。

AppModel 里功能比较多，不必从头逐行读。先把“界面把动作交给它，它再调用合适的服务并更新状态”这个角色弄清楚就够了。

| 目录                                                           | 作用                                                               |
| -------------------------------------------------------------- | ------------------------------------------------------------------ |
| [Telisten/App](../Telisten/App/TelistenApp.swift)               | 应用入口，以及创建和启动应用状态                                   |
| [Telisten/Views](../Telisten/Views/RootView.swift)              | SwiftUI 界面，例如登录、曲库、播放器和设置                         |
| [Telisten/Core](../Telisten/Core/Models.swift)                  | 应用共用的数据类型和小工具，例如歌曲 `Track`、聊天 `MusicChat` |
| [Telisten/Telegram](../Telisten/Telegram/TelegramService.swift) | Telegram 登录、搜索、取回音频等通信逻辑                            |
| [Telisten/Player](../Telisten/Player/AudioPlayer.swift)         | 音频播放、流式读取和“正在播放”状态                               |
| [Telisten/Storage](../Telisten/Storage/CacheStore.swift)        | 音频缓存、本地曲库资料和 Keychain 凭证                             |
| [Telisten/Lyrics](../Telisten/Lyrics/LyricsService.swift)       | 查询、读取和缓存歌词                                               |
| [Tests](../Tests)                                               | 测试代码和测试用音频                                               |
| [android](../android)                                           | 独立的 Android 版本，使用 Kotlin，不是 iOS 代码                    |

## iOS 16.3 / TrollStore 本机编译

保存 Swift 文件本身不会触发依赖权限错误；它会让 Xcode 重新编译相关源码。最近一次失败分成了几个阶段：

1. 受限构建环境拒绝 SwiftPM 创建临时编译文件，并且不能写入用户目录下的 SwiftPM 缓存。这是构建环境权限问题，与 Swift 代码内容无关。
2. 使用本机权限重试后，SwiftPM 通过了依赖解析，但当前活动缓存目录缺少 `TDLibFramework.xcframework`。本机已有的 358 MB 压缩包校验和正确，将它解压到同一个 SwiftPM artifacts 目录后才继续。
3. 这次重试使用的包缓存目录是 `/private/tmp/TelistenSwiftPackages`；之前生成包的构建使用了 `/private/tmp/TelistenSourcePackages`。源码绝对路径不同，加上缺少 XCFramework，使 SwiftPM/Xcode 需要重新编译许多依赖；因此耗时明显变长。依赖编译完成后，应用代码还暴露了分页消息 ID 的 `Int64` / `Int32` 类型不一致，现已统一为 `Int64`。

现在统一通过一个脚本构建，固定临时目录、SwiftPM 源码缓存、构建产物路径，检查 TDLibFramework 校验和，只有构建成功且确认最低系统版本为 iOS 16.3、包含 arm64 后才生成 `.tipa`：

```sh
./Scripts/build-ios-tipa.sh
```

首次使用需要 `.env` 中配置 `TELEGRAM_API_ID` 和 `TELEGRAM_API_HASH`；脚本会调用 `generate-local-config.sh` 更新本机配置。后续使用相同路径的缓存，Xcode 通常只会重编译改动的代码。构建日志写入 `/private/tmp/Telisten-iOS-16.3-build.log`，安装包写在仓库根目录 `Telisten-iOS-16.3.tipa`。本流程不执行 Telegram 登录验证。安装包内包含 API ID 和 hash，请不要公开发布。
