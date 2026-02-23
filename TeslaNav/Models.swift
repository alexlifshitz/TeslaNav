import Foundation

// MARK: - Route Models

/// A stop can be a specific address ("123 Main St") or a search query ("Starbucks on the way").
/// The backend resolves search-type stops via Google Places API.
struct RouteStop: Identifiable, Codable {
    let id: UUID
    var address: String
    var label: String?
    var notes: String?
    /// "specific" = exact address, "search" = needs Places API resolution
    var stopType: String?
    /// For search-type stops: what to search for (e.g. "Starbucks", "gas station")
    var searchQuery: String?
    var openTime: String?
    var closeTime: String?
    var dwellMinutes: Int
    var estimatedArrival: String?
    var driveMinutesFromPrev: Int?
    var hasConflict: Bool

    init(id: UUID = UUID(), address: String, label: String? = nil,
         notes: String? = nil, stopType: String? = "specific",
         searchQuery: String? = nil, openTime: String? = nil,
         closeTime: String? = nil, dwellMinutes: Int = 20,
         estimatedArrival: String? = nil, driveMinutesFromPrev: Int? = nil,
         hasConflict: Bool = false) {
        self.id = id
        self.address = address
        self.label = label
        self.notes = notes
        self.stopType = stopType
        self.searchQuery = searchQuery
        self.openTime = openTime
        self.closeTime = closeTime
        self.dwellMinutes = dwellMinutes
        self.estimatedArrival = estimatedArrival
        self.driveMinutesFromPrev = driveMinutesFromPrev
        self.hasConflict = hasConflict
    }

    var isSearch: Bool { stopType == "search" }
    var hasTimeWindow: Bool { openTime != nil || closeTime != nil }
    var displayName: String { label ?? address }
}

/// Route-level preferences extracted from user intent.
struct RoutePreferences: Codable {
    var scenic: Bool = false
    var avoidHighways: Bool = false
    var avoidTolls: Bool = false
    var avoidFerries: Bool = false
    var preferenceNotes: String?
}

struct ParsedRoute: Codable {
    var origin: String?
    var stops: [RouteStop]
    var preferences: RoutePreferences?
    var notes: String?
}

// MARK: - Tesla Models

struct TeslaVehicle: Identifiable, Codable {
    let id: String
    let displayName: String
    let vin: String
    let state: String  // "online", "asleep", "offline"

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case vin
        case state
    }

    var isOnline: Bool { state == "online" }
}

struct TeslaVehiclesResponse: Codable {
    let response: [TeslaVehicle]
}

// MARK: - Claude API Models

struct ClaudeMessage: Codable {
    let role: String
    let content: String
}

struct ClaudeRequest: Codable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [ClaudeMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

struct ClaudeResponse: Codable {
    struct Content: Codable {
        let type: String
        let text: String
    }
    let content: [Content]
}

// MARK: - App Settings

struct AppSettings: Codable {
    var claudeApiKey: String = ""
    var googleMapsApiKey: String = ""
    var teslaAccessToken: String = ""
    var backendUrl: String = "http://localhost:8000"
    var defaultDwellMinutes: Int = 20
    var trafficModel: String = "best_guess"
    var avoidTolls: Bool = false

    static var current: AppSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "app_settings"),
                  let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
            else { return AppSettings() }
            return settings
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "app_settings")
            }
        }
    }
}
