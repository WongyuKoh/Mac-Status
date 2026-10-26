import XCTest
@testable import MacStatus

final class WakaTimeCredentialTests: XCTestCase {
    func testOnlySettingsAPIKeyIsReadWithoutExecutingVaultCommands() {
        let config = """
        # ignored = comment
        [other]
        api_key = wrong
        [settings]
        api_url = https://example.com
        api_key_vault_cmd = never execute this
        api_key = waka_tok_example
        """
        XCTAssertEqual(WakaTimeCredential.parseConfiguration(config), "waka_tok_example")
        XCTAssertNil(WakaTimeCredential.parseConfiguration("[settings]\napi_key_vault_cmd = echo value"))
        XCTAssertNil(WakaTimeCredential.parseConfiguration("[settings]\napi_key =  \n[other]\napi_key = wrong"))
    }

    func testConfigurationReadIsBoundedAndMissingFileIsNotAnError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(".wakatime.cfg")
        XCTAssertNil(try WakaTimeCredential.readConfigured(at: file))
        try "[settings]\napi_key = waka_tok_example\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try WakaTimeCredential.readConfigured(at: file), "waka_tok_example")
        try Data(repeating: 65, count: 65_537).write(to: file)
        XCTAssertThrowsError(try WakaTimeCredential.readConfigured(at: file))
    }

    func testPluginConfigurationIsPreservedWhenAnAPIKeyIsRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(".wakatime.cfg")
        let original = "[settings]\napi_key = 00000000-0000-0000-0000-000000000000\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WakaTimeCredential.readConfigured(at: file)) { error in
            guard case StatusError.authentication = error else { return XCTFail("An old key must request OAuth setup") }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }

    func testPersonalTokenValidationDoesNotTreatOtherCredentialsAsOAuth() throws {
        XCTAssertEqual(try WakaTimeCredential.checkedAccessToken("  waka_tok_example\n"), "waka_tok_example")
        for value in ["", "sample-key", "waka_tok_", "waka_tok_two words", "waka_tok_a\u{0}b", "Bearer waka_tok_example"] {
            XCTAssertThrowsError(try WakaTimeCredential.checkedAccessToken(value))
        }
    }
}
