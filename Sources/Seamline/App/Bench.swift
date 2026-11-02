#if DEBUG
import Foundation
import SeamlineCore

/// Debug builds only. SEAMLINE_BENCH=seconds drives a paired link with realistic input and prints latency percentiles.
/// Motion is ignored by the guest (the pointer never "enters") and the events are `.leave`, which injects nothing.
enum Bench {
    static func runIfRequested(_ connection: PeerConnection, name: String) {
        guard let value = ProcessInfo.processInfo.environment["SEAMLINE_BENCH"], let seconds = Double(value) else { return }
        let queue = DispatchQueue(label: "seamline.bench", qos: .userInteractive)
        queue.asyncAfter(deadline: .now() + 1.5) {
            connection.setHot(true)
            connection.resetMeasurements()
            print("[bench] \(name) over \(connection.linkKind?.rawValue ?? "?"), datagrams: \(connection.usesDatagrams), \(Int(seconds)) s at 125 Hz motion + 20 events/s")
            let start = Date()
            var tick = 0
            while Date().timeIntervalSince(start) < seconds {
                connection.send(.move(seq: 0, x: Float(tick % 1000), y: 10, dx: 1, dy: 0))
                if tick % 6 == 0 { connection.send(.leave) }
                tick += 1
                Thread.sleep(forTimeInterval: 0.008)
            }
            Thread.sleep(forTimeInterval: 0.5)
            let (datagram, stream) = connection.latencyReport
            func line(_ label: String, _ s: LatencyStats) -> String {
                guard s.count > 0 else { return "[bench] \(label): no samples" }
                let f = { (p: Double) in String(format: "%.1f", s.percentile(p) ?? 0) }
                return "[bench] \(label) round trip ms  p50 \(f(50))  p90 \(f(90))  p99 \(f(99))  max \(f(100))  (n=\(s.count))"
            }
            print(line("UDP ", datagram))
            print(line("TCP ", stream))
            let stats = connection.statistics
            print("[bench] host sent \(tick) moves, \(stats.movesSent) motion datagrams, \(stats.datagramsOut) datagrams total")
            fflush(stdout)
        }
    }
}
#endif
