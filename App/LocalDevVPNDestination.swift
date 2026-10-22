import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Canonicalizes an endpoint for NWConnection. CIDR describes route matching;
/// socket APIs need only the address, and only full-width host prefixes can be
/// safely removed without guessing which address within a subnet was intended.
struct LocalDevVPNDestination {
    let host: String
    let normalizationNotice: String?

    enum ParseError: LocalizedError {
        case empty
        case urlNotAllowed
        case pathNotAllowed
        case portNotAllowed
        case malformedAddress
        case invalidCIDR
        case networkCIDR

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter the LocalDevVPN destination address first."
            case .urlNotAllowed:
                return "Enter an IP address or hostname only, not a URL such as https://10.7.0.1."
            case .pathNotAllowed:
                return "The destination contains a path or an unsupported slash. Enter a host/IP only."
            case .portNotAllowed:
                return "Do not include a port. GassPair always tests TCP port 62078. For IPv6, use a bare address or [address]."
            case .malformedAddress:
                return "This does not look like a valid IPv4 address, IPv6 address, or hostname."
            case .invalidCIDR:
                return "The CIDR suffix is invalid. Use a host address such as 10.7.0.1/32 or an IPv6 host such as [::1]/128."
            case .networkCIDR:
                return "This is a network route, not a single destination host. Enter the LocalDevVPN Device/Peer IP without a network prefix (for example, 10.7.0.1)."
            }
        }
    }

    static func parse(_ rawValue: String) throws -> LocalDevVPNDestination {
        let original = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { throw ParseError.empty }
        guard !original.contains("://") else { throw ParseError.urlNotAllowed }
        guard !original.contains(where: { $0.isWhitespace }) else { throw ParseError.malformedAddress }

        var candidate = original
        var suppliedPrefix: Int?
        var suppliedPrefixText: String?
        var removedBrackets = false

        // Split CIDR before stripping IPv6 brackets, so both ::1/128 and [::1]/128 work.
        if let slash = candidate.lastIndex(of: "/") {
            let addressPart = String(candidate[..<slash])
            let suffix = String(candidate[candidate.index(after: slash)...])
            guard !addressPart.isEmpty,
                  !suffix.isEmpty,
                  suffix.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let prefix = Int(suffix) else {
                throw ParseError.invalidCIDR
            }
            candidate = addressPart
            suppliedPrefix = prefix
            suppliedPrefixText = "/\(prefix)"
        } else if candidate.contains("/") {
            throw ParseError.pathNotAllowed
        }

        // Brackets are accepted only around an IPv6 literal, never around a hostname/IPv4.
        if candidate.hasPrefix("[") || candidate.hasSuffix("]") {
            guard candidate.hasPrefix("["), candidate.hasSuffix("]"), candidate.count >= 4 else {
                throw ParseError.malformedAddress
            }
            let inner = String(candidate.dropFirst().dropLast())
            guard isIPv6(inner) else { throw ParseError.malformedAddress }
            candidate = inner
            removedBrackets = true
        }

        let isV4 = isIPv4(candidate)
        let isV6 = isIPv6(candidate)
        if let suppliedPrefix {
            guard isV4 || isV6 else { throw ParseError.invalidCIDR }
            let fullPrefix = isV4 ? 32 : 128
            // A /24, /64, etc. identifies a route/subnet rather than this socket's host.
            guard suppliedPrefix == fullPrefix else { throw ParseError.networkCIDR }
        }

        if isV4 || isV6 {
            var notes: [String] = []
            if let suppliedPrefixText {
                notes.append("Removed CIDR suffix \(suppliedPrefixText): it describes the route prefix and is not part of the TCP host. Testing \(candidate).")
            }
            if removedBrackets {
                notes.append("Removed IPv6 brackets for the socket host: \(candidate).")
            }
            return LocalDevVPNDestination(host: candidate, normalizationNotice: notes.isEmpty ? nil : notes.joined(separator: " "))
        }

        // An unparsed colon means a host:port, invalid IPv6, or unsupported scoped IPv6.
        if candidate.contains(":") { throw ParseError.portNotAllowed }
        if candidate.allSatisfy({ $0.isNumber || $0 == "." }) {
            throw ParseError.malformedAddress
        }

        // Deliberately restrict hostnames to ASCII DNS labels. Network.framework handles
        // resolution; this validation prevents URLs, ports, path fragments and whitespace.
        guard candidate.count <= 253,
              candidate.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (value >= 48 && value <= 57)
                      || (value >= 65 && value <= 90)
                      || (value >= 97 && value <= 122)
                      || value == 45 || value == 46
              }) else {
            throw ParseError.malformedAddress
        }

        let labels = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".")
        guard !labels.isEmpty,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }) else {
            throw ParseError.malformedAddress
        }

        // CIDR is permitted only with a valid IP literal, so any remaining prefix here
        // would be a malformed input rather than a resolvable hostname.
        guard suppliedPrefix == nil else { throw ParseError.invalidCIDR }
        return LocalDevVPNDestination(host: candidate, normalizationNotice: nil)
    }

    private static func isIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    private static func isIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
}
