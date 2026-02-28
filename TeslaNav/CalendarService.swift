import EventKit

@MainActor
class CalendarService: ObservableObject {
    @Published var upcomingEvents: [CalendarEvent] = []
    @Published var accessGranted = false

    private let store = EKEventStore()

    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            accessGranted = granted
            if granted { fetchUpcoming() }
        } catch {
            accessGranted = false
        }
    }

    func fetchUpcoming() {
        guard accessGranted else { return }

        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 48, to: now)!
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let ekEvents = store.events(matching: predicate)

        upcomingEvents = ekEvents.compactMap { event in
            guard let location = event.structuredLocation?.title ?? event.location,
                  !location.isEmpty else { return nil }
            return CalendarEvent(
                title: event.title ?? "Event",
                location: location,
                startDate: event.startDate
            )
        }
    }
}
