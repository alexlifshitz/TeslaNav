import Foundation
import SwiftUI

struct SendStatus {
    let success: Bool
    let message: String
}

@MainActor
class RouteViewModel: ObservableObject {
    @Published var promptText: String = ""
    @Published var stops: [RouteStop] = []
    @Published var origin: String? = nil
    @Published var preferences: RoutePreferences? = nil
    @Published var totalDriveMin: Int? = nil
    @Published var isOptimizing = false
    @Published var isSending = false
    @Published var errorMessage: String? = nil
    @Published var selectedVehicleIds: Set<Int> = []
    @Published var sendStatus: [Int: SendStatus] = [:]
    @Published var isResolving = false
    @Published var totalDistanceKm: Double? = nil
    @Published var rangeWarning: String? = nil
    @Published var isClimateActivating = false
    @Published var climateStatus: String? = nil

    private let llm = LLMService()

    // MARK: - Parse Prompt + Resolve + Optimize

    func parseAndOptimize(
        calendarEvents: [CalendarEvent] = [],
        contactAddresses: [ContactAddress] = []
    ) async {
        guard !promptText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isOptimizing = true
        errorMessage = nil
        stops = []
        preferences = nil
        totalDriveMin = nil
        totalDistanceKm = nil
        rangeWarning = nil
        sendStatus = [:]

        let settings = AppSettings.current

        do {
            // 1. Claude parses free-form text → structured stops + preferences
            let saved = settings.allSavedLocations.map { (name: $0.name, address: $0.address) }
            let parsed = try await llm.parsePrompt(
                promptText,
                apiKey: settings.claudeApiKey,
                savedLocations: saved,
                calendarEvents: calendarEvents,
                contactAddresses: contactAddresses
            )
            origin = parsed.origin
            preferences = parsed.preferences

            guard !parsed.stops.isEmpty else {
                errorMessage = parsed.notes ?? "No destinations found"
                isOptimizing = false
                return
            }

            // Show Claude-parsed stops immediately
            self.stops = parsed.stops
            isOptimizing = false

            // 2. Backend resolves search-type stops (Places API) + gets directions
            let needsBackend = parsed.stops.contains { $0.isSearch }
                || parsed.preferences?.scenic == true
                || parsed.preferences?.avoidHighways == true
                || parsed.preferences?.avoidTolls == true
                || parsed.preferences?.avoidFerries == true
                || parsed.stops.count > 1

            if needsBackend && !settings.backendUrl.isEmpty {
                isResolving = true
                let tesla = TeslaService()
                let result = try await tesla.resolveRoute(
                    parsed.stops,
                    origin: parsed.origin,
                    preferences: parsed.preferences
                )
                self.stops = result.stops
                self.totalDriveMin = result.totalDriveMin
                self.totalDistanceKm = result.totalDistanceKm
                isResolving = false
            }

        } catch {
            if stops.isEmpty {
                errorMessage = error.localizedDescription
            }
            isOptimizing = false
            isResolving = false
        }
    }

    // MARK: - Vehicle Selection

    func toggleVehicle(_ id: Int) {
        if selectedVehicleIds.contains(id) {
            selectedVehicleIds.remove(id)
        } else {
            selectedVehicleIds.insert(id)
        }
    }

    // MARK: - Send to Tesla

    func sendToSelectedVehicles(tesla: TeslaService) async {
        guard !stops.isEmpty, !selectedVehicleIds.isEmpty else { return }
        isSending = true
        sendStatus = [:]

        let currentStops = stops
        let vehicleIds = selectedVehicleIds
        let vehicles = tesla.vehicles

        for vehicleId in vehicleIds {
            let vehicle = vehicles.first { $0.id == vehicleId }
            let name = vehicle?.displayName ?? String(vehicleId)
            let idStr = String(vehicleId)

            do {
                if vehicle?.isOnline == false {
                    try await tesla.wakeVehicle(idStr)
                }
                try await tesla.sendRoute(currentStops, to: idStr)
                sendStatus[vehicleId] = SendStatus(success: true, message: "Route sent to \(name)")
            } catch {
                sendStatus[vehicleId] = SendStatus(success: false, message: "\(name): \(error.localizedDescription)")
            }
        }

        isSending = false
    }

    // MARK: - Optimize Stop Order

    func optimizeOrder(tesla: TeslaService) async {
        guard stops.count >= 3 else { return }
        isResolving = true
        do {
            let optimized = try await tesla.optimizeStopOrder(stops, origin: origin)
            self.stops = optimized
        } catch {
            errorMessage = "Optimize failed: \(error.localizedDescription)"
        }
        isResolving = false
    }

    // MARK: - Battery Range Check

    func checkBatteryRange(tesla: TeslaService) {
        guard let distKm = totalDistanceKm, distKm > 0 else {
            rangeWarning = nil
            return
        }

        // Check all selected vehicles
        for vehicleId in selectedVehicleIds {
            if let status = tesla.vehicleStatus[vehicleId] {
                let rangeKm = status.batteryRange * 1.60934 // miles → km
                if distKm > rangeKm * 0.9 { // warn at 90% of range
                    let vehicle = tesla.vehicles.first { $0.id == vehicleId }
                    rangeWarning = "\(vehicle?.displayName ?? "Vehicle") may not have enough range (\(Int(rangeKm)) km) for this \(Int(distKm)) km route"
                    return
                }
            }
        }
        rangeWarning = nil
    }

    // MARK: - Climate Control

    /// Pick a comfortable cabin target based on the car's interior temp.
    private func suggestedTempC(interiorC: Double?) -> Double {
        guard let inside = interiorC else { return 21.0 }
        if inside < 5 { return 23.0 }       // freezing cabin → heat up
        if inside < 15 { return 22.0 }       // cold cabin → warm
        if inside < 20 { return 21.0 }       // cool cabin → mild
        if inside >= 20, inside <= 24 { return 21.0 } // already comfortable
        if inside < 32 { return 20.0 }       // warm cabin → cool down
        return 19.0                           // hot cabin → max cool
    }

    func activateClimate(tesla: TeslaService) async {
        guard !selectedVehicleIds.isEmpty else { return }
        isClimateActivating = true
        climateStatus = nil
        var successes = 0
        var statusMessages: [String] = []

        var lastError: String?
        for vehicleId in selectedVehicleIds {
            let idStr = String(vehicleId)
            do {
                // Wake first — backend polls until online (up to ~30s)
                try await tesla.wakeVehicle(idStr)

                // Refresh vehicle data to get current interior temp
                await tesla.loadVehicleData(idStr)
                let status = tesla.vehicleStatus[vehicleId]
                let interiorC = status?.interiorTemp
                let tempC = suggestedTempC(interiorC: interiorC)
                let tempF = Int(tempC * 9.0 / 5.0 + 32.0)

                // Skip if cabin is already comfortable (19-24°C)
                if let inside = interiorC, inside >= 19, inside <= 24 {
                    let insideF = Int(inside * 9.0 / 5.0 + 32.0)
                    statusMessages.append("Already \(insideF)°F — no action needed")
                    successes += 1
                    continue
                }

                try await tesla.setClimate(idStr, on: true, tempC: tempC)
                successes += 1
                if let inside = interiorC {
                    let insideF = Int(inside * 9.0 / 5.0 + 32.0)
                    statusMessages.append("Cabin \(insideF)°F → setting to \(tempF)°F")
                } else {
                    statusMessages.append("Climate on → \(tempF)°F")
                }
            } catch {
                lastError = "Vehicle \(idStr): \(error.localizedDescription)"
            }
        }

        if successes > 0 {
            climateStatus = statusMessages.joined(separator: " | ")
        } else {
            climateStatus = "Climate failed: \(lastError ?? "unknown error")"
        }
        isClimateActivating = false
    }

    func clearRoute() {
        stops = []
        origin = nil
        preferences = nil
        totalDriveMin = nil
        totalDistanceKm = nil
        rangeWarning = nil
        errorMessage = nil
        sendStatus = [:]
        climateStatus = nil
        isResolving = false
    }
}
