import SwiftUI

// MARK: - Main View

struct ContentView: View {
    @StateObject private var speech = SpeechService()
    @StateObject private var tesla = TeslaService()
    @StateObject private var vm = RouteViewModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        VoiceInputCard(speech: speech, vm: vm)

                        if !vm.stops.isEmpty {
                            RouteStopsSection(vm: vm)
                        }

                        if !vm.stops.isEmpty && !vm.isOptimizing {
                            VehicleSendSection(tesla: tesla, vm: vm)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle("Tesla Nav")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gear")
                            .foregroundColor(.white)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionBadge(tesla: tesla)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(tesla: tesla)
            }
            .task { await tesla.loadVehicles() }
            .onChange(of: speech.transcript) { _, new in
                vm.promptText = new
            }
        }
    }
}

// MARK: - Voice Input Card

struct VoiceInputCard: View {
    @ObservedObject var speech: SpeechService
    @ObservedObject var vm: RouteViewModel

    var body: some View {
        VStack(spacing: 16) {
            Button(action: { speech.startListening() }) {
                ZStack {
                    Circle()
                        .fill(speech.isListening
                              ? Color.red.opacity(0.2)
                              : Color(white: 0.12))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Circle().stroke(
                                speech.isListening ? Color.red : Color(white: 0.2),
                                lineWidth: 1.5
                            )
                        )

                    if speech.isListening {
                        WaveformView()
                            .frame(width: 36, height: 24)
                            .foregroundColor(.red)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.top, 24)

            Text(speech.isListening ? "Listening..." : "Tap to speak or type below")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(white: 0.15), lineWidth: 1)
                    )

                if vm.promptText.isEmpty {
                    Text("\"Costco, then dry cleaning on University Ave, then home\"")
                        .font(.system(size: 14))
                        .foregroundColor(.gray.opacity(0.5))
                        .padding(14)
                }

                TextEditor(text: $vm.promptText)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 90)
            }
            .frame(minHeight: 90)

            HStack(spacing: 10) {
                // Build Route
                Button(action: { Task { await vm.parseAndOptimize() } }) {
                    HStack(spacing: 8) {
                        if vm.isOptimizing {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "location.fill")
                        }
                        Text(vm.isOptimizing ? "Parsing..." : "Build Route")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(vm.promptText.isEmpty ? Color(white: 0.15) : Color.yellow)
                    .foregroundColor(vm.promptText.isEmpty ? .gray : .black)
                    .cornerRadius(12)
                }
                .disabled(vm.promptText.isEmpty || vm.isOptimizing)

                // Clear
                if !vm.stops.isEmpty {
                    Button(action: { vm.clearRoute() }) {
                        Image(systemName: "xmark")
                            .fontWeight(.bold)
                            .frame(width: 48, height: 48)
                            .background(Color(white: 0.12))
                            .foregroundColor(.gray)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(white: 0.15), lineWidth: 1)
                            )
                    }
                }
            }

            if let err = vm.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.red)
                    .padding(10)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Route Stops Section

struct RouteStopsSection: View {
    @ObservedObject var vm: RouteViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Route header with total drive time
            HStack {
                SectionHeader(title: "Route", badge: "\(vm.stops.count) stop\(vm.stops.count == 1 ? "" : "s")")
                if let total = vm.totalDriveMin {
                    Text("\(total) min total")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(red: 0.3, green: 0.8, blue: 1))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.3, green: 0.8, blue: 1).opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 16)

            // Route preferences badges
            if let prefs = vm.preferences {
                RoutePrefsBadges(prefs: prefs)
                    .padding(.bottom, 10)
            }

            VStack(spacing: 0) {
                ForEach(Array(vm.stops.enumerated()), id: \.element.id) { idx, stop in
                    RouteStopRow(stop: stop, index: idx, isLast: idx == vm.stops.count - 1)
                }
            }
            .background(Color(white: 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(white: 0.13), lineWidth: 1)
            )
        }
    }
}

struct RoutePrefsBadges: View {
    let prefs: RoutePreferences

    var body: some View {
        let badges: [(String, String)] = {
            var b: [(String, String)] = []
            if prefs.scenic { b.append(("mountain.2.fill", "Scenic")) }
            if prefs.avoidHighways { b.append(("road.lanes", "No highways")) }
            if prefs.avoidTolls { b.append(("dollarsign.circle", "No tolls")) }
            if prefs.avoidFerries { b.append(("ferry", "No ferries")) }
            return b
        }()

        if !badges.isEmpty {
            HStack(spacing: 8) {
                ForEach(badges, id: \.1) { icon, text in
                    Label(text, systemImage: icon)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.yellow.opacity(0.1))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.yellow.opacity(0.3), lineWidth: 1))
                }
                Spacer()
            }
        }
    }
}

struct RouteStopRow: View {
    let stop: RouteStop
    let index: Int
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let drive = stop.driveMinutesFromPrev {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9))
                    Text("\(drive) min")
                    Spacer()
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(white: 0.05))
            }

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(stop.hasConflict ? Color.red.opacity(0.2) : Color.yellow.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(stop.hasConflict ? Color.red.opacity(0.5) : Color.yellow.opacity(0.4), lineWidth: 1)
                        )
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(stop.hasConflict ? .red : .yellow)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    // Label + address
                    if let label = stop.label, !label.isEmpty {
                        HStack(spacing: 6) {
                            Text(label)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            if stop.stopType == "resolved" {
                                Text("found")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(stop.address)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                    } else {
                        Text(stop.address)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    if let open = stop.openTime, let close = stop.closeTime {
                        Label("\(open) - \(close)", systemImage: "clock")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                    }

                    if let notes = stop.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.8))
                            .italic()
                    }

                    if let arrival = stop.estimatedArrival {
                        Label("Arrive \(arrival)", systemImage: "mappin")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(stop.hasConflict ? .red : Color(red: 0.3, green: 0.8, blue: 1))
                    }

                    if stop.hasConflict {
                        Label("Schedule conflict", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                    }
                }

                Spacer()
            }
            .padding(14)

            if !isLast {
                Divider()
                    .background(Color(white: 0.13))
                    .padding(.leading, 56)
            }
        }
    }
}

// MARK: - Vehicle Send Section

struct VehicleSendSection: View {
    @ObservedObject var tesla: TeslaService
    @ObservedObject var vm: RouteViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Send to Tesla", badge: tesla.vehicles.isEmpty ? "No cars" : "\(tesla.vehicles.count) car\(tesla.vehicles.count == 1 ? "" : "s")")
                .padding(.vertical, 16)

            if tesla.vehicles.isEmpty {
                HStack {
                    Image(systemName: "car.fill")
                        .foregroundColor(.gray)
                    Text("Add Tesla token in Settings to load vehicles")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.13)))

            } else {
                VStack(spacing: 10) {
                    ForEach(tesla.vehicles) { vehicle in
                        VehicleToggleRow(
                            vehicle: vehicle,
                            isSelected: vm.selectedVehicleIds.contains(vehicle.id),
                            onToggle: { vm.toggleVehicle(vehicle.id) }
                        )
                    }

                    Button(action: { Task { await vm.sendToSelectedVehicles(tesla: tesla) } }) {
                        HStack(spacing: 8) {
                            if vm.isSending {
                                ProgressView().tint(.black).scaleEffect(0.8)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text(sendButtonLabel)
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(vm.selectedVehicleIds.isEmpty ? Color(white: 0.15) : Color(red: 0.28, green: 0.78, blue: 1))
                        .foregroundColor(vm.selectedVehicleIds.isEmpty ? .gray : .black)
                        .cornerRadius(12)
                    }
                    .disabled(vm.selectedVehicleIds.isEmpty || vm.isSending)

                    ForEach(Array(vm.sendStatus.keys.sorted()), id: \.self) { key in
                        if let status = vm.sendStatus[key] {
                            HStack {
                                Image(systemName: status.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(status.success ? .green : .red)
                                Text(status.message)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.gray)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color(white: 0.07))
                            .cornerRadius(8)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    private var sendButtonLabel: String {
        if vm.isSending { return "Sending..." }
        let count = vm.selectedVehicleIds.count
        if count == 0 { return "Select a car" }
        return "Send to \(count) Car\(count == 1 ? "" : "s")"
    }
}

struct VehicleToggleRow: View {
    let vehicle: TeslaVehicle
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .yellow : .gray)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(vehicle.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(vehicle.vin)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                }

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(vehicle.isOnline ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(vehicle.state.capitalized)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .yellow : Color(white: 0.3))
                    .font(.system(size: 20))
            }
            .padding(14)
            .background(Color(white: isSelected ? 0.1 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.yellow.opacity(0.4) : Color(white: 0.13), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Helpers

struct SectionHeader: View {
    let title: String
    let badge: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
                .tracking(1.5)
            Spacer()
            Text(badge)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(white: 0.1))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(white: 0.15), lineWidth: 1))
        }
    }
}

struct ConnectionBadge: View {
    @ObservedObject var tesla: TeslaService

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tesla.vehicles.isEmpty ? Color.gray : Color.green)
                .frame(width: 7, height: 7)
            Text(tesla.vehicles.isEmpty ? "NO CAR" : "\(tesla.vehicles.count) CAR\(tesla.vehicles.count == 1 ? "" : "S")")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.1))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(white: 0.15), lineWidth: 1))
    }
}

// MARK: - Waveform Animation

struct WaveformView: View {
    @State private var phase = false

    let bars = 5
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .frame(width: 3)
                    .scaleEffect(y: phase ? [0.4, 1.0, 0.6, 0.9, 0.5][i] : [0.8, 0.5, 1.0, 0.4, 0.7][i], anchor: .center)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.08), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

#Preview {
    ContentView()
}
