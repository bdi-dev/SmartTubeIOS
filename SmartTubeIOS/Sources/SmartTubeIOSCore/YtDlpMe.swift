import Foundation

// MARK: - YtDlpMe

/// The caller's identity on the companion server, from `GET /v1/me`. An older server has no such
/// route (it answers 404), in which case the app simply does not show the "Signed in as" row.
public struct YtDlpMe: Decodable, Sendable, Equatable {
    public enum Role: String, Decodable, Sendable, Equatable {
        case admin
        case user
    }

    public let id: String
    public let name: String
    public let role: Role

    public init(id: String, name: String, role: Role) {
        self.id = id
        self.name = name
        self.role = role
    }
}
