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
    @Published var selectedVehicleIds: Set<String> = []
    @Published var sendStatus: [String: SendStatus] = [:]

    private let llm = LLMService()

    // MARK: - Parse Prompt + Resolve + Optimize

    func parseAndOptimize() async {
        guard !promptText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isOptimizing = true
        errorMessage = nil
        stops = []
        preferences = nil
        totalDriveMin = nil
        sendStatus = [:]

        let settings = AppSettings.current

        do {
            // 1. Claude parses free-form text → structured stops + preferences
            let parsed = try await llm.parsePrompt(promptText, apiKey: settings.claudeApiKey)
            origin = parsed.origin
            preferences = parsed.preferences

            guard !parsed.stops.isEmpty else {
                errorMessage = parsed.notes ?? "No destinations found"
                isOptimizing = false
                return
            }

            // 2. Backend resolves search-type stops (Places API) + gets directions
            let needsBackend = parsed.stops.contains { $0.isSearch }
                || parsed.preferences?.scenic == true
                || parsed.preferences?.avoidHighways == true
                || parsed.preferences?.avoidTolls == true
                || parsed.preferences?.avoidFerries == true
                || parsed.stops.count > 1

            if needsBackend && !settings.backendUrl.isEmpty {
                let tesla = TeslaService()
                let result = try await tesla.resolveRoute(
                    parsed.stops,
                    origin: parsed.origin,
                    preferences: parsed.preferences
                )
                self.stops = result.stops
                self.totalDriveMin = result.totalDriveMin
            } else {
                // Single specific stop, no preferences — no backend needed
                self.stops = parsed.stops
            }

        } catch {
            errorMessage = error.localizedDescription
        }

        isOptimizing = false
    }

    // MARK: - Vehicle Selection

    func toggleVehicle(_ id: String) {
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

        await withTaskGroup(of: (String, SendStatus).self) { group in
            for vehicleId in selectedVehicleIds {
                group.addTask {
                    let vehicle = tesla.vehicles.first { $0.id == vehicleId }
                    let name = vehicle?.displayName ?? vehicleId

                    do {
                        if vehicle?.isOnline == false {
                            try await tesla.wakeVehicle(vehicleId)
                        }
                        try await tesla.sendRoute(self.stops, to: vehicleId)
                        return (vehicleId, SendStatus(success: true, message: "Route sent to \(name)"))
                    } catch {
                        return (vehicleId, SendStatus(success: false, message: "\(name): \(error.localizedDescription)"))
                    }
                }
            }

            for await (id, status) in group {
                await MainActor.run { self.sendStatus[id] = status }
            }
        }

        isSending = false
    }

    func clearRoute() {
        stops = []
        origin = nil
        preferences = nil
        totalDriveMin = nil
        errorMessage = nil
        sendStatus = [:]
    }
}
