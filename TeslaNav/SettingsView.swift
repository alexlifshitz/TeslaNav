import SwiftUI

struct SettingsView: View {
    @ObservedObject var tesla: TeslaService
    @Environment(\.dismiss) private var dismiss

    @State private var settings = AppSettings.current
    @State private var backendStatus: ConnectionStatus = .unknown
    @State private var teslaStatus: ConnectionStatus = .unknown
    @State private var claudeStatus: ConnectionStatus = .unknown
    @State private var googleStatus: ConnectionStatus = .unknown

    enum ConnectionStatus {
        case unknown, checking, connected, error(String)

        var color: Color {
            switch self {
            case .unknown: return .gray
            case .checking: return .yellow
            case .connected: return .green
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .unknown: return "circle"
            case .checking: return "arrow.trianglehead.2.clockwise"
            case .connected: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection Status
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("CONNECTION STATUS")

                        VStack(spacing: 0) {
                            StatusRow(label: "Backend", status: backendStatus, detail: settings.backendUrl)
                            Divider().background(Color(white: 0.15))
                            StatusRow(label: "Claude AI", status: claudeStatus,
                                      detail: settings.claudeApiKey.isEmpty ? "No key" : "Key set")
                            Divider().background(Color(white: 0.15))
                            StatusRow(label: "Tesla", status: teslaStatus,
                                      detail: settings.teslaAccessToken.isEmpty ? "No token" : "Token set")
                            Divider().background(Color(white: 0.15))
                            StatusRow(label: "Google Maps", status: googleStatus,
                                      detail: settings.googleMapsApiKey.isEmpty ? "No key" : "Key set")
                        }
                        .background(Color(white: 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button(action: testConnections) {
                            HStack {
                                Image(systemName: "bolt.fill")
                                Text("Test All Connections")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.yellow.opacity(0.15))
                            .foregroundColor(.yellow)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.3)))
                        }
                    }

                    // Backend URL
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("BACKEND")
                        apiField("https://your-backend.dev", text: $settings.backendUrl)
                    }

                    // Claude API Key
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("CLAUDE AI")
                        apiField("sk-ant-api03-...", text: $settings.claudeApiKey)

                        Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                            HStack {
                                Image(systemName: "key.fill")
                                Text("Get API Key from Anthropic Console")
                                    .font(.system(size: 13))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                            .foregroundColor(.yellow)
                            .padding(12)
                            .background(Color(white: 0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    // Tesla
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("TESLA")
                        apiField("Tesla access token", text: $settings.teslaAccessToken)

                        if !settings.backendUrl.isEmpty {
                            Link(destination: URL(string: "\(settings.backendUrl)/tesla/auth")!) {
                                HStack {
                                    Image(systemName: "car.fill")
                                    Text("Sign in with Tesla")
                                        .font(.system(size: 13))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 11))
                                        .foregroundColor(.gray)
                                }
                                .foregroundColor(.yellow)
                                .padding(12)
                                .background(Color(white: 0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }

                        Text("Sign in with Tesla to get a token, then paste it above.")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }

                    // Google Maps
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("GOOGLE MAPS (OPTIONAL)")
                        apiField("AIzaSy...", text: $settings.googleMapsApiKey)
                        Text("Needed for search stops (\"Starbucks on the way\") and drive times.")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }

                    // Saved Locations
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("SAVED LOCATIONS")

                        VStack(spacing: 0) {
                            // Home
                            HStack(spacing: 10) {
                                Image(systemName: "house.fill")
                                    .foregroundColor(.yellow)
                                    .frame(width: 22)
                                Text("Home")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 50, alignment: .leading)
                                TextField("Home address", text: $settings.homeAddress)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            .padding(12)

                            Divider().background(Color(white: 0.15))

                            // Work
                            HStack(spacing: 10) {
                                Image(systemName: "briefcase.fill")
                                    .foregroundColor(.yellow)
                                    .frame(width: 22)
                                Text("Work")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 50, alignment: .leading)
                                TextField("Work address", text: $settings.workAddress)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            .padding(12)

                            // Favorites
                            ForEach($settings.favorites) { $fav in
                                Divider().background(Color(white: 0.15))
                                HStack(spacing: 10) {
                                    Image(systemName: "star.fill")
                                        .foregroundColor(.yellow)
                                        .frame(width: 22)
                                    TextField("Name", text: $fav.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 50)
                                    TextField("Address", text: $fav.address)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.white)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)
                                    Button(action: {
                                        settings.favorites.removeAll { $0.id == fav.id }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(12)
                            }
                        }
                        .background(Color(white: 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button(action: {
                            settings.favorites.append(SavedLocation())
                        }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Favorite")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.yellow)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(white: 0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.2)))
                        }

                        Text("Say \"take me home\" or \"stop at work\" and the app will use these addresses.")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }

                    // Route Options
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("ROUTE OPTIONS")

                        VStack(spacing: 0) {
                            Stepper("Dwell time: \(settings.defaultDwellMinutes) min",
                                    value: $settings.defaultDwellMinutes, in: 5...90, step: 5)
                                .foregroundColor(.white)
                                .padding(12)

                            Divider().background(Color(white: 0.15))

                            Picker("Traffic model", selection: $settings.trafficModel) {
                                Text("Best guess").tag("best_guess")
                                Text("Pessimistic").tag("pessimistic")
                                Text("Optimistic").tag("optimistic")
                            }
                            .foregroundColor(.white)
                            .padding(12)

                            Divider().background(Color(white: 0.15))

                            Toggle("Avoid tolls", isOn: $settings.avoidTolls)
                                .tint(.yellow)
                                .foregroundColor(.white)
                                .padding(12)
                        }
                        .background(Color(white: 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        AppSettings.current = settings
                        let t = tesla
                        Task { await t.loadVehicles() }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.yellow)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.gray)
            .tracking(1.5)
    }

    private func apiField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(.white)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .textContentType(.none)
            .padding(14)
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(white: 0.2), lineWidth: 1)
            )
    }

    // MARK: - Connection Tests

    private func testConnections() {
        backendStatus = .checking
        teslaStatus = .checking
        claudeStatus = .checking
        googleStatus = settings.googleMapsApiKey.isEmpty ? .error("No key") : .checking
        AppSettings.current = settings

        Task {
            await testBackend()
            await testClaude()
            await testTesla()
            await testGoogle()
        }
    }

    private func testBackend() async {
        guard !settings.backendUrl.isEmpty else {
            backendStatus = .error("No URL")
            return
        }
        do {
            let url = URL(string: "\(settings.backendUrl)/health")!
            let (_, resp) = try await URLSession.shared.data(from: url)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                backendStatus = .connected
            } else {
                backendStatus = .error("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
            }
        } catch {
            backendStatus = .error("Unreachable")
        }
    }

    private func testClaude() async {
        guard !settings.claudeApiKey.isEmpty else {
            claudeStatus = .error("No key")
            return
        }
        do {
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue(settings.claudeApiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 10
            let body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                claudeStatus = .connected
            } else if code == 401 {
                claudeStatus = .error("Invalid key")
            } else if code == 429 {
                claudeStatus = .connected
            } else {
                claudeStatus = .error("HTTP \(code)")
            }
        } catch {
            claudeStatus = .error("Failed")
        }
    }

    private func testTesla() async {
        guard !settings.teslaAccessToken.isEmpty, !settings.backendUrl.isEmpty else {
            teslaStatus = .error("No token")
            return
        }
        do {
            var req = URLRequest(url: URL(string: "\(settings.backendUrl)/vehicles")!)
            req.setValue("Bearer \(settings.teslaAccessToken)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 10
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                teslaStatus = .connected
            } else if code == 401 {
                teslaStatus = .error("Token expired")
            } else {
                teslaStatus = .error("HTTP \(code)")
            }
        } catch {
            teslaStatus = .error("Failed")
        }
    }

    private func testGoogle() async {
        guard !settings.googleMapsApiKey.isEmpty else {
            googleStatus = .error("No key")
            return
        }
        do {
            let urlStr = "https://maps.googleapis.com/maps/api/geocode/json?address=test&key=\(settings.googleMapsApiKey)"
            let url = URL(string: urlStr)!
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String {
                if status == "OK" || status == "ZERO_RESULTS" {
                    googleStatus = .connected
                } else if status == "REQUEST_DENIED" {
                    googleStatus = .error("API not enabled")
                } else {
                    googleStatus = .error(status)
                }
            } else {
                googleStatus = .error("Bad response")
            }
        } catch {
            googleStatus = .error("Failed")
        }
    }
}

struct StatusRow: View {
    let label: String
    let status: SettingsView.ConnectionStatus
    var detail: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.icon)
                .foregroundColor(status.color)
                .font(.system(size: 14))
                .frame(width: 20)

            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)

            Spacer()

            switch status {
            case .checking:
                ProgressView().scaleEffect(0.7).tint(.yellow)
            case .error(let msg):
                Text(msg)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red)
            case .connected:
                Text("Connected")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
            case .unknown:
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
        .padding(12)
    }
}
