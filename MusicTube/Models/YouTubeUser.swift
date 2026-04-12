import Foundation

struct YouTubeUser: Codable, Hashable {
    let id: String
    let email: String
    let name: String
    let pictureURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case picture = "picture"
    }

    init(id: String, email: String, name: String, pictureURL: URL?) {
        self.id = id
        self.email = email
        self.name = name
        self.pictureURL = pictureURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        name = try container.decode(String.self, forKey: .name)

        if let pictureString = try container.decodeIfPresent(String.self, forKey: .picture) {
            pictureURL = URL(string: pictureString)
        } else {
            pictureURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(email, forKey: .email)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(pictureURL?.absoluteString, forKey: .picture)
    }
}

struct YouTubeSession: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let user: YouTubeUser
    let scopeVersion: Int

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case user
        case scopeVersion
    }

    init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        user: YouTubeUser,
        scopeVersion: Int = 1
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.user = user
        self.scopeVersion = scopeVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        user = try container.decode(YouTubeUser.self, forKey: .user)
        scopeVersion = try container.decodeIfPresent(Int.self, forKey: .scopeVersion) ?? 1
    }

    var isExpired: Bool {
        Date() >= expiresAt
    }
}
