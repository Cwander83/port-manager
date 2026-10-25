import Foundation

public extension Int64 {
    func formatBytes() -> String {
        let gb = Double(self) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(self) / (1024 * 1024)
        if mb >= 0.9 {
            return String(format: "%.1f MB", mb)
        }
        let kb = Double(self) / 1024
        if kb >= 1.0 {
            return String(format: "%.1f KB", kb)
        }
        return "\(self) B"
    }
}
