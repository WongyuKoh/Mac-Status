import Foundation

/// Reuses only the user's explicit WakaTime plugin configuration, never a
/// browser session, shell command, or a configurable destination.
enum WakaTimeCredential {
    static let tokenURL = URL(string: "https://wakatime.com/oauth")!
    static let tokenRequiredMessage = "WakaTime 개인 OAuth 토큰을 연결해 주세요. API 키로는 통계를 조회하지 않습니다."

    /// Only recognized personal tokens are sent to the summaries API. Never
    /// reinterpret a plugin key from an older installation as a bearer token.
    static func checkedAccessToken(_ credential: String) throws -> String {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("waka_tok_"), value.count > "waka_tok_".count,
              value.utf8.count <= 8_192,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw StatusError.authentication("waka_tok_로 시작하는 개인 OAuth 토큰을 입력해 주세요. 기존 API 키는 사용할 수 없습니다.")
        }
        return value
    }

    static func readConfigured(at url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wakatime.cfg")) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw StatusError.message("기존 WakaTime 설정을 읽을 수 없습니다. 개인 OAuth 토큰을 직접 연결해 주세요.")
        }
        guard let value = parseConfiguration(text) else { return nil }
        return try checkedAccessToken(value)
    }

    static func parseConfiguration(_ text: String) -> String? {
        var section = ""
        var credential: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard section == "settings", let separator = line.firstIndex(of: "=") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "api_key" else { continue }
            credential = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard let credential, !credential.isEmpty else { return nil }
        return credential
    }
}
