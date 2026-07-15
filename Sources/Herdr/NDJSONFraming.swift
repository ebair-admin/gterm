import Foundation

/// NDJSON framing for herdr's socket: messages are single JSON objects separated
/// by `\n`, one request/response/event per line.
///
/// This core is deliberately a PURE, NIO-free value type: the hermetic test
/// target compiles `Sources/Herdr` without linking NIO (spec §1.5/§5.5), and
/// framing is the most heavily unit-tested part of the module (spec §5.2). The
/// thin `ByteToMessageDecoder` adapter that feeds it inside the app lives next
/// to the bridge (`Sources/SSH/HerdrBridgeChannel.swift`).
///
/// Error policy (spec §5.2): an oversized line is a CONNECTION error — the
/// caller tears the channel down — never a crash.
struct NDJSONLineFramer {
    /// Hard cap on one line's bytes (spec §5.2). herdr responses are small; the
    /// cap exists to bound memory if a peer (or a shell greeting polluting the
    /// exec channel) starts streaming unterminated garbage.
    static let maxLineBytes = 1_048_576

    enum FramingError: Error, Equatable {
        case lineTooLong(limit: Int)
    }

    private var buffer = Data()

    /// Bytes currently held without a terminating newline (diagnostics only).
    var pendingBytes: Int { buffer.count }

    /// Feed inbound bytes; returns every complete line terminated in (or before)
    /// this chunk, WITHOUT the trailing `\n`. A trailing `\r` is stripped so
    /// CRLF-speaking peers are tolerated (spec §5.2). Lines may arrive split
    /// across any number of feeds, or several per feed. Empty lines are skipped.
    ///
    /// Throws `lineTooLong` when buffered bytes exceed the cap with no newline;
    /// the framer is then reset and must not be reused for this connection.
    mutating func feed(_ bytes: some Sequence<UInt8>) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) { // '\n'
            var line = buffer[buffer.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() } // tolerate CRLF
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = buffer[buffer.index(after: nl)...]
        }
        guard buffer.count <= Self.maxLineBytes else {
            buffer.removeAll()
            throw FramingError.lineTooLong(limit: Self.maxLineBytes)
        }
        return lines
    }

    /// Connection reached EOF. Returns leftover unterminated bytes, if any —
    /// herdr always newline-terminates, so a non-empty remainder is protocol
    /// garbage the caller should log (metadata only) and discard.
    mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        if buffer.last == 0x0D { buffer = buffer.dropLast() }
        return buffer
    }
}

enum NDJSONLineEncoder {
    /// Outbound framing: exactly one JSON line, `\n`-terminated (spec §5.2).
    static func encode(_ line: Data) -> Data {
        var out = line
        out.append(0x0A)
        return out
    }
}
