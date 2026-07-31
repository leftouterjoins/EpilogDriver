/*
 * PackbitsTests.swift - Unit tests for TIFF Packbits encoder
 */

import XCTest
@testable import EpilogKit

final class PackbitsTests: XCTestCase {

    func testEmptyInput() {
        let result = RasterEncoder.packbitsEncode([])
        XCTAssertEqual(result, [])
    }

    func testSingleByte() {
        let result = RasterEncoder.packbitsEncode([0x42])
        // Single byte: literal run of 1 = count-1 = 0, followed by the byte
        XCTAssertEqual(result, [0x00, 0x42])
    }

    func testRunOfTwo() {
        let result = RasterEncoder.packbitsEncode([0xAA, 0xAA])
        // Run of 2: (1 - 2) = -1 = 0xFF, followed by the byte
        XCTAssertEqual(result, [0xFF, 0xAA])
    }

    func testRunOfThree() {
        let result = RasterEncoder.packbitsEncode([0xBB, 0xBB, 0xBB])
        // Run of 3: (1 - 3) = -2 = 0xFE, followed by the byte
        XCTAssertEqual(result, [0xFE, 0xBB])
    }

    func testLiteralRun() {
        let result = RasterEncoder.packbitsEncode([0x01, 0x02, 0x03])
        // Literal run of 3: count-1 = 2, followed by bytes
        XCTAssertEqual(result, [0x02, 0x01, 0x02, 0x03])
    }

    func testMixedRunsAndLiterals() {
        // 0x00, 0x00, 0x00 (run of 3) + 0x01, 0x02 (literals) + 0xFF, 0xFF (run of 2)
        let input: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x02, 0xFF, 0xFF]
        let result = RasterEncoder.packbitsEncode(input)

        // Expected:
        // Run of 3 zeros: 0xFE, 0x00
        // Literal 0x01, 0x02: 0x01, 0x01, 0x02
        // Run of 2 0xFF: 0xFF, 0xFF
        XCTAssertEqual(result, [0xFE, 0x00, 0x01, 0x01, 0x02, 0xFF, 0xFF])
    }

    func testAllZeros() {
        let input = [UInt8](repeating: 0x00, count: 10)
        let result = RasterEncoder.packbitsEncode(input)
        // Run of 10: (1 - 10) = -9 = 0xF7, followed by 0x00
        XCTAssertEqual(result, [0xF7, 0x00])
    }

    func testMaxRunLength() {
        // Maximum run length is 128
        let input = [UInt8](repeating: 0x55, count: 200)
        let result = RasterEncoder.packbitsEncode(input)

        // First run of 128: (1 - 128) = -127 = 0x81, 0x55
        // Second run of 72: (1 - 72) = -71 = 0xB9, 0x55
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0], 0x81) // -127
        XCTAssertEqual(result[1], 0x55)
        XCTAssertEqual(result[2], 0xB9) // -71
        XCTAssertEqual(result[3], 0x55)
    }
}
