import Foundation

// MARK: - Route Models

/// A stop can be a specific address ("123 Main St") or a search query ("Starbucks on the way").
/// The backend resolves search-type stops via Google Places API.
struct RouteStop: Identifiable, Codable, Equatable {
    let id: UUID
    var address: String
    var label: String?
    var notes: String?
    var stopType: String?
    var searchQuery: String?
    var openTime: String?
    var closeTime: String?
    var dwellMinutes: Int
    var estimatedArrival: String?
    var driveMinutesFromPrev: Int?
    var hasConflict: Bool
    var latitude: Double?
    var longitude: Double?
    var distanceMeters: Int?

    init(id: UUID = UUID(), address: String, label: String? = nil,
         notes: String? = nil, stopType: String? = "specific",
         searchQuery: String? = nil, openTime: String? = nil,
         closeTime: String? = nil, dwellMinutes: Int = 20,
         estimatedArrival: String? = nil, driveMinutesFromPrev: Int? = nil,
         hasConflict: Bool = false, latitude: Double? = nil,
         longitude: Double? = nil, distanceMeters: Int? = nil) {
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
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
    }

    // Custom decoder to handle Claude returning int/string IDs and null for non-optional fields
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // id: accept UUID string, plain string, int, or generate one
        if let uuidStr = try? c.decode(String.self, forKey: .id), let uuid = UUID(uuidString: uuidStr) {
            self.id = uuid
        } else {
            self.id = UUID()
        }

        self.address = (try? c.decode(String.self, forKey: .address)) ?? ""
        self.label = try? c.decode(String.self, forKey: .label)
        self.notes = try? c.decode(String.self, forKey: .notes)
        self.stopType = try? c.decode(String.self, forKey: .stopType)
        self.searchQuery = try? c.decode(String.self, forKey: .searchQuery)
        self.openTime = try? c.decode(String.self, forKey: .openTime)
        self.closeTime = try? c.decode(String.self, forKey: .closeTime)
        self.dwellMinutes = (try? c.decode(Int.self, forKey: .dwellMinutes)) ?? 20
        self.estimatedArrival = try? c.decode(String.self, forKey: .estimatedArrival)
        self.driveMinutesFromPrev = try? c.decode(Int.self, forKey: .driveMinutesFromPrev)
        self.hasConflict = (try? c.decode(Bool.self, forKey: .hasConflict)) ?? false
        self.latitude = try? c.decode(Double.self, forKey: .latitude)
        self.longitude = try? c.decode(Double.self, forKey: .longitude)
        self.distanceMeters = try? c.decode(Int.self, forKey: .distanceMeters)
    }

    private enum CodingKeys: String, CodingKey {
        case id, address, label, notes, stopType, searchQuery
        case openTime, closeTime, dwellMinutes, estimatedArrival
        case driveMinutesFromPrev, hasConflict, latitude, longitude, distanceMeters
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
    let id: Int
    let displayName: String
    let vin: String
    let state: String  // "online", "asleep", "offline"
    let optionCodes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case vin
        case state
        case optionCodes = "option_codes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intId = try? c.decode(Int.self, forKey: .id) {
            self.id = intId
        } else if let strId = try? c.decode(String.self, forKey: .id), let parsed = Int(strId) {
            self.id = parsed
        } else {
            self.id = 0
        }
        self.displayName = (try? c.decode(String.self, forKey: .displayName)) ?? "Tesla"
        self.vin = (try? c.decode(String.self, forKey: .vin)) ?? ""
        self.state = (try? c.decode(String.self, forKey: .state)) ?? "offline"
        self.optionCodes = try? c.decode(String.self, forKey: .optionCodes)
    }

    var isOnline: Bool { state == "online" }
    var idString: String { String(id) }

    /// Model code derived from VIN (position 4)
    var modelCode: String {
        guard vin.count >= 4 else { return "m3" }
        let ch = vin[vin.index(vin.startIndex, offsetBy: 3)]
        switch ch {
        case "S", "s": return "ms"
        case "X", "x": return "mx"
        case "3": return "m3"
        case "Y", "y": return "my"
        default: return "m3"
        }
    }

    /// Tesla compositor URL for the exact vehicle image (model, color, wheels)
    func imageURL(paintCode: String? = nil) -> URL? {
        if let codes = optionCodes, !codes.isEmpty {
            let urlStr = "https://static-assets.tesla.com/configurator/compositor?model=\(modelCode)&view=STUD_3QTR&size=400&options=\(codes)&bkba_opt=1"
            return URL(string: urlStr)
        }
        // Use paint code from vehicle status, or default
        let paint = paintCode ?? "PMNG"
        let wheels = modelCode == "my" ? "W40B" : "W38B"
        let urlStr = "https://static-assets.tesla.com/configurator/compositor?model=\(modelCode)&view=STUD_3QTR&size=400&options=\(paint),\(wheels),IBB1&bkba_opt=1"
        return URL(string: urlStr)
    }
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

// MARK: - Vehicle Status

struct VehicleStatusData: Codable {
    var batteryLevel: Int       // 0-100
    var batteryRange: Double    // miles
    var isClimateOn: Bool
    var interiorTemp: Double?   // celsius
    var exteriorTemp: Double?   // celsius
    var locked: Bool
    var sentryMode: Bool
    var exteriorColor: String?  // e.g. "Red", "Blue", "White"
    var paintColor: String?     // paint code if available

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batteryLevel = (try? c.decode(Int.self, forKey: .batteryLevel)) ?? 0
        batteryRange = (try? c.decode(Double.self, forKey: .batteryRange)) ?? 0
        isClimateOn = (try? c.decode(Bool.self, forKey: .isClimateOn)) ?? false
        interiorTemp = try? c.decode(Double.self, forKey: .interiorTemp)
        exteriorTemp = try? c.decode(Double.self, forKey: .exteriorTemp)
        locked = (try? c.decode(Bool.self, forKey: .locked)) ?? true
        sentryMode = (try? c.decode(Bool.self, forKey: .sentryMode)) ?? false
        exteriorColor = try? c.decode(String.self, forKey: .exteriorColor)
        paintColor = try? c.decode(String.self, forKey: .paintColor)
    }

    enum CodingKeys: String, CodingKey {
        case batteryLevel = "battery_level"
        case batteryRange = "battery_range"
        case isClimateOn = "is_climate_on"
        case interiorTemp = "interior_temp"
        case exteriorTemp = "exterior_temp"
        case locked
        case sentryMode = "sentry_mode"
        case exteriorColor = "exterior_color"
        case paintColor = "paint_color"
    }

    /// Map exterior color name to Tesla compositor paint option code
    var paintOptionCode: String? {
        if let pc = paintColor, !pc.isEmpty { return pc }
        guard let color = exteriorColor?.lowercased() else { return nil }
        switch color {
        case let c where c.contains("red"): return "PPMR"
        case let c where c.contains("blue"): return "PPSB"
        case let c where c.contains("white"): return "PPSW"
        case let c where c.contains("black"): return "PBSB"
        case let c where c.contains("silver"), let c where c.contains("midnight"): return "PMNG"
        case let c where c.contains("gray"), let c where c.contains("grey"): return "PMNG"
        case let c where c.contains("pearl"): return "PPSW"
        case let c where c.contains("quicksilver"): return "PQS0"
        case let c where c.contains("ultra white"): return "PU01"
        default: return nil
        }
    }
}

// MARK: - Calendar & Contacts

struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let location: String
    let startDate: Date
}

struct ContactAddress: Identifiable {
    let id = UUID()
    let name: String
    let address: String
}

// MARK: - Saved Locations

struct SavedLocation: Codable, Identifiable {
    let id: UUID
    var name: String
    var address: String

    init(id: UUID = UUID(), name: String = "", address: String = "") {
        self.id = id
        self.name = name
        self.address = address
    }
}

// MARK: - App Settings

struct AppSettings: Codable {
    var claudeApiKey: String = ""
    var googleMapsApiKey: String = ""
    var teslaAccessToken: String = ""
    var teslaRefreshToken: String = ""
    var backendUrl: String = "http://localhost:8000"
    var defaultDwellMinutes: Int = 20
    var trafficModel: String = "best_guess"
    var avoidTolls: Bool = false
    var homeAddress: String = ""
    var workAddress: String = ""
    var favorites: [SavedLocation] = []
    var calendarEnabled: Bool = true
    var contactsEnabled: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeApiKey = (try? c.decode(String.self, forKey: .claudeApiKey)) ?? ""
        googleMapsApiKey = (try? c.decode(String.self, forKey: .googleMapsApiKey)) ?? ""
        teslaAccessToken = (try? c.decode(String.self, forKey: .teslaAccessToken)) ?? ""
        teslaRefreshToken = (try? c.decode(String.self, forKey: .teslaRefreshToken)) ?? ""
        backendUrl = (try? c.decode(String.self, forKey: .backendUrl)) ?? "http://localhost:8000"
        defaultDwellMinutes = (try? c.decode(Int.self, forKey: .defaultDwellMinutes)) ?? 20
        trafficModel = (try? c.decode(String.self, forKey: .trafficModel)) ?? "best_guess"
        avoidTolls = (try? c.decode(Bool.self, forKey: .avoidTolls)) ?? false
        homeAddress = (try? c.decode(String.self, forKey: .homeAddress)) ?? ""
        workAddress = (try? c.decode(String.self, forKey: .workAddress)) ?? ""
        favorites = (try? c.decode([SavedLocation].self, forKey: .favorites)) ?? []
        calendarEnabled = (try? c.decode(Bool.self, forKey: .calendarEnabled)) ?? true
        contactsEnabled = (try? c.decode(Bool.self, forKey: .contactsEnabled)) ?? true
    }

    /// All saved locations with addresses set, for display and LLM context.
    var allSavedLocations: [(name: String, address: String, icon: String)] {
        var locs: [(String, String, String)] = []
        if !homeAddress.isEmpty { locs.append(("Home", homeAddress, "house.fill")) }
        if !workAddress.isEmpty { locs.append(("Work", workAddress, "briefcase.fill")) }
        for fav in favorites where !fav.address.isEmpty {
            locs.append((fav.name.isEmpty ? "Favorite" : fav.name, fav.address, "star.fill"))
        }
        return locs
    }

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
