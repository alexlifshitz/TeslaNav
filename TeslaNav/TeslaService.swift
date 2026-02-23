import Foundation

struct ResolvedRoute {
    let stops: [RouteStop]
    let totalDriveMin: Int?
}

class TeslaService: ObservableObject {
    @Published var vehicles: [TeslaVehicle] = []
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
        ["Authorization": "Bearer \(AppSettings.current.teslaAccessToken)",
         "Content-Type": "application/json"]
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(backendURL())\(path)")!)
        req.httpMethod = method
        authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = body
        return req
    }

    // MARK: - Load Vehicles

    func loadVehicles() async {
        await MainActor.run { isLoading = true; lastError = nil }

        do {
            let req = request(path: "/vehicles")
            let (data, _) = try await Self.session.data(for: req)
            let response = try JSONDecoder().decode(TeslaVehiclesResponse.self, from: data)

            await MainActor.run {
                self.vehicles = response.response
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    // MARK: - Wake Vehicle

    func wakeVehicle(_ vehicleId: String) async throws {
        let req = request(path: "/vehicles/\(vehicleId)/wake", method: "POST")
        let (data, _) = try await Self.session.data(for: req)

        struct WakeResp: Codable { struct R: Codable { let state: String }; let response: R }
        let resp = try JSONDecoder().decode(WakeResp.self, from: data)

        if resp.response.state != "online" {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: - Send Navigation

    func sendRoute(_ stops: [RouteStop], to vehicleId: String) async throws {
        guard !stops.isEmpty else { return }

        let body = ["stops": stops.map { $0.address }]
        let bodyData = try JSONEncoder().encode(body)
        let req = request(path: "/vehicles/\(vehicleId)/navigate", method: "POST", body: bodyData)

        let (data, resp) = try await Self.session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Failed"
            throw TeslaError.commandFailed(msg)
        }
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

            enum CodingKeys: String, CodingKey {
                case totalDurationMin = "total_duration_min"
            }
        }
        struct RouteResponse: Codable {
            let stops: [RouteStop]
            let directions: DirectionsInfo?
        }

        let result = try JSONDecoder().decode(RouteResponse.self, from: data)
        return ResolvedRoute(
            stops: result.stops,
            totalDriveMin: result.directions?.totalDurationMin
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
