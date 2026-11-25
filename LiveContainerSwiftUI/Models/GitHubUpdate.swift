//
//  GitHubUpdate.swift
//  LiveContainer
//
//  Support for installing/updating guest apps straight from a GitHub
//  repository's latest release (GitHub Releases API, no hosting site needed).
//

import Foundation

struct GitHubReleaseAsset: Decodable {
    let name: String
    let size: Int64
    let browser_download_url: String
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let name: String?
    let prerelease: Bool
    let html_url: String?
    let assets: [GitHubReleaseAsset]
    
    /// The first `.ipa` asset of the release, if any
    var ipaAsset: GitHubReleaseAsset? {
        return assets.first { $0.name.lowercased().hasSuffix(".ipa") }
    }
}

/// Parse "owner/repo", "github.com/owner/repo", or a full GitHub URL
/// (possibly ending in /releases/...) into the canonical "owner/repo" form.
func parseGithubRepoString(_ input: String) -> String? {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if s.lowercased().contains("github.com") || s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://") {
        guard let url = URL(string: s.lowercased().hasPrefix("http") ? s : "https://\(s)"),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        s = "\(parts[0])/\(parts[1])"
    }
    
    if s.lowercased().hasSuffix(".git") {
        s = String(s.dropLast(4))
    }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    
    let parts = s.split(separator: "/")
    guard parts.count == 2 else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
    guard parts[0].unicodeScalars.allSatisfy({ allowed.contains($0) }),
          parts[1].unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        return nil
    }
    return "\(parts[0])/\(parts[1])"
}

enum GithubApi {
    private static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = LCUtils.appGroupUserDefault.string(forKey: "LCGitHubToken")?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    
    /// Returns (statusCode, data). Network errors are thrown.
    private static func fetch(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw "lc.appList.githubApiError %lld".localizeWithFormat(-1)
        }
        return (http.statusCode, data)
    }
    
    /// The latest non-prerelease release of a repo. Repos that only publish
    /// prereleases have no "latest" (404), so we fall back to the newest single release.
    static func latestRelease(repo: String) async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw "lc.appList.repoInvalidError".loc
        }
        var (status, data) = try await fetch(makeRequest(url))
        
        if status == 404 {
            // Possibly a repo that marks all releases as pre-releases
            guard let listUrl = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=1") else {
                throw "lc.appList.noReleasesError %@".localizeWithFormat(repo)
            }
            (status, data) = try await fetch(makeRequest(listUrl))
            if status == 404 {
                // repo itself does not exist / no access
                throw "lc.appList.repoNotFoundError %@".localizeWithFormat(repo)
            }
            guard (200...299).contains(status) else {
                throw apiError(status)
            }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let first = releases.first else {
                throw "lc.appList.noReleasesError %@".localizeWithFormat(repo)
            }
            return first
        }
        
        guard (200...299).contains(status) else {
            throw apiError(status)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
    
    private static func apiError(_ status: Int) -> String {
        if status == 403 || status == 429 {
            return "lc.appList.githubRateLimitedError".loc
        }
        return "lc.appList.githubApiError %lld".localizeWithFormat(status)
    }
}
