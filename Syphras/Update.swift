//
//  Update.swift
//  Syphras
//
//  Created by saiitanaa on 08/08/2026.
//

import Foundation
import os

private let updateLogger = Logger(subsystem: "com.saiitanaa.syphras", category: "update")

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let prerelease: Bool
    let draft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case prerelease
        case draft
    }
}

enum UpdateCheckError: Error {
    case invalidURL
    case httpError(Int)
    case decodingError(Error)
}

final class UpdateChecker {
    private let owner: String
    private let repo: String

    init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }

    func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw UpdateCheckError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateCheckError.httpError(code)
        }

        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.decodingError(error)
        }
    }

    /// Returns true if `latest` (tag_name) is a newer version than `current`
    static func isNewer(latest: String, than current: String) -> Bool {
        let clean1 = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
        let clean2 = current.hasPrefix("v") ? String(current.dropFirst()) : current

        let c1 = clean1.split(separator: ".").map { Int($0) ?? 0 }
        let c2 = clean2.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(c1.count, c2.count)

        for i in 0..<count {
            let a = i < c1.count ? c1[i] : 0
            let b = i < c2.count ? c2[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
