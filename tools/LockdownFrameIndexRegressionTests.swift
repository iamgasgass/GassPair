import Foundation

/// Regression test for Data indices after removeFirst(), which caused a crash on
/// the second Lockdown plist response in TCP + Lockdown mode.
@main
struct LockdownFrameIndexRegressionTests {
    static func main() throws {
        let body1 = Data("first-response".utf8)
        let body2 = Data("second-response".utf8)
        var buffer = frame(body1)
        let first = try extractFrame(from: &buffer)
        guard first == body1 else { throw Failure(message: "First frame decoded incorrectly") }

        // Simulate the next send/reply cycle using the same parser state. This used
        // to retain a shifted Data.startIndex and then index the header as [0...3].
        buffer = Data([0xAA, 0xBB])
        buffer.append(frame(body2))
        buffer.removeFirst(2) // deliberately leave startIndex == 2, like Data after removeFirst()
        let second = try extractFrame(from: &buffer)
        guard second == body2 else { throw Failure(message: "Shifted-index frame decoded incorrectly") }


        print("PASS: sequential frames do not assume Data.startIndex == 0")
    }

    private static func frame(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var result = Data()
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(body)
        return result
    }

    private static func extractFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let b0 = Int(buffer[buffer.index(start, offsetBy: 0)])
        let b1 = Int(buffer[buffer.index(start, offsetBy: 1)])
        let b2 = Int(buffer[buffer.index(start, offsetBy: 2)])
        let b3 = Int(buffer[buffer.index(start, offsetBy: 3)])
        let length = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        guard length > 0, length <= 2 * 1024 * 1024 else { throw Failure(message: "Invalid frame length") }
        buffer = Data(buffer.dropFirst(4))
        guard buffer.count >= length else { return nil }
        let decoded = Data(buffer.prefix(length))
        buffer = Data(buffer.dropFirst(length))
        return decoded
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
