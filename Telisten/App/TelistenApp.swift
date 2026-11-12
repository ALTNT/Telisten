import SwiftUI

@main
struct TelistenApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    @State private var startupTask: Task<Void, Never>?
    #if os(macOS)
    @AppStorage("floatingLyrics.locked") private var lyricsLocked = false
    #endif

    var body: some Scene {
        WindowGroup(id: "library") {
            RootView(model: model)
                #if os(macOS)
                .environment(\.openLyricsWindow, { LyricsWindow.open(model: model) })
                #endif
                .task { await startIfNeeded() }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        model.applicationDidEnterBackground()
                    case .active:
                        Task { await model.applicationDidBecomeActive() }
                    default:
                        break
                    }
                }
                #if os(visionOS)
                .frame(minWidth: 760, minHeight: 560)
                #else
                .frame(minWidth: 360, minHeight: 560)
                #endif
        }
        #if os(visionOS)
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)
        #endif
        #if os(macOS)
        .defaultSize(width: 1_080, height: 720)
        .commands {
            CommandMenu("Playback") {
                Button(model.player.isPlaying ? "Pause" : "Play") { model.player.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Previous") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()
                OpenLyricsWindowButton()
                    .environment(\.openLyricsWindow, { LyricsWindow.open(model: model) })
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Toggle("Lock Floating Lyrics", isOn: $lyricsLocked)
            }
        }
        #endif

        #if os(visionOS)
        // A stable value brings the existing lyrics window forward on repeated opens.
        WindowGroup("Floating Lyrics", id: LyricsWindow.id, for: String.self) { _ in
            FloatingLyricsView(model: model)
                .task { await startIfNeeded() }
        } defaultValue: {
            LyricsWindow.currentPlayback
        }
        .windowResizability(.contentSize)
        #if os(visionOS)
        .windowStyle(.plain)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }
        #endif
        #endif
    }

    @MainActor
    private func startIfNeeded() async {
        if startupTask == nil {
            startupTask = Task { await model.start() }
        }
        await startupTask?.value
        if scenePhase == .active {
            await model.applicationDidBecomeActive()
        }
    }
}
