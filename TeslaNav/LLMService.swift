import Foundation

final class LLMService: Sendable {
    private let baseURL = "https://api.anthropic.com/v1/messages"

    static let systemPrompt = """
    You are a vehicle navigation assistant. The user will describe where they want to drive — \
    destinations, errands, stops along the way, route preferences, or any combination.

    Return a JSON object with this exact structure:
    {
      "origin": "starting address or null",
      "stops": [
        {
          "id": "unique-uuid",
          "address": "full street address if known, or best description",
          "label": "short display name (e.g. Costco, Home, Airport)",
          "notes": "user context about this stop, or null",
          "stopType": "specific or search",
          "searchQuery": "what to search for if stopType is search, or null",
          "openTime": "HH:MM 24h if time constraint mentioned, or null",
          "closeTime": "HH:MM 24h if time constraint mentioned, or null",
          "dwellMinutes": 20,
          "estimatedArrival": null,
          "driveMinutesFromPrev": null,
          "hasConflict": false
        }
      ],
      "preferences": {
        "scenic": false,
        "avoidHighways": false,
        "avoidTolls": false,
        "avoidFerries": false,
        "preferenceNotes": "any route preference context, or null"
      },
      "notes": "any warnings, or null"
    }

    Stop types:
    - "specific": user gave an exact address or well-known named location you can geocode \
    (e.g. "Tesla HQ", "123 Main St", "SFO airport"). Set address to the full geocodable address.
    - "search": user wants a type of place along the route, not a specific one \
    (e.g. "stop at a Starbucks", "get gas", "find a good lunch spot"). \
    Set searchQuery to the search term (e.g. "Starbucks", "gas station", "restaurant"). \
    Set address to the searchQuery as a placeholder — the backend will resolve the actual location.

    Route preferences:
    - "scenic route" / "take the scenic way" → scenic: true, avoidHighways: true
    - "avoid tolls" → avoidTolls: true
    - "take the highway" / "fastest route" → all false (defaults)
    - "avoid the freeway" → avoidHighways: true
    - Any other route context → put in preferenceNotes

    Saved places:
    - The user may have saved locations (Home, Work, favorites). These will be provided below.
    - When the user says "home", "my house", "take me home" → use their saved Home address.
    - When the user says "work", "the office", "go to work" → use their saved Work address.
    - When the user mentions a saved favorite by name → use that saved address.
    - For saved places, set stopType to "specific" and use the saved address.

    Parsing comma-separated input:
    - Users often type multiple addresses separated by commas, e.g. "123 Main St, SF, 456 Oak Ave, LA"
    - A full US address typically follows the pattern: street, city, state/ZIP — these commas are PART of the address, not separators between stops
    - To split correctly: look for street number or place name patterns that signal a NEW stop
    - Example: "123 Main St, San Francisco, CA, 456 Oak Ave, Los Angeles, CA" → TWO stops:
      1. "123 Main St, San Francisco, CA"
      2. "456 Oak Ave, Los Angeles, CA"
    - Example: "Costco, Trader Joe's, Home Depot" → THREE stops (each is a place name, comma separates them)
    - Example: "1600 Amphitheatre Parkway, Mountain View, CA 94043, 1 Apple Park Way, Cupertino, CA" → TWO stops
    - When in doubt, treat a comma followed by a street number (digits) or well-known place name as a new stop
    - Never split a "street, city, state" address into multiple stops
    - "then" is also a separator between stops, e.g. "A, then B, then C" → three stops

    Parsing time windows:
    - Input like "(1:30 PM-4:00 PM)" or "(2:00 PM - 5:00 PM)" means a time window for that stop
    - Convert to 24h format: openTime = start time, closeTime = end time
    - Example: "(1:30 PM-4:00 PM)" → openTime: "13:30", closeTime: "16:00"
    - Example: "(2:00 PM-5:00 PM)" → openTime: "14:00", closeTime: "17:00"
    - The time window is NOT part of the address — strip it from the address field

    Rules:
    - Preserve the user's intended stop order
    - Make addresses as complete as possible (city, state, ZIP when inferrable)
    - label = shortest recognizable name
    - dwellMinutes: default 20, "quick stop" → 5, "grab coffee" → 10, "lunch" → 45
    - Return ONLY valid JSON, no markdown, no explanation
    - If nothing found: {"origin": null, "stops": [], "preferences": null, "notes": "No destinations found"}
    """

    func parsePrompt(
        _ prompt: String,
        apiKey: String,
        savedLocations: [(name: String, address: String)] = [],
        calendarEvents: [CalendarEvent] = [],
        contactAddresses: [ContactAddress] = []
    ) async throws -> ParsedRoute {
        guard !apiKey.isEmpty else { throw LLMError.noApiKey }

        var system = LLMService.systemPrompt
        if !savedLocations.isEmpty {
            let places = savedLocations.map { "\($0.name): \($0.address)" }.joined(separator: "\n")
            system += "\n\nUser's saved places:\n\(places)"
        }

        if !calendarEvents.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE h:mm a"
            let events = calendarEvents.prefix(5).map { "\($0.title) at \(formatter.string(from: $0.startDate)): \($0.location)" }.joined(separator: "\n")
            system += "\n\nUpcoming calendar events (use these locations when user mentions events like \"my meeting\", \"dentist\", \"appointment\", etc.):\n\(events)"
        }

        if !contactAddresses.isEmpty {
            let contacts = contactAddresses.prefix(10).map { "\($0.name): \($0.address)" }.joined(separator: "\n")
            system += "\n\nUser's contacts with addresses (use when user mentions a person's name):\n\(contacts)"
        }

        let request = ClaudeRequest(
            model: "claude-haiku-4-5-20251001",
            maxTokens: 4096,
            system: system,
            messages: [ClaudeMessage(role: "user", content: prompt)]
        )

        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, resp) = try await URLSession.shared.data(for: urlRequest)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.apiError(String(data: data, encoding: .utf8) ?? "Unknown")
        }

        let claude = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let text = claude.content.first?.text else { throw LLMError.emptyResponse }

        let json = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = json.data(using: .utf8) else { throw LLMError.parseError }
        return try JSONDecoder().decode(ParsedRoute.self, from: jsonData)
    }

    enum LLMError: LocalizedError {
        case noApiKey, apiError(String), emptyResponse, parseError
        var errorDescription: String? {
            switch self {
            case .noApiKey: return "No Claude API key — add one in Settings"
            case .apiError(let msg): return "API error: \(msg)"
            case .emptyResponse: return "Empty response from Claude"
            case .parseError: return "Could not parse response"
            }
        }
    }
}
