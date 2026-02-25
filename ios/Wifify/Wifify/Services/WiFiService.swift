import Foundation
import NetworkExtension
import CoreLocation

protocol WiFiServiceProtocol: Sendable {
    func fetchCurrentNetwork() async -> WiFiSignalInfo?
    func fetchSignalStrength() async -> (rssiEstimate: Int, normalized: Double)?
}

final class WiFiService: NSObject, WiFiServiceProtocol, CLLocationManagerDelegate, @unchecked Sendable {
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    /// Request location permission if needed (required for WiFi info).
    func ensureLocationPermission() async {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.locationContinuation = continuation
                DispatchQueue.main.async {
                    self.locationManager.requestWhenInUseAuthorization()
                }
            }
        }
    }

    func fetchCurrentNetwork() async -> WiFiSignalInfo? {
        await ensureLocationPermission()

        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                guard let network else {
                    continuation.resume(returning: nil)
                    return
                }

                // Convert normalized signal (0.0-1.0) to approximate dBm
                // Linear interpolation: 0.0 ≈ -90 dBm, 1.0 ≈ -30 dBm
                let normalized = network.signalStrength
                let estimatedRssi = Int(-90.0 + normalized * 60.0)

                continuation.resume(returning: WiFiSignalInfo(
                    rssiDbm: estimatedRssi,
                    noiseDbm: nil,
                    snrDb: nil,
                    channel: nil,
                    channelBand: nil,
                    channelWidth: nil,
                    txRateMbps: nil,
                    mcsIndex: nil,
                    phyMode: nil,
                    ssid: network.ssid,
                    bssid: network.bssid,
                    security: nil,
                    signalStrengthNormalized: normalized
                ))
            }
        }
    }

    func fetchSignalStrength() async -> (rssiEstimate: Int, normalized: Double)? {
        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                guard let network else {
                    continuation.resume(returning: nil)
                    return
                }
                let normalized = network.signalStrength
                let estimated = Int(-90.0 + normalized * 60.0)
                continuation.resume(returning: (estimated, normalized))
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined {
            locationContinuation?.resume()
            locationContinuation = nil
        }
    }
}
