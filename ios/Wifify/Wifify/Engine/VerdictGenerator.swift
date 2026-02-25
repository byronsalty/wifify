import Foundation

/// Port of generate_verdicts() from wifify.py — same thresholds and categories.
enum VerdictGenerator {

    static func generate(from result: DiagnosticsResult) -> [Verdict] {
        var verdicts: [Verdict] = []

        // WiFi signal
        if result.connection.type == "wifi", let ws = result.wifiSignal {
            if let rssi = ws.rssiDbm {
                if rssi >= -50 {
                    verdicts.append(Verdict(category: "wifi_signal", severity: "good",
                        message: "Excellent WiFi signal (\(rssi) dBm)"))
                } else if rssi >= -60 {
                    verdicts.append(Verdict(category: "wifi_signal", severity: "good",
                        message: "Good WiFi signal (\(rssi) dBm)"))
                } else if rssi >= -70 {
                    verdicts.append(Verdict(category: "wifi_signal", severity: "warning",
                        message: "Fair WiFi signal (\(rssi) dBm) — consider moving closer to the router"))
                } else {
                    verdicts.append(Verdict(category: "wifi_signal", severity: "bad",
                        message: "Weak WiFi signal (\(rssi) dBm) — likely degrading your connection"))
                }
            }

            // SNR (only if available — won't be on iOS)
            if let snr = ws.snrDb {
                if snr < 20 {
                    verdicts.append(Verdict(category: "wifi_noise", severity: "bad",
                        message: "Very low SNR (\(snr) dB) — heavy interference"))
                } else if snr < 30 {
                    verdicts.append(Verdict(category: "wifi_noise", severity: "warning",
                        message: "Moderate SNR (\(snr) dB) — some interference"))
                }
            }

            // 2.4GHz warning
            if let band = ws.channelBand, band == "2.4GHz" {
                verdicts.append(Verdict(category: "wifi_band", severity: "warning",
                    message: "Connected on 2.4GHz — 5GHz or 6GHz is faster if available"))
            }
        }

        // Baseline packet loss
        for (label, pingResult) in result.baselineLatency {
            if pingResult.packetLossPct > 5 {
                verdicts.append(Verdict(category: "packet_loss", severity: "bad",
                    message: "High packet loss to \(label): \(String(format: "%.1f", pingResult.packetLossPct))%"))
            } else if pingResult.packetLossPct > 1 {
                verdicts.append(Verdict(category: "packet_loss", severity: "warning",
                    message: "Some packet loss to \(label): \(String(format: "%.1f", pingResult.packetLossPct))%"))
            }
        }

        // Gateway latency
        if let gw = result.baselineLatency["gateway"] {
            if let avg = gw.avgMs {
                if avg > 20 {
                    verdicts.append(Verdict(category: "gateway_latency", severity: "bad",
                        message: "High gateway latency (\(String(format: "%.1f", avg))ms)"))
                } else if avg > 10 {
                    verdicts.append(Verdict(category: "gateway_latency", severity: "warning",
                        message: "Moderate gateway latency (\(String(format: "%.1f", avg))ms)"))
                } else {
                    verdicts.append(Verdict(category: "gateway_latency", severity: "good",
                        message: "Good gateway latency (\(String(format: "%.1f", avg))ms)"))
                }
            }

            // Jitter
            if let jitter = gw.jitterMs {
                if jitter > 10 {
                    verdicts.append(Verdict(category: "jitter", severity: "warning",
                        message: "High jitter (\(String(format: "%.1f", jitter))ms) — connection is unstable"))
                }
            }
        }

        // DNS
        if result.dns.failures > 0 {
            verdicts.append(Verdict(category: "dns", severity: "bad",
                message: "\(result.dns.failures) DNS resolution failure(s)"))
        } else if let avg = result.dns.avgTimeMs, avg > 100 {
            verdicts.append(Verdict(category: "dns", severity: "warning",
                message: "Slow DNS resolution (avg \(Int(avg))ms)"))
        }

        // Speed
        let speed = result.speed
        if let dl = speed.dlThroughputMbps {
            if dl < 10 {
                verdicts.append(Verdict(category: "speed", severity: "bad",
                    message: "Very slow download: \(String(format: "%.1f", dl)) Mbps"))
            } else if dl < 50 {
                verdicts.append(Verdict(category: "speed", severity: "warning",
                    message: "Moderate download: \(String(format: "%.1f", dl)) Mbps"))
            } else {
                verdicts.append(Verdict(category: "speed", severity: "good",
                    message: "Download: \(String(format: "%.1f", dl)) Mbps"))
            }
        }

        if let ul = speed.ulThroughputMbps {
            if ul < 5 {
                verdicts.append(Verdict(category: "speed_up", severity: "bad",
                    message: "Very slow upload: \(String(format: "%.1f", ul)) Mbps"))
            } else if ul < 20 {
                verdicts.append(Verdict(category: "speed_up", severity: "warning",
                    message: "Moderate upload: \(String(format: "%.1f", ul)) Mbps"))
            } else {
                verdicts.append(Verdict(category: "speed_up", severity: "good",
                    message: "Upload: \(String(format: "%.1f", ul)) Mbps"))
            }
        }

        // Bufferbloat
        if let ratio = speed.bufferbloatRatio {
            if ratio > 5 {
                verdicts.append(Verdict(category: "bufferbloat", severity: "bad",
                    message: "Severe bufferbloat — latency increases \(String(format: "%.0f", ratio))x under load"))
            } else if ratio > 3 {
                verdicts.append(Verdict(category: "bufferbloat", severity: "warning",
                    message: "Moderate bufferbloat — latency increases \(String(format: "%.1f", ratio))x under load"))
            } else {
                verdicts.append(Verdict(category: "bufferbloat", severity: "good",
                    message: "Low bufferbloat (\(String(format: "%.1f", ratio))x)"))
            }
        }

        // Monitoring loss
        let summary = result.monitoringSummary
        if summary.gatewayTotal > 0 {
            let lossPct = Double(summary.gatewayLossCount) / Double(summary.gatewayTotal) * 100
            if lossPct > 2 {
                verdicts.append(Verdict(category: "monitoring_loss", severity: "bad",
                    message: "Gateway packet loss during monitoring: \(summary.gatewayLossCount)/\(summary.gatewayTotal) (\(String(format: "%.1f", lossPct))%)"))
            } else if lossPct > 0 {
                verdicts.append(Verdict(category: "monitoring_loss", severity: "warning",
                    message: "Some gateway packet loss: \(summary.gatewayLossCount)/\(summary.gatewayTotal)"))
            }

            let inetLossPct = Double(summary.internetLossCount) / Double(summary.gatewayTotal) * 100
            if inetLossPct > 2 {
                verdicts.append(Verdict(category: "monitoring_inet_loss", severity: "bad",
                    message: "Internet packet loss during monitoring: \(summary.internetLossCount)/\(summary.gatewayTotal) (\(String(format: "%.1f", inetLossPct))%)"))
            }
        }

        // Latency spikes
        if let avg = summary.gatewayStats.avg, let p95 = summary.gatewayStats.p95 {
            if avg > 0 && p95 > avg * 3 {
                verdicts.append(Verdict(category: "latency_spikes", severity: "warning",
                    message: "Latency spikes detected — P95 (\(String(format: "%.0f", p95))ms) is \(String(format: "%.1f", p95/avg))x average"))
            }
        }

        // Anomalies
        if summary.anomalyCount > 0 {
            verdicts.append(Verdict(category: "anomalies", severity: summary.anomalyCount > 5 ? "bad" : "warning",
                message: "\(summary.anomalyCount) anomalies detected during monitoring"))
        }

        return verdicts
    }
}
