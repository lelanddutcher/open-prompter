//
//  XMPMarkerWriterTests.swift
//  OpenPrompterTests
//
//  Unit tests for the V3 Premiere-marker deliverable:
//
//    - XMPMarkerWriter.makeXMPPacket: well-formed XML, correct marker count,
//      per-marker startTime (Adobe ticks) + name, track type / frame rate,
//      and XML escaping of special characters.
//    - XMPMarkerWriter.ticks(forSeconds:): tick conversion + clamping.
//    - orderedMarkerPoints: sort, auto-number "Marker N", file-relative offsets
//      (shared numbering with buildChapterSegments).
//    - XMPMarkerWriter atom injection: rebuildMoov / udtaByAddingXMP produce a
//      valid moov/udta/XMP_ box structure; injectXMPIntoMOV on a synthetic
//      `.mov` leaves ftyp + mdat byte-identical (chunk offsets preserved) and
//      refuses (untouched) when moov isn't the last top-level atom.
//    - ChapterTextTrack.textSamplePayload: QuickTime text sample byte layout.
//
//  No device, no AVAssetWriter — every path here is pure value-in / value-out.
//

import XCTest
import AVFoundation
@testable import OpenPrompter

final class XMPMarkerWriterTests: XCTestCase {

    // MARK: - Helpers

    private func points(_ pairs: [(Double, String)]) -> [XMPMarkerWriter.MarkerPoint] {
        pairs.map { XMPMarkerWriter.MarkerPoint(offsetSeconds: $0.0, name: $0.1) }
    }

    /// Extract just the `<x:xmpmeta>…</x:xmpmeta>` core so XMLParser validates
    /// the RDF without the surrounding `<?xpacket?>` processing instructions.
    private func core(of packet: String) -> String {
        guard let start = packet.range(of: "<x:xmpmeta"),
              let end = packet.range(of: "</x:xmpmeta>") else {
            return packet
        }
        return String(packet[start.lowerBound..<end.upperBound])
    }

    // MARK: - XMP packet: structure

    func testPacketHasXPacketFraming() {
        let packet = XMPMarkerWriter.makeXMPPacket(markers: points([(1.0, "Marker 1")]))
        XCTAssertTrue(packet.contains("<?xpacket begin="))
        XCTAssertTrue(packet.contains("id=\"W5M0MpCehiHzreSzNTczkc9d\""))
        XCTAssertTrue(packet.hasSuffix("<?xpacket end=\"w\"?>"))
        XCTAssertTrue(packet.contains("http://ns.adobe.com/xmp/1.0/DynamicMedia/"))
    }

    func testPacketTrackTypeAndFrameRate() {
        let packet = XMPMarkerWriter.makeXMPPacket(markers: points([(1.0, "A")]))
        XCTAssertTrue(packet.contains("<xmpDM:trackType>Comment</xmpDM:trackType>"))
        XCTAssertTrue(packet.contains("<xmpDM:frameRate>f254016000</xmpDM:frameRate>"))
        XCTAssertTrue(packet.contains("<xmpDM:Tracks>"))
        XCTAssertTrue(packet.contains("<xmpDM:markers>"))
    }

    func testPacketIsWellFormedXML() {
        let packet = XMPMarkerWriter.makeXMPPacket(
            markers: points([(0.5, "Intro"), (2.5, "Verse"), (9.0, "Outro")])
        )
        let parser = XMLParser(data: Data(core(of: packet).utf8))
        XCTAssertTrue(parser.parse(), "XMP core should parse as well-formed XML")
        XCTAssertNil(parser.parserError)
    }

    func testPacketMarkerCountNamesAndStartTimes() {
        let input = points([(0.0, "Marker 1"), (5.0, "Chorus"), (10.0, "Marker 3")])
        let packet = XMPMarkerWriter.makeXMPPacket(markers: input)

        let collector = XMPCollector()
        let parser = XMLParser(data: Data(core(of: packet).utf8))
        parser.delegate = collector
        XCTAssertTrue(parser.parse())

        XCTAssertEqual(collector.names, ["Marker 1", "Chorus", "Marker 3"])
        // 254016000 ticks/sec: 0s → 0, 5s → 1270080000, 10s → 2540160000.
        XCTAssertEqual(collector.startTimes, ["0", "1270080000", "2540160000"])
        XCTAssertEqual(collector.durations, ["0", "0", "0"])
    }

    func testPacketEscapesSpecialCharacters() {
        let packet = XMPMarkerWriter.makeXMPPacket(
            markers: points([(1.0, "R&D <take> \"one\" 'go'")])
        )
        XCTAssertTrue(packet.contains("R&amp;D &lt;take&gt; &quot;one&quot; &apos;go&apos;"))
        // The raw ampersand/angle brackets must NOT appear unescaped in content.
        XCTAssertFalse(packet.contains(">R&D <take>"))
        // And the escaped packet must still be well-formed.
        let parser = XMLParser(data: Data(core(of: packet).utf8))
        XCTAssertTrue(parser.parse())
    }

    func testEmptyMarkersStillWellFormed() {
        let packet = XMPMarkerWriter.makeXMPPacket(markers: [])
        let parser = XMLParser(data: Data(core(of: packet).utf8))
        XCTAssertTrue(parser.parse())
        XCTAssertFalse(packet.contains("<rdf:li rdf:parseType=\"Resource\">\n         <xmpDM:startTime>"))
    }

    // MARK: - Tick conversion

    func testTicksForSeconds() {
        XCTAssertEqual(XMPMarkerWriter.ticks(forSeconds: 0), 0)
        XCTAssertEqual(XMPMarkerWriter.ticks(forSeconds: -3), 0)
        XCTAssertEqual(XMPMarkerWriter.ticks(forSeconds: 1), 254_016_000)
        XCTAssertEqual(XMPMarkerWriter.ticks(forSeconds: 5), 1_270_080_000)
        // 1/24 s at 24fps → an exact integer tick count (no rounding drift).
        XCTAssertEqual(XMPMarkerWriter.ticks(forSeconds: 1.0 / 24.0), 254_016_000 / 24)
    }

    // MARK: - orderedMarkerPoints

    private func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    func testOrderedMarkerPointsSortsAndAutoNumbers() {
        let start = time(10)
        let markers = [
            RecordingMarker(time: time(14), title: nil),        // manual
            RecordingMarker(time: time(11), title: "Heading A"), // script
            RecordingMarker(time: time(13), title: nil)         // manual
        ]
        let pts = orderedMarkerPoints(from: markers, sessionStart: start, lastPTS: time(20))
        XCTAssertEqual(pts.map { $0.name }, ["Heading A", "Marker 1", "Marker 2"])
        // Offsets are file-relative (time − sessionStart).
        XCTAssertEqual(pts.map { $0.offsetSeconds }, [1, 3, 4])
    }

    func testOrderedMarkerPointsClampsAndHandlesInvalid() {
        let start = time(0)
        let markers = [
            RecordingMarker(time: .invalid, title: "Warmup"),   // → sessionStart (0)
            RecordingMarker(time: time(99), title: "Late")      // clamped to lastPTS
        ]
        let pts = orderedMarkerPoints(from: markers, sessionStart: start, lastPTS: time(8))
        XCTAssertEqual(pts.map { $0.name }, ["Warmup", "Late"])
        XCTAssertEqual(pts[0].offsetSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(pts[1].offsetSeconds, 8, accuracy: 0.001)
    }

    func testOrderedMarkerPointsEmptyForNoMarkers() {
        XCTAssertTrue(orderedMarkerPoints(from: [], sessionStart: time(0), lastPTS: time(5)).isEmpty)
    }

    // MARK: - Atom injection (pure moov rebuild)

    func testRebuildMoovCreatesUdtaXMPWhenAbsent() {
        // moov with a single 'mvhd' stub child, no udta.
        let mvhd = box("mvhd", Data([0x01, 0x02, 0x03, 0x04]))
        let moov = box("moov", mvhd)
        let xmp = Data("XMPDATA".utf8)

        guard let rebuilt = XMPMarkerWriter.rebuildMoov(moovData: moov, xmpPacket: xmp) else {
            return XCTFail("rebuildMoov returned nil")
        }
        // Result is a valid moov whose declared size matches its bytes.
        let top = walk(rebuilt)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].type, "moov")
        XCTAssertEqual(top[0].size, rebuilt.count)

        let children = walk(bodyOf(rebuilt, boxAt: 0))
        XCTAssertEqual(children.map { $0.type }, ["mvhd", "udta"])

        // udta → XMP_ carrying our exact packet bytes.
        let xmpRaw = child(rebuilt, path: ["moov", "udta", "XMP_"])
        XCTAssertEqual(bodyOf(xmpRaw, boxAt: 0), xmp)
    }

    func testRebuildMoovPreservesExistingUdtaChildren() {
        let cprt = box("cprt", Data("copyright".utf8))
        let udta = box("udta", cprt)
        let mvhd = box("mvhd", Data([0x00, 0x00]))
        let moov = box("moov", mvhd + udta)
        let xmp = Data("PACKET".utf8)

        guard let rebuilt = XMPMarkerWriter.rebuildMoov(moovData: moov, xmpPacket: xmp) else {
            return XCTFail("rebuildMoov returned nil")
        }
        let newUdta = child(rebuilt, path: ["moov", "udta"])
        let udtaChildren = walk(bodyOf(newUdta, boxAt: 0)).map { $0.type }
        // Existing cprt preserved, XMP_ appended.
        XCTAssertEqual(udtaChildren, ["cprt", "XMP_"])
        // Declared udta size == actual bytes (parent size fix-up correct).
        XCTAssertEqual(walk(bodyOf(rebuilt, boxAt: 0)).first { $0.type == "udta" }?.size, newUdta.count)
    }

    func testRebuildMoovReplacesExistingXMP() {
        let oldXMP = box("XMP_", Data("OLD".utf8))
        let udta = box("udta", oldXMP)
        let moov = box("moov", udta)

        guard let rebuilt = XMPMarkerWriter.rebuildMoov(moovData: moov, xmpPacket: Data("NEW".utf8)) else {
            return XCTFail("rebuildMoov returned nil")
        }
        let newUdta = child(rebuilt, path: ["moov", "udta"])
        let xmpBoxes = walk(bodyOf(newUdta, boxAt: 0)).filter { $0.type == "XMP_" }
        XCTAssertEqual(xmpBoxes.count, 1, "the stale XMP_ should be replaced, not duplicated")
    }

    // MARK: - Atom injection (full file)

    func testInjectIntoMovAppendsXMPAndPreservesMdat() throws {
        let ftyp = box("ftyp", Data("qt  ".utf8) + Data([0, 0, 0, 0]))
        let mdat = box("mdat", Data(repeating: 0xAB, count: 32))
        let moov = box("moov", box("mvhd", Data([0x11, 0x22, 0x33, 0x44])))
        let original = ftyp + mdat + moov

        let url = try writeTemp(original)
        defer { try? FileManager.default.removeItem(at: url) }

        let ok = XMPMarkerWriter.injectXMPIntoMOV(xmpPacket: Data("HELLO-XMP".utf8), fileURL: url)
        XCTAssertTrue(ok)

        let after = try Data(contentsOf: url)
        // ftyp + mdat bytes are byte-identical (chunk offsets into mdat valid).
        XCTAssertEqual(after.prefix(ftyp.count + mdat.count), original.prefix(ftyp.count + mdat.count))
        // File grew (moov gained a udta/XMP_).
        XCTAssertGreaterThan(after.count, original.count)

        // Top-level structure still ftyp, mdat, moov (moov last).
        let top = walk(after)
        XCTAssertEqual(top.map { $0.type }, ["ftyp", "mdat", "moov"])
        XCTAssertEqual(top.last!.offset + top.last!.size, after.count, "moov must remain the last atom")

        // moov/udta/XMP_ carries the packet.
        let moovData = after.subdata(in: top.last!.offset..<(top.last!.offset + top.last!.size))
        let udta = child(moovData, path: ["moov", "udta"])
        let udtaBody = bodyOf(udta, boxAt: 0)
        let idx = walk(udtaBody).firstIndex { $0.type == "XMP_" }
        XCTAssertNotNil(idx)
        XCTAssertEqual(bodyOf(udtaBody, boxAt: idx!), Data("HELLO-XMP".utf8))
    }

    func testInjectRefusesWhenMoovNotLast() throws {
        // moov BEFORE mdat — growing it would shift mdat, so the injector must
        // refuse and leave the file untouched.
        let ftyp = box("ftyp", Data("qt  ".utf8))
        let moov = box("moov", box("mvhd", Data([0x01])))
        let mdat = box("mdat", Data(repeating: 0x7F, count: 16))
        let original = ftyp + moov + mdat

        let url = try writeTemp(original)
        defer { try? FileManager.default.removeItem(at: url) }

        let ok = XMPMarkerWriter.injectXMPIntoMOV(xmpPacket: Data("X".utf8), fileURL: url)
        XCTAssertFalse(ok)
        XCTAssertEqual(try Data(contentsOf: url), original, "file must be untouched on refusal")
    }

    func testInjectRefusesFileWithoutMoov() throws {
        let original = box("ftyp", Data("qt  ".utf8)) + box("mdat", Data([1, 2, 3, 4]))
        let url = try writeTemp(original)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(XMPMarkerWriter.injectXMPIntoMOV(xmpPacket: Data("X".utf8), fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    // MARK: - Chapter text sample payload

    func testChapterTextSamplePayloadLayout() {
        let payload = ChapterTextTrack.textSamplePayload(for: "Hi")
        // [uint16 len=2]['H','i']['encd' atom: 00 00 00 0C 'encd' 08 00 01 00]
        XCTAssertEqual([UInt8](payload.prefix(2)), [0x00, 0x02])
        XCTAssertEqual([UInt8](payload.subdata(in: 2..<4)), Array("Hi".utf8))
        let encd = payload.subdata(in: 4..<payload.count)
        XCTAssertEqual([UInt8](encd), [0x00, 0x00, 0x00, 0x0C, 0x65, 0x6E, 0x63, 0x64, 0x08, 0x00, 0x01, 0x00])
    }

    func testChapterTextSampleLengthPrefixMatchesUTF8ByteCount() {
        let payload = ChapterTextTrack.textSamplePayload(for: "café")   // 5 UTF-8 bytes
        XCTAssertEqual([UInt8](payload.prefix(2)), [0x00, 0x05])
    }

    // MARK: - MOV box test utilities

    /// Build a box: `[size:4][type:4][body]` (32-bit size only — test boxes are
    /// small).
    private func box(_ type: String, _ body: Data) -> Data {
        var d = Data()
        let size = UInt32(8 + body.count)
        d.append(contentsOf: [UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
                              UInt8((size >> 8) & 0xff), UInt8(size & 0xff)])
        d.append(Data(type.utf8))
        d.append(body)
        return d
    }

    private struct Box { let type: String; let offset: Int; let size: Int }

    /// Walk top-level boxes of `data` (32-bit sizes; sufficient for tests).
    private func walk(_ data: Data) -> [Box] {
        var boxes: [Box] = []
        var off = 0
        while off + 8 <= data.count {
            let size = Int(be32(data, off))
            let type = String(decoding: data.subdata(in: (off + 4)..<(off + 8)), as: UTF8.self)
            guard size >= 8, off + size <= data.count else { break }
            boxes.append(Box(type: type, offset: off, size: size))
            off += size
        }
        return boxes
    }

    /// Body bytes (past the 8-byte header) of the box at index `boxAt` in `data`.
    private func bodyOf(_ data: Data, boxAt: Int) -> Data {
        let boxes = walk(data)
        let b = boxes[boxAt]
        return data.subdata(in: (b.offset + 8)..<(b.offset + b.size))
    }

    /// Return the raw bytes of a nested box by type path, e.g. ["moov","udta"].
    private func child(_ data: Data, path: [String]) -> Data {
        var current = data
        for (i, type) in path.enumerated() {
            let boxes = walk(current)
            guard let b = boxes.first(where: { $0.type == type }) else {
                XCTFail("missing box \(type)"); return Data()
            }
            let raw = current.subdata(in: b.offset..<(b.offset + b.size))
            if i == path.count - 1 { return raw }
            current = current.subdata(in: (b.offset + 8)..<(b.offset + b.size))
        }
        return current
    }

    private func be32(_ d: Data, _ off: Int) -> UInt32 {
        let b = d.startIndex + off
        return (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmpmarker-\(UUID().uuidString).mov")
        try data.write(to: url)
        return url
    }
}

/// Collects `xmpDM:name`, `xmpDM:startTime`, `xmpDM:duration` element text from
/// a parsed marker packet.
private final class XMPCollector: NSObject, XMLParserDelegate {
    var names: [String] = []
    var startTimes: [String] = []
    var durations: [String] = []
    private var current = ""
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        current = qName ?? elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "xmpDM:name": names.append(value)
        case "xmpDM:startTime": startTimes.append(value)
        case "xmpDM:duration": durations.append(value)
        default: break
        }
        buffer = ""
    }
}
