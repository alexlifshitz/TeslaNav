import Foundation
import CoreLocation

@MainActor
class WeatherService: ObservableObject {
    @Published var currentTempC: Double?
    @Published var feelsLikeC: Double?
    @Published var weatherCode: Int?

    /// Fetch current weather from Open-Meteo (free, no API key needed).
    func fetchWeather(latitude: Double, longitude: Double) async {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,apparent_temperature,weather_code"
        guard let url = URL(string: urlStr) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let current = json["current"] as? [String: Any] {
                currentTempC = current["temperature_2m"] as? Double
                feelsLikeC = current["apparent_temperature"] as? Double
                weatherCode = current["weather_code"] as? Int
            }
        } catch { /* weather is best-effort */ }
    }

    /// Suggest a comfortable cabin temperature based on outside weather.
    /// Returns Celsius value.
    var suggestedCabinTempC: Double {
        guard let outside = currentTempC else { return 21.0 }
        if outside < 5 { return 23.0 }       // cold → warm cabin
        if outside < 15 { return 22.0 }       // cool → slightly warm
        if outside < 25 { return 21.0 }       // mild → comfortable
        if outside < 32 { return 20.0 }       // warm → cool cabin
        return 19.0                           // hot → cold cabin
    }

    /// Fahrenheit conversion for display.
    func celsiusToFahrenheit(_ c: Double) -> Double {
        c * 9.0 / 5.0 + 32.0
    }

    var currentTempF: Double? {
        currentTempC.map { celsiusToFahrenheit($0) }
    }
}
