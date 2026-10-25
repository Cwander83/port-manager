import Combine
import Core
import Foundation
import os

@MainActor
final class PortStore: ObservableObject {
    @Published var listeners: [PortItem] = []
    @Published var lastScanAt: Date?
    @Published var error: Error?

    /// Unique process count across all address rows.
    public var processCount: Int { stats.processCount }
    /// Total RAM held by unique processes (deduped by PID).
    public var totalRAM: Int64 { stats.totalRAM }

    private let scanner: PortScanner
    private let logger = Logger(subsystem: "com.cwander83.portmanager", category: "PortStore")
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var stats: ListenerStats = ListenerStats(processCount: 0, totalRAM: 0)

    init(scanner: PortScanner = MockPortScanner()) {
        self.scanner = scanner
    }

    func startScanning(interval: TimeInterval = 2.0) {
        stopScanning()
        performScan()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performScan()
            }
        }
    }

    func stopScanning() {
        timer?.invalidate()
        timer = nil
        scanTask?.cancel()
        scanTask = nil
    }

    /// Test-only hook to simulate a timer tick.
    func tick() {
        performScan()
    }

    private func performScan() {
        guard scanTask == nil else { return }
        let scanner = scanner
        let logger = logger
        scanTask = Task.detached { [weak self] in
            do {
                logger.debug("Starting port scan")
                let items = try await scanner.scan().sortedForDisplay()
                let stats = items.listenerStats()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled else {
                        self.scanTask = nil
                        return
                    }
                    self.listeners = items
                    self.stats = stats
                    self.lastScanAt = Date()
                    self.error = nil
                    self.scanTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled else {
                        self.scanTask = nil
                        return
                    }
                    self.error = error
                    logger.error("Port scan failed: \(error.localizedDescription)")
                    self.scanTask = nil
                }
            }
        }
    }
}
