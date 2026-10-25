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
        try "[settings]\napi_key = example-token\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try WakaTimeCredential.readConfigured(at: file), "example-token")
        try Data(repeating: 65, count: 65_537).write(to: file)
        XCTAssertThrowsError(try WakaTimeCredential.readConfigured(at: file))
    }
}
