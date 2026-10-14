import Foundation
import CryptoKit

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable = "Stable"
    case beta = "Beta"
    var id: String { rawValue }
}

enum AppConfig {
    static let repo = "Malti2/Unbox"
}

struct ReleaseInfo: Decodable, Identifiable {
    struct Asset: Decodable {
        var name: String
        var size: Int64
        var browser_download_url: URL
        var digest: String?
    }
    var tag_name: String
    var name: String?
    var prerelease: Bool
    var draft: Bool
    var html_url: URL
    var assets: [Asset]
    var id: String { tag_name }

    var dmgAsset: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
}

/// Version ordering for tags such as v0.1.0, v0.2.0-beta.3.
struct AppVersion: Comparable {
    var core: [Int]
    var pre: [Int]?   // nil = final release; final sorts above any pre-release of the same core

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        let nums = parts[0].split(separator: ".").compactMap { Int($0) }
        guard !nums.isEmpty, nums.count == parts[0].split(separator: ".").count else { return nil }
        core = nums
        if parts.count == 2 {
            pre = parts[1].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if pre?.isEmpty == true { pre = [0] }
        } else { pre = nil }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.core.count, b.core.count)
        for i in 0..<n {
            let x = i < a.core.count ? a.core[i] : 0, y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y }
        }
        switch (a.pre, b.pre) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (p?, q?): return p.lexicographicallyPrecedes(q)
        }
    }
    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

enum Updater {
    static func latest(channel: UpdateChannel, current: String) async throws -> ReleaseInfo? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppConfig.repo)/releases?per_page=30")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("GitHub did not return the release list.")
        }
        let releases = try JSONDecoder().decode([ReleaseInfo].self, from: data)
        let eligible = releases.filter { !$0.draft && $0.dmgAsset != nil && (channel == .beta || !$0.prerelease) }
        let best = eligible.compactMap { r in AppVersion(r.tag_name).map { (r, $0) } }.max { $0.1 < $1.1 }
        guard let (release, version) = best, let cur = AppVersion(current), cur < version else { return nil }
        return release
    }

    /// Downloads the release image and checks size and SHA-256 (when GitHub provides one).
    static func download(_ release: ReleaseInfo) async throws -> URL {
        guard let asset = release.dmgAsset else { throw UpdateError.message("The release has no disk image.") }
        let (tmp, resp) = try await URLSession.shared.download(from: asset.browser_download_url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("The download failed.") }
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? nil
        if let size, size != asset.size { throw UpdateError.message("The download is incomplete.") }
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            let expected = String(digest.dropFirst(7)).lowercased()
            let handle = try FileHandle(forReadingFrom: tmp)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError.message("The download does not match its checksum.") }
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Unbox-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
