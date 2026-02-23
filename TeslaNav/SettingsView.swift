import SwiftUI

struct SettingsView: View {
    @ObservedObject var tesla: TeslaService
    @Environment(\.dismiss) private var dismiss

    @State private var settings = AppSettings.current

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                List {
                    // API Keys
                    Section {
                        SecureField("Claude API Key", text: $settings.claudeApiKey)
                            .font(.system(size: 13, design: .monospaced))
                            .listRowBackground(Color(white: 0.08))

                        SecureField("Tesla Fleet API Token", text: $settings.teslaAccessToken)
                            .font(.system(size: 13, design: .monospaced))
                            .listRowBackground(Color(white: 0.08))

                        SecureField("Google Maps API Key", text: $settings.googleMapsApiKey)
                            .font(.system(size: 13, design: .monospaced))
                            .listRowBackground(Color(white: 0.08))

                        TextField("Backend URL", text: $settings.backendUrl)
                            .font(.system(size: 13, design: .monospaced))
                            .listRowBackground(Color(white: 0.08))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                    } header: {
                        Text("API CONFIGURATION")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .listRowSeparatorTint(Color(white: 0.15))

                    // Route Preferences
                    Section {
                        Stepper("Dwell time: \(settings.defaultDwellMinutes) min",
                                value: $settings.defaultDwellMinutes, in: 5...90, step: 5)
                            .foregroundColor(.white)
                            .listRowBackground(Color(white: 0.08))

                        Picker("Traffic model", selection: $settings.trafficModel) {
                            Text("Best guess").tag("best_guess")
                            Text("Pessimistic").tag("pessimistic")
                            Text("Optimistic").tag("optimistic")
                        }
                        .foregroundColor(.white)
                        .listRowBackground(Color(white: 0.08))

                        Toggle("Avoid tolls", isOn: $settings.avoidTolls)
                            .tint(.yellow)
                            .foregroundColor(.white)
                            .listRowBackground(Color(white: 0.08))

                    } header: {
                        Text("ROUTE OPTIONS")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .listRowSeparatorTint(Color(white: 0.15))

                    // Tesla Auth info
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tesla OAuth Flow")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            Text("1. Register app at developer.tesla.com\n2. Implement OAuth 2.0 → get access_token\n3. Paste token above\n\nScopes needed:\nvehicle_device_data, vehicle_cmds")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                                .lineSpacing(3)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color(white: 0.08))

                    } header: {
                        Text("TESLA SETUP")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .listRowSeparatorTint(Color(white: 0.15))
                }
                .scrollContentBackground(.hidden)
                .foregroundColor(.white)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        AppSettings.current = settings
                        Task { await tesla.loadVehicles() }
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
}
