import SwiftUI

@main
struct TeslaNavApp: App {
    @StateObject private var deepLink = DeepLinkManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environmentObject(deepLink)
                .onOpenURL { url in
                    deepLink.handle(url)
                }
        }
    }
}

class DeepLinkManager: ObservableObject {
    @Published var pendingPrompt: String?
    @Published var shouldOpenSettings = false

    func handle(_ url: URL) {
        guard url.scheme == "teslanav" else { return }

        // Apply any config params from URL
        var settings = AppSettings.current
        var changed = false
        if let key = url.queryValue(for: "claude_key"), !key.isEmpty {
            settings.claudeApiKey = key; changed = true
        }
        if let key = url.queryValue(for: "google_key"), !key.isEmpty {
            settings.googleMapsApiKey = key; changed = true
        }
        if let token = url.queryValue(for: "tesla_token"), !token.isEmpty {
            settings.teslaAccessToken = token; changed = true
        }
        if let backend = url.queryValue(for: "backend"), !backend.isEmpty {
            settings.backendUrl = backend; changed = true
        }
        if changed { AppSettings.current = settings }

        switch url.host {
        case "route":
            if let prompt = url.queryValue(for: "prompt") {
                pendingPrompt = prompt
            }
        case "settings":
            shouldOpenSettings = true
        default:
            break
        }
    }
}

extension URL {
    func queryValue(for key: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == key }?.value
    }
}
