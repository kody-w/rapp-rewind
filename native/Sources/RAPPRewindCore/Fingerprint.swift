import Foundation

public enum Fingerprint {
    public static func hex(_ data: [UInt8]) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func delta(_ lhs: String?, _ rhs: String?) -> (mean: Double, maximum: Double) {
        guard let lhs, let rhs, !lhs.isEmpty, lhs.count == rhs.count,
              let a = decode(lhs), let b = decode(rhs), !a.isEmpty else {
            return (999, 999)
        }
        let values = zip(a, b).map { abs(Int($0) - Int($1)) }
        return (Double(values.reduce(0, +)) / Double(values.count), Double(values.max() ?? 999))
    }

    public static func isSame(_ lhs: String?, _ rhs: String?, mean: Double = 0.5, maximum: Double = 12) -> Bool {
        let difference = delta(lhs, rhs)
        return difference.mean < mean && difference.maximum < maximum
    }

    private static func decode(_ string: String) -> [UInt8]? {
        let bytes = Array(string.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        func digit(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 55
            case 97...102: return value - 87
            default: return nil
            }
        }
        var output: [UInt8] = []
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let a = digit(bytes[index]), let b = digit(bytes[index + 1]) else { return nil }
            output.append(a * 16 + b)
        }
        return output
    }
}
