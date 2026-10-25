import Combine
import Core
import Foundation
import os

@MainActor
final class PortStore: ObservableObject {
    @Published var listeners: [PortItem] = []
    @Published var lastScanAt: Date?
    @Published var error: Error?

    private let scanner: PortScanner
    private let logger = Logger(subsystem: "com.cwander83.portmanager", category: "PortStore")
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?

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

    private func performScan() {
        scanTask?.cancel()
        let scanner = scanner
        let logger = logger
        scanTask = Task.detached {
            do {
                logger.debug("Starting port scan")
                let items = try scanner.scan().sortedForDisplay()
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.listeners = items
                    self?.lastScanAt = Date()
                    self?.error = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.error = error
                    logger.error("Port scan failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
