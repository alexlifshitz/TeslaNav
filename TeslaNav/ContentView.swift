import SwiftUI

// MARK: - Main View

struct ContentView: View {
    @EnvironmentObject var deepLink: DeepLinkManager
    @StateObject private var speech = SpeechService()
    @StateObject private var tesla = TeslaService()
    @StateObject private var vm = RouteViewModel()
    @StateObject private var calendar = CalendarService()
    @StateObject private var contacts = ContactsService()
    @StateObject private var weather = WeatherService()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            mainContent
                .navigationBarHidden(true)
                .sheet(isPresented: $showSettings) { SettingsView(tesla: tesla) }
                .task { [tesla] in await tesla.loadVehicles() }
                .task { [calendar] in
                    if AppSettings.current.calendarEnabled { await calendar.requestAccess() }
                }
                .task { [contacts] in
                    if AppSettings.current.contactsEnabled { await contacts.requestAccess() }
                }
                .task { [weather] in
                    await weather.fetchWeather(latitude: 37.7749, longitude: -122.4194)
                }
                .onChange(of: vm.stops) { _, _ in vm.checkBatteryRange(tesla: tesla) }
                .onChange(of: vm.selectedVehicleIds) { _, _ in vm.checkBatteryRange(tesla: tesla) }
                .onChange(of: speech.transcript) { _, new in vm.promptText = new }
                .onChange(of: deepLink.shouldOpenSettings) { _, open in
                    if open { showSettings = true; deepLink.shouldOpenSettings = false }
                }
                .onChange(of: deepLink.pendingPrompt) { _, prompt in
                    if let prompt {
                        vm.promptText = prompt
                        deepLink.pendingPrompt = nil
                        Task { await vm.parseAndOptimize(calendarEvents: calendar.upcomingEvents, contactAddresses: contacts.recentAddresses) }
                    }
                }
        }
    }

    private var mainContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }

            ScrollView {
                VStack(spacing: 16) {
                    headerRow
                    VoiceInputCard(speech: speech, vm: vm, calendar: calendar, contacts: contacts)
                    routeActionsSection
                    VehicleSendSection(tesla: tesla, vm: vm, weather: weather)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Tesla Nav")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.gray)
                    .frame(width: 36, height: 36)
                    .background(Color(white: 0.12))
                    .clipShape(Circle())
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var routeActionsSection: some View {
        if !vm.stops.isEmpty {
            RouteStopsSection(vm: vm, tesla: tesla)
            RouteActionsBar(vm: vm, tesla: tesla)
        }
    }
}

// MARK: - Voice Input Card

struct VoiceInputCard: View {
    @ObservedObject var speech: SpeechService
    @ObservedObject var vm: RouteViewModel
    @ObservedObject var calendar: CalendarService
    @ObservedObject var contacts: ContactsService

    var body: some View {
        VStack(spacing: 14) {
            // Mic + text input side by side
            HStack(alignment: .top, spacing: 12) {
                // Mic button
                Button(action: { speech.startListening() }) {
                    ZStack {
                        Circle()
                            .fill(speech.isListening
                                  ? Color.red.opacity(0.2)
                                  : Color(white: 0.12))
                            .frame(width: 56, height: 56)
                            .overlay(
                                Circle().stroke(
                                    speech.isListening ? Color.red : Color(white: 0.25),
                                    lineWidth: 1.5
                                )
                            )

                        if speech.isListening {
                            WaveformView()
                                .frame(width: 28, height: 18)
                                .foregroundColor(.red)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.top, 4)

                // Text input
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(white: 0.18), lineWidth: 1)
                        )

                    if vm.promptText.isEmpty {
                        Text("\"Take me to Costco, stop at Starbucks on the way, scenic route\"")
                            .font(.system(size: 14))
                            .foregroundColor(.gray.opacity(0.4))
                            .padding(12)
                    }

                    TextEditor(text: $vm.promptText)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 80)
                }
                .frame(minHeight: 80)
            }

            // Quick-tap saved locations
            let saved = AppSettings.current.allSavedLocations
            if !saved.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(saved, id: \.name) { loc in
                            Button(action: {
                                vm.promptText = vm.promptText.isEmpty
                                    ? "Take me to \(loc.name)"
                                    : "\(vm.promptText), stop at \(loc.name)"
                            }) {
                                Label(loc.name, systemImage: loc.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.yellow)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.yellow.opacity(0.1))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(Color.yellow.opacity(0.3), lineWidth: 1))
                            }
                        }
                    }
                }
            }

            // Calendar event chips
            if !calendar.upcomingEvents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(calendar.upcomingEvents.prefix(3)) { event in
                            Button(action: {
                                vm.promptText = vm.promptText.isEmpty
                                    ? "Take me to \(event.title)"
                                    : "\(vm.promptText), then to \(event.title)"
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 10))
                                    Text(event.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.cyan.opacity(0.1))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color.cyan.opacity(0.3), lineWidth: 1))
                            }
                        }
                    }
                }
            }

            // Buttons row
            HStack(spacing: 10) {
                Button(action: {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task {
                        await vm.parseAndOptimize(
                            calendarEvents: calendar.upcomingEvents,
                            contactAddresses: contacts.recentAddresses
                        )
                    }
                }) {
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
                    .background(vm.promptText.isEmpty ? Color(white: 0.12) : Color.yellow)
                    .foregroundColor(vm.promptText.isEmpty ? .gray : .black)
                    .cornerRadius(12)
                }
                .disabled(vm.promptText.isEmpty || vm.isOptimizing)

                if !vm.stops.isEmpty || !vm.promptText.isEmpty {
                    Button(action: {
                        vm.clearRoute()
                        vm.promptText = ""
                    }) {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                            .frame(width: 48, height: 48)
                            .background(Color(white: 0.12))
                            .foregroundColor(.gray)
                            .cornerRadius(12)
                    }
                }
            }

            if let err = vm.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Route Actions Bar

struct RouteActionsBar: View {
    @ObservedObject var vm: RouteViewModel
    @ObservedObject var tesla: TeslaService

    var body: some View {
        VStack(spacing: 8) {
            if vm.stops.count >= 3 {
                Button(action: { Task { await vm.optimizeOrder(tesla: tesla) } }) {
                    HStack(spacing: 8) {
                        if vm.isResolving {
                            ProgressView().tint(.yellow).scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.triangle.swap")
                        }
                        Text("Optimize Route Order")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.yellow.opacity(0.12))
                    .foregroundColor(.yellow)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.3)))
                }
                .disabled(vm.isResolving)
            }

            if let warning = vm.rangeWarning {
                Label(warning, systemImage: "battery.25")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
            }
        }
    }
}

// MARK: - Route Stops Section

struct RouteStopsSection: View {
    @ObservedObject var vm: RouteViewModel
    @ObservedObject var tesla: TeslaService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ROUTE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                    .tracking(1.5)

                Spacer()

                Text("\(vm.stops.count) stop\(vm.stops.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)

                if vm.isResolving {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6).tint(.yellow)
                        Text("Resolving...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                } else {
                    if let dist = vm.totalDistanceKm {
                        let miles = dist * 0.621371
                        Text(String(format: "%.0f mi", miles))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                    if let total = vm.totalDriveMin {
                        Text("\(total) min")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(red: 0.3, green: 0.8, blue: 1))
                    }
                }
            }

            if let prefs = vm.preferences {
                RoutePrefsBadges(prefs: prefs)
            }

            VStack(spacing: 0) {
                ForEach(Array(vm.stops.enumerated()), id: \.element.id) { idx, stop in
                    RouteStopRow(stop: stop, index: idx, isLast: idx == vm.stops.count - 1)
                }
            }
            .background(Color(white: 0.06))
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
            if stop.driveMinutesFromPrev != nil || stop.distanceMeters != nil {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9))
                    if let drive = stop.driveMinutesFromPrev {
                        Text("\(drive) min")
                    }
                    if let dist = stop.distanceMeters {
                        let miles = Double(dist) / 1609.34
                        Text(String(format: "%.1f mi", miles))
                    }
                    Spacer()
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(Color(white: 0.04))
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
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
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
                            .font(.system(size: 11))
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
                            .foregroundColor(.gray.opacity(0.7))
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
            .padding(12)

            if !isLast {
                Divider()
                    .background(Color(white: 0.13))
                    .padding(.leading, 52)
            }
        }
    }
}

// MARK: - Vehicle Send Section

struct VehicleSendSection: View {
    @ObservedObject var tesla: TeslaService
    @ObservedObject var vm: RouteViewModel
    @ObservedObject var weather: WeatherService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("YOUR TESLAS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                    .tracking(1.5)
                Spacer()
                if !tesla.vehicles.isEmpty {
                    Text("\(tesla.vehicles.count) car\(tesla.vehicles.count == 1 ? "" : "s")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            if tesla.isLoading {
                HStack {
                    ProgressView().tint(.gray).scaleEffect(0.8)
                    Text("Loading vehicles...")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.13)))

            } else if tesla.vehicles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.gray)
                        Text("No vehicles found")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Text("Add your Tesla token in Settings to connect your cars.")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.13)))

            } else {
                VStack(spacing: 8) {
                    ForEach(tesla.vehicles) { vehicle in
                        VehicleToggleRow(
                            vehicle: vehicle,
                            isSelected: vm.selectedVehicleIds.contains(vehicle.id),
                            status: tesla.vehicleStatus[vehicle.id],
                            onToggle: { vm.toggleVehicle(vehicle.id) }
                        )
                    }
                }

                // Send button — only show when there's a route
                if !vm.stops.isEmpty {
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
                        .background(canSend ? Color(red: 0.28, green: 0.78, blue: 1) : Color(white: 0.1))
                        .foregroundColor(canSend ? .black : .gray)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(canSend ? Color.clear : Color(white: 0.15), lineWidth: 1)
                        )
                    }
                    .disabled(!canSend)
                }

                // Pre-condition climate
                if !vm.selectedVehicleIds.isEmpty {
                    Button(action: { Task { await vm.activateClimate(tesla: tesla) } }) {
                        HStack(spacing: 8) {
                            if vm.isClimateActivating {
                                ProgressView().tint(.cyan).scaleEffect(0.8)
                            } else {
                                Image(systemName: "snowflake")
                            }
                            Text(vm.isClimateActivating ? "Starting..." : "Pre-condition Climate")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.cyan.opacity(0.12))
                        .foregroundColor(.cyan)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cyan.opacity(0.3)))
                    }
                    .disabled(vm.isClimateActivating)
                }

                // Climate status
                if let climateMsg = vm.climateStatus {
                    Label(climateMsg, systemImage: "thermometer.medium")
                        .font(.system(size: 12))
                        .foregroundColor(.cyan)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cyan.opacity(0.08))
                        .cornerRadius(8)
                }

                // Send results
                ForEach(vm.sendStatus.keys.sorted(), id: \.self) { key in
                    if let status = vm.sendStatus[key] {
                        HStack {
                            Image(systemName: status.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(status.success ? .green : .red)
                            Text(status.message)
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                            Spacer()
                        }
                        .padding(10)
                        .background(Color(white: 0.06))
                        .cornerRadius(8)
                    }
                }
            }
        }
    }

    private var canSend: Bool {
        !vm.selectedVehicleIds.isEmpty && !vm.stops.isEmpty && !vm.isSending
    }

    private var sendButtonLabel: String {
        if vm.isSending { return "Sending..." }
        let count = vm.selectedVehicleIds.count
        if count == 0 { return "Select a car above" }
        return "Send to \(count) Car\(count == 1 ? "" : "s")"
    }
}

struct VehicleToggleRow: View {
    let vehicle: TeslaVehicle
    let isSelected: Bool
    let status: VehicleStatusData?
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Group {
                    if let url = vehicle.imageURL(paintCode: status?.paintOptionCode) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                Image(systemName: "car.side.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(isSelected ? .yellow : .gray)
                            }
                        }
                    } else {
                        Image(systemName: "car.side.fill")
                            .font(.system(size: 28))
                            .foregroundColor(isSelected ? .yellow : .gray)
                    }
                }
                .frame(width: 100, height: 60)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(vehicle.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Circle()
                            .fill(vehicle.isOnline ? Color.green : Color.gray.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(vehicle.state.capitalized)
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    if let s = status {
                        HStack(spacing: 5) {
                            Image(systemName: batteryIcon(s.batteryLevel))
                                .font(.system(size: 10))
                                .foregroundColor(batteryColor(s.batteryLevel))
                            Text("\(s.batteryLevel)%")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(batteryColor(s.batteryLevel))
                            Text("\(Int(s.batteryRange)) mi")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                            if let cabin = s.interiorTemp {
                                Text("·")
                                    .foregroundColor(.gray)
                                Image(systemName: "thermometer.medium")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                Text("\(Int(cabin * 9.0 / 5.0 + 32.0))°F")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }

                Spacer()

                if let s = status, s.isClimateOn {
                    Image(systemName: "snowflake")
                        .font(.system(size: 12))
                        .foregroundColor(.cyan)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .yellow : Color(white: 0.25))
                    .font(.system(size: 24))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(white: isSelected ? 0.1 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.yellow.opacity(0.5) : Color(white: 0.13), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func batteryIcon(_ level: Int) -> String {
        if level > 75 { return "battery.100" }
        if level > 50 { return "battery.75" }
        if level > 25 { return "battery.50" }
        return "battery.25"
    }

    private func batteryColor(_ level: Int) -> Color {
        if level > 50 { return .green }
        if level > 20 { return .yellow }
        return .red
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
