import Foundation

@main
struct LocalDevVPNDestinationTests {
    static func main() throws {
        try expectHost("10.7.0.1", "10.7.0.1")
        try expectHost(" 10.7.0.1/32 ", "10.7.0.1", noticeContains: "/32")
        try expectHost("[::1]", "::1", noticeContains: "IPv6 brackets")
        try expectHost("[::1]/128", "::1", noticeContains: "/128")
        try expectHost("::1/128", "::1", noticeContains: "/128")
        try expectHost("example.local", "example.local")
        try expectHost("example.local.", "example.local.")

        try expectFailure("", containing: "Enter the LocalDevVPN destination")
        try expectFailure("10.7.0.0/24", containing: "network route")
        try expectFailure("https://10.7.0.1", containing: "not a URL")
        try expectFailure("10.7.0.1:62078", containing: "Do not include a port")
        try expectFailure("999.1.1.1", containing: "valid IPv4")
        try expectFailure("[not-ipv6]", containing: "valid IPv4")
        try expectFailure("10.7.0.1/32:62078", containing: "CIDR suffix is invalid")

        print("PASS: 7 valid destination cases and 7 invalid destination cases")
    }

    private static func expectHost(_ input: String, _ expected: String, noticeContains: String? = nil) throws {
        let destination = try LocalDevVPNDestination.parse(input)
        guard destination.host == expected else {
            throw TestFailure(description: "Expected \(input.debugDescription) -> \(expected), got \(destination.host)")
        }
        if let noticeContains {
            guard destination.normalizationNotice?.contains(noticeContains) == true else {
                throw TestFailure(description: "Expected normalization notice containing \(noticeContains.debugDescription) for \(input.debugDescription)")
            }
        } else if destination.normalizationNotice != nil {
            throw TestFailure(description: "Unexpected normalization notice for \(input.debugDescription)")
        }
    }

    private static func expectFailure(_ input: String, containing text: String) throws {
        do {
            _ = try LocalDevVPNDestination.parse(input)
            throw TestFailure(description: "Expected \(input.debugDescription) to fail")
        } catch let error as LocalDevVPNDestination.ParseError {
            guard error.localizedDescription.contains(text) else {
                throw TestFailure(description: "Unexpected error for \(input.debugDescription): \(error.localizedDescription)")
            }
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(description: String) { self.description = description }
    }
}
