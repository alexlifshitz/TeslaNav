import SwiftUI

struct SettingsView: View {
    @ObservedObject var tesla: TeslaService
    @Environment(\.dismiss) private var dismiss

    @State private var settings = AppSettings.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Tesla
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("TESLA")

                        if settings.teslaAccessToken.isEmpty {
                            if !settings.backendUrl.isEmpty {
                                Link(destination: URL(string: "\(settings.backendUrl)/tesla/auth?app_scheme=teslanav")!) {
                                    HStack {
                                        Image(systemName: "bolt.car.fill")
                                        Text("Sign in with Tesla")
                                            .fontWeight(.semibold)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(red: 0.9, green: 0.1, blue: 0.1))
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                            Text("Sign in to send routes directly to your Tesla.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Tesla connected")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                Spacer()
                                Button("Sign Out") {
                                    settings.teslaAccessToken = ""
                                    settings.teslaRefreshToken = ""
                                }
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                            }
                            .padding(12)
                            .background(Color(white: 0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    // Saved Locations
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("SAVED LOCATIONS")

                        VStack(spacing: 0) {
                            // Home
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "house.fill")
                                    .foregroundColor(.yellow)
                                    .frame(width: 22)
                                    .padding(.top, 2)
                                Text("Home")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 50, alignment: .leading)
                                    .padding(.top, 2)
                                AddressSearchField(placeholder: "Home address", address: $settings.homeAddress)
                            }
                            .padding(12)

                            Divider().background(Color(white: 0.15))

                            // Work
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "briefcase.fill")
                                    .foregroundColor(.yellow)
                                    .frame(width: 22)
                                    .padding(.top, 2)
                                Text("Work")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 50, alignment: .leading)
                                    .padding(.top, 2)
                                AddressSearchField(placeholder: "Work address", address: $settings.workAddress)
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
                                    AddressSearchField(placeholder: "Address", address: $fav.address)
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

}
