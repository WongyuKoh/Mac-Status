import XCTest
@testable import MacStatus

final class SystemMetricsTests: XCTestCase {
    func testSMCTemperatureFormats() {
        XCTAssertEqual(SMCValueDecoder.temperature(bytes: [0x32, 0x80], type: "sp78"), 50.5)
        XCTAssertEqual(SMCValueDecoder.temperature(bytes: [0xFF, 0x80], type: "sp78"), -0.5)
        XCTAssertEqual(SMCValueDecoder.temperature(bytes: [0, 0, 0x48, 0x42], type: "flt "), 50)
        XCTAssertNil(SMCValueDecoder.temperature(bytes: [0], type: "sp78"))
        XCTAssertNil(SMCValueDecoder.temperature(bytes: [0, 0, 0xC0, 0x7F], type: "flt "))
        XCTAssertNil(SMCValueDecoder.temperature(bytes: [0, 0], type: "ui16"))
    }

    func testPhysicalMemoryAndStorageAreBounded() {
        let metrics = SystemMetrics()
        for kind in [MetricKind.memory, .storage] {
            let reading = metrics.read(kind)
            XCTAssertEqual(reading.state, .ready, "\(kind): \(reading.subtitle)")
            XCTAssertGreaterThan(reading.limit ?? 0, 0)
            XCTAssertGreaterThanOrEqual(reading.value ?? -1, 0)
            XCTAssertLessThanOrEqual(reading.value ?? .infinity, reading.limit ?? 0)
        }
    }

    func testThermalFallbackLabelsRemainDistinct() {
        XCTAssertEqual(SystemMetrics.thermalLabel(.nominal), "정상")
        XCTAssertEqual(SystemMetrics.thermalLabel(.fair), "따뜻함")
        XCTAssertEqual(SystemMetrics.thermalLabel(.serious), "높음")
        XCTAssertEqual(SystemMetrics.thermalLabel(.critical), "매우 높음")
    }
}
