import EventKit

@MainActor
class CalendarService: ObservableObject {
    @Published var upcomingEvents: [CalendarEvent] = []
    @Published var accessGranted = false
    @Published var calendarNames: [String] = []

    private let store = EKEventStore()

    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            accessGranted = granted
            if granted {
                loadCalendarNames()
                fetchUpcoming()
            }
        } catch {
            accessGranted = false
        }
    }

    private func loadCalendarNames() {
        let calendars = store.calendars(for: .event)
        calendarNames = calendars.map { "\($0.title) (\($0.source.title))" }
    }

    func fetchUpcoming() {
        guard accessGranted else { return }

        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 48, to: now)!

        // Only include personal calendars (iCloud, Google, Local) — skip Exchange/Office 365 (work)
        let allCalendars = store.calendars(for: .event)
        let personalCalendars = allCalendars.filter { cal in
            let sourceType = cal.source.sourceType
            // Exclude Exchange (work) calendars
            return sourceType != .exchange
        }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: personalCalendars.isEmpty ? allCalendars : personalCalendars)
        let ekEvents = store.events(matching: predicate)

        upcomingEvents = ekEvents.compactMap { event in
            let location = extractLocation(from: event)
            guard let location, !location.isEmpty else { return nil }
            return CalendarEvent(
                title: event.title ?? "Event",
                location: location,
                startDate: event.startDate
            )
        }
    }

    /// Extract location from various fields — Exchange/O365 calendars
    /// store locations differently than Google Calendar.
    private func extractLocation(from event: EKEvent) -> String? {
        // 1. Structured location (best — has coordinates)
        if let structured = event.structuredLocation?.title, !structured.isEmpty {
            return structured
        }

        // 2. Plain location string
        if let loc = event.location, !loc.isEmpty {
            // Exchange often puts "Microsoft Teams Meeting" or join URLs here — skip those
            let lower = loc.lowercased()
            if lower.contains("teams meeting") || lower.contains("zoom.us") ||
               lower.contains("webex") || lower.contains("meet.google") ||
               lower.hasPrefix("http") {
                return nil
            }
            return loc
        }

        // 3. Check notes for address patterns (Exchange sometimes puts location in notes)
        if let notes = event.notes, !notes.isEmpty {
            // Look for a line that looks like an address (contains a number + street name)
            let lines = notes.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 10, trimmed.count < 200,
                   trimmed.range(of: #"\d+\s+\w+"#, options: .regularExpression) != nil,
                   !trimmed.lowercased().contains("http"),
                   !trimmed.lowercased().contains("dial") {
                    return trimmed
                }
            }
        }

        return nil
    }
}
