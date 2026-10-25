import Combine
import Core
import Foundation

@MainActor
final class PortStore: ObservableObject {
    @Published var listeners: [PortItem] = []
    @Published var lastScanAt: Date?
    @Published var error: Error?

    private let scanner: PortScanner
    private var timer: Timer?

    init(scanner: PortScanner = MockPortScanner()) {
        self.scanner = scanner
    }

    func startScanning(interval: TimeInterval = 2.0) {
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
    }

    private func performScan() {
        Task.detached { [scanner = scanner] in
            do {
                let items = try scanner.scan().sortedForDisplay()
                await MainActor.run { [weak self] in
                    self?.listeners = items
                    self?.lastScanAt = Date()
                    self?.error = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.error = error
                }
            }
        }
    }
}
