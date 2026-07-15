import XCTest

final class NDJSONFramingTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testSingleLineOneFeed() throws {
        var f = NDJSONLineFramer()
        let lines = try f.feed(bytes("{\"a\":1}\n"))
        XCTAssertEqual(lines, [Data("{\"a\":1}".utf8)])
        XCTAssertEqual(f.pendingBytes, 0)
    }

    func testMultipleLinesOneFeed() throws {
        var f = NDJSONLineFramer()
        let lines = try f.feed(bytes("{\"a\":1}\n{\"b\":2}\n"))
        XCTAssertEqual(lines, [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
    }

    func testLineSplitAcrossFeeds() throws {
        var f = NDJSONLineFramer()
        XCTAssertEqual(try f.feed(bytes("{\"a\":")), [])
        XCTAssertEqual(f.pendingBytes, 5)
        XCTAssertEqual(try f.feed(bytes("1}\n")), [Data("{\"a\":1}".utf8)])
    }

    func testLineSplitByteByByte() throws {
        var f = NDJSONLineFramer()
        var out: [Data] = []
        for b in bytes("{\"a\":1}\n{\"b\":2}\n") {
            out.append(contentsOf: try f.feed([b]))
        }
        XCTAssertEqual(out, [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
    }

    func testCRLFTolerated() throws {
        var f = NDJSONLineFramer()
        let lines = try f.feed(bytes("{\"a\":1}\r\n{\"b\":2}\r\n"))
        XCTAssertEqual(lines, [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
    }

    func testEmptyLinesSkipped() throws {
        var f = NDJSONLineFramer()
        let lines = try f.feed(bytes("\n\n{\"a\":1}\n\n"))
        XCTAssertEqual(lines, [Data("{\"a\":1}".utf8)])
    }

    func testOversizedLineRejected() {
        var f = NDJSONLineFramer()
        let big = [UInt8](repeating: 0x61, count: NDJSONLineFramer.maxLineBytes + 1)
        XCTAssertThrowsError(try f.feed(big)) {
            XCTAssertEqual($0 as? NDJSONLineFramer.FramingError,
                           .lineTooLong(limit: NDJSONLineFramer.maxLineBytes))
        }
        // After a violation the framer resets; it must not keep the poisoned buffer.
        XCTAssertEqual(f.pendingBytes, 0)
    }

    func testLineExactlyAtLimitAccepted() throws {
        var f = NDJSONLineFramer()
        let payload = [UInt8](repeating: 0x61, count: NDJSONLineFramer.maxLineBytes)
        let lines = try f.feed(payload + bytes("\n"))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.count, NDJSONLineFramer.maxLineBytes)
    }

    func testFinishReturnsUnterminatedRemainder() throws {
        var f = NDJSONLineFramer()
        XCTAssertEqual(try f.feed(bytes("{\"a\":1}\n{\"partial\":")),
                       [Data("{\"a\":1}".utf8)])
        XCTAssertEqual(f.finish(), Data("{\"partial\":".utf8))
        XCTAssertNil(f.finish())
    }

    func testFinishWithoutRemainder() {
        var f = NDJSONLineFramer()
        XCTAssertNil(f.finish())
    }

    func testEncoderAppendsNewline() {
        let out = NDJSONLineEncoder.encode(Data("{\"a\":1}".utf8))
        XCTAssertEqual(out, Data("{\"a\":1}\n".utf8))
    }
}
