import SwiftUI
import MapKit

struct RouteMapView: View {
    let stops: [RouteStop]
    let encodedPolyline: String?

    var body: some View {
        let coords = stopsWithCoordinates
        let polylineCoords = decodePolyline(encodedPolyline)
        let camera = fitCamera(coords: coords, polylineCoords: polylineCoords)

        Map(initialPosition: camera) {
            ForEach(Array(coords.enumerated()), id: \.element.id) { idx, stop in
                Marker(
                    "\(idx + 1). \(stop.displayName)",
                    coordinate: CLLocationCoordinate2D(
                        latitude: stop.latitude!,
                        longitude: stop.longitude!
                    )
                )
                .tint(.yellow)
            }

            if polylineCoords.count >= 2 {
                MapPolyline(coordinates: polylineCoords)
                    .stroke(.yellow, lineWidth: 4)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(white: 0.13), lineWidth: 1)
        )
    }

    private var stopsWithCoordinates: [RouteStop] {
        stops.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private func fitCamera(coords: [RouteStop], polylineCoords: [CLLocationCoordinate2D]) -> MapCameraPosition {
        var allCoords = coords.map {
            CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!)
        }
        allCoords.append(contentsOf: polylineCoords)

        guard !allCoords.isEmpty else {
            return .automatic
        }

        let lats = allCoords.map { $0.latitude }
        let lngs = allCoords.map { $0.longitude }
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lngs.min()! + lngs.max()!) / 2
        )
        let latSpan = max((lats.max()! - lats.min()!) * 1.4, 0.01)
        let lngSpan = max((lngs.max()! - lngs.min()!) * 1.4, 0.01)

        return .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lngSpan)
        ))
    }
}

// MARK: - Google Encoded Polyline Decoder

private func decodePolyline(_ encoded: String?) -> [CLLocationCoordinate2D] {
    guard let encoded, !encoded.isEmpty else { return [] }
    var coords: [CLLocationCoordinate2D] = []
    let bytes = Array(encoded.utf8)
    var index = 0
    var lat: Int32 = 0
    var lng: Int32 = 0

    while index < bytes.count {
        var result: Int32 = 0
        var shift: Int32 = 0
        var byte: Int32
        repeat {
            byte = Int32(bytes[index]) - 63
            index += 1
            result |= (byte & 0x1F) << shift
            shift += 5
        } while byte >= 0x20 && index < bytes.count
        lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

        result = 0
        shift = 0
        repeat {
            byte = Int32(bytes[index]) - 63
            index += 1
            result |= (byte & 0x1F) << shift
            shift += 5
        } while byte >= 0x20 && index < bytes.count
        lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

        coords.append(CLLocationCoordinate2D(
            latitude: Double(lat) / 1e5,
            longitude: Double(lng) / 1e5
        ))
    }

    return coords
}
