import Foundation

struct ResolvedRoute {
    let stops: [RouteStop]
    let totalDriveMin: Int?
    let totalDistanceKm: Double?
}

@MainActor
class TeslaService: ObservableObject {
    @Published var vehicles: [TeslaVehicle] = []
    @Published var vehicleStatus: [Int: VehicleStatusData] = [:]
    @Published var isLoading = false
    @Published var lastError: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func backendURL() -> String {
        AppSettings.current.backendUrl
    }

    private func authHeaders() -> [String: String] {
        let settings = AppSettings.current
        var h = ["Authorization": "Bearer \(settings.teslaAccessToken)",
                 "Content-Type": "application/json"]
        let gmKey = settings.googleMapsApiKey
        if !gmKey.isEmpty { h["X-Google-Maps-Key"] = gmKey }
        let rt = settings.teslaRefreshToken
        if !rt.isEmpty { h["X-Refresh-Token"] = rt }
        return h
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(backendURL())\(path)")!)
        req.httpMethod = method
        authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = body
        return req
    }

    /// Check response for refreshed token and update settings if present.
    private func handleTokenRefresh(_ response: URLResponse) {
        if let http = response as? HTTPURLResponse,
           let newToken = http.value(forHTTPHeaderField: "X-New-Access-Token") {
            var settings = AppSettings.current
            settings.teslaAccessToken = newToken
            if let newRefresh = http.value(forHTTPHeaderField: "X-New-Refresh-Token") {
                settings.teslaRefreshToken = newRefresh
            }
            AppSettings.current = settings
        }
    }

    // MARK: - Load Vehicles

    func loadVehicles() async {
        isLoading = true
        lastError = nil

        do {
            let req = request(path: "/vehicles")
            let (data, resp) = try await Self.session.data(for: req)
            handleTokenRefresh(resp)
            let response = try JSONDecoder().decode(TeslaVehiclesResponse.self, from: data)
            vehicles = response.response
            isLoading = false
            await loadAllVehicleData()
        } catch {
            lastError = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Wake Vehicle

    func wakeVehicle(_ vehicleId: String) async throws {
        var req = request(path: "/vehicles/\(vehicleId)/wake", method: "POST")
        req.timeoutInterval = 45
        let (data, resp) = try await Self.session.data(for: req)
        handleTokenRefresh(resp)

        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Wake failed"
            throw TeslaError.commandFailed(msg)
        }
    }

    // MARK: - Send Navigation

    func sendRoute(_ stops: [RouteStop], to vehicleId: String) async throws {
        guard !stops.isEmpty else { return }

        let body = ["stops": stops.map { $0.address }]
        let bodyData = try JSONEncoder().encode(body)
        let req = request(path: "/vehicles/\(vehicleId)/navigate", method: "POST", body: bodyData)

        let (data, resp) = try await Self.session.data(for: req)
        handleTokenRefresh(resp)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Failed"
            throw TeslaError.commandFailed(msg)
        }
    }

    // MARK: - Vehicle Data

    func loadVehicleData(_ vehicleId: String) async {
        do {
            let req = request(path: "/vehicles/\(vehicleId)/vehicle_data")
            let (data, resp) = try await Self.session.data(for: req)
            handleTokenRefresh(resp)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

            // Vehicle might be asleep (408) — try waking it
            if code == 408 {
                try? await wakeVehicle(vehicleId)
                let retryReq = request(path: "/vehicles/\(vehicleId)/vehicle_data")
                let (retryData, retryResp) = try await Self.session.data(for: retryReq)
                handleTokenRefresh(retryResp)
                guard (retryResp as? HTTPURLResponse)?.statusCode == 200 else { return }
                let status = try JSONDecoder().decode(VehicleStatusData.self, from: retryData)
                if let id = Int(vehicleId) { vehicleStatus[id] = status }
                return
            }

            guard code == 200 else { return }
            let status = try JSONDecoder().decode(VehicleStatusData.self, from: data)
            if let id = Int(vehicleId) { vehicleStatus[id] = status }
        } catch { /* status is optional */ }
    }

    func loadAllVehicleData() async {
        for vehicle in vehicles {
            await loadVehicleData(vehicle.idString)
        }
    }

    // MARK: - Climate Control

    func setClimate(_ vehicleId: String, on: Bool, tempC: Double? = nil) async throws {
        struct ClimateBody: Codable {
            let on: Bool
            let temp_c: Double?
        }
        let body = ClimateBody(on: on, temp_c: tempC)
        let bodyData = try JSONEncoder().encode(body)
        let req = request(path: "/vehicles/\(vehicleId)/command/climate", method: "POST", body: bodyData)
        let (data, resp) = try await Self.session.data(for: req)
        handleTokenRefresh(resp)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Climate command failed"
            throw TeslaError.commandFailed(msg)
        }
    }

    // MARK: - Optimize Stop Order

    func optimizeStopOrder(_ stops: [RouteStop], origin: String?) async throws -> [RouteStop] {
        struct OptBody: Codable { let origin: String?; let stops: [RouteStop] }
        let body = OptBody(origin: origin, stops: stops)
        let bodyData = try JSONEncoder().encode(body)
        let req = request(path: "/route/optimize-order", method: "POST", body: bodyData)
        let (data, _) = try await Self.session.data(for: req)
        struct OptResponse: Codable { let stops: [RouteStop] }
        let result = try JSONDecoder().decode(OptResponse.self, from: data)
        return result.stops
    }

    // MARK: - Resolve Route (Places + Directions + Preferences)

    func resolveRoute(
        _ stops: [RouteStop],
        origin: String?,
        preferences: RoutePreferences?
    ) async throws -> ResolvedRoute {
        struct RouteRequestBody: Codable {
            let origin: String?
            let stops: [RouteStop]
            let preferences: RoutePreferences?
        }

        let body = RouteRequestBody(origin: origin, stops: stops, preferences: preferences)
        let bodyData = try JSONEncoder().encode(body)
        let req = request(path: "/route", method: "POST", body: bodyData)

        let (data, _) = try await Self.session.data(for: req)

        struct DirectionsInfo: Codable {
            let totalDurationMin: Int?
            let totalDistanceKm: Double?

            enum CodingKeys: String, CodingKey {
                case totalDurationMin = "total_duration_min"
                case totalDistanceKm = "total_distance_km"
            }
        }
        struct RouteResponse: Codable {
            let stops: [RouteStop]
            let directions: DirectionsInfo?
        }

        let result = try JSONDecoder().decode(RouteResponse.self, from: data)
        return ResolvedRoute(
            stops: result.stops,
            totalDriveMin: result.directions?.totalDurationMin,
            totalDistanceKm: result.directions?.totalDistanceKm
        )
    }

    enum TeslaError: LocalizedError {
        case commandFailed(String)
        var errorDescription: String? {
            if case .commandFailed(let msg) = self { return msg }
            return "Tesla command failed"
        }
    }
}
