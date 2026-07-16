//
//  XMPMarkerWriter.swift
//  OpenPrompter
//
//  V3 markers — Adobe Premiere Pro native-marker output.
//
//  WHY THIS EXISTS
//  ---------------
//  The recording pipeline already writes a QuickTime chapter track and a
//  timed-metadata (`mebx`) track for every tapped mark. Neither imports into
//  Adobe Premiere Pro as a timeline marker. Ground truth (ffprobe/exiftool on
//  a founder recording that had been round-tripped through Premiere Pro 2026):
//
//    • Premiere's OWN marker/clip metadata for a `.mov` lives in the QuickTime
//      `moov` → `udta` → `XMP_` atom as an XMP packet. That inspected file had
//      an `XMP_` atom (3.9 KB) written by "Adobe Premiere Pro 2026.0" — but it
//      contained only duration / frameSize / xmpMM:History, NO marker track,
//      because our app never wrote markers in a form Premiere reads. There was
//      NO top-level `uuid` XMP box in the file at all.
//    • Premiere's native marker representation is Adobe XMP **Dynamic Media**:
//      an `xmpDM:Tracks` bag holding one track whose `xmpDM:markers` is an
//      `rdf:Seq` of markers (each with `xmpDM:startTime`, `xmpDM:duration`,
//      `xmpDM:name`).
//
//  So the fix is: after `AVAssetWriter` finalizes the `.mov`, embed an XMP
//  packet carrying an `xmpDM:Tracks` marker track into `moov/udta/XMP_` — the
//  exact atom Premiere reads/writes for a QuickTime `.mov`. (The XMP spec's
//  top-level `uuid` box — user-type BE7ACFCB-97A9-42E8-9C71-999491E3AFAC — is
//  the MP4/ISO convention; for a QuickTime `.mov` the QuickTime handler reads
//  `udta/XMP_`, which is where the inspected Premiere file stored it, so that
//  is what we target.)
//
//  TIME BASE
//  ---------
//  Marker times use Adobe's universal tick rate, 254016000 ticks/second, via
//  a track `xmpDM:frameRate` of `f254016000` and per-marker `xmpDM:startTime`
//  in ticks. 254016000 is evenly divisible by every common video frame rate
//  (24/25/30/50/60 and the 1000/1001 pulldowns) and by 44100/48000, so a
//  marker lands at the exact wall-clock instant regardless of the clip's frame
//  rate — no rounding to the wrong frame. This matches what Premiere itself
//  emits, so the markers round-trip cleanly.
//
//  SAFETY (atom surgery)
//  ---------------------
//  `RecordingSession` builds the writer with `shouldOptimizeForNetworkUse =
//  false`, so `AVAssetWriter` lays the file out as `ftyp … mdat … moov` with
//  `moov` LAST. Growing `moov` (to add/extend `udta/XMP_`) therefore never
//  shifts `mdat`, so every `stco`/`co64` chunk offset (which points into
//  `mdat`, before `moov`) stays valid — no offset fix-ups needed. The injector
//  REQUIRES `moov` to be the last top-level atom and bails (leaving the file
//  byte-for-byte untouched) on any structural surprise, so a marker write can
//  never corrupt a recording. Markers are best-effort; the video is sacred.
//

import Foundation

/// Builds a Premiere-readable Adobe XMP Dynamic Media marker packet and injects
/// it into a finished QuickTime `.mov` at `moov/udta/XMP_`. Pure/`nonisolated`
/// so it runs on the recording queue (off the main actor) and is unit-testable
/// without AVFoundation or a device.
enum XMPMarkerWriter {

    /// Adobe's universal time base: ticks per second. `xmpDM:frameRate` is
    /// emitted as `f<this>` and each marker `xmpDM:startTime` is in these ticks.
    static let adobeTickRate: Int64 = 254_016_000

    /// One marker to serialize: its file-relative offset (seconds ≥ 0) and its
    /// display name ("Marker 1", a script heading, …).
    struct MarkerPoint: Equatable, Sendable {
        var offsetSeconds: Double
        var name: String

        init(offsetSeconds: Double, name: String) {
            self.offsetSeconds = offsetSeconds
            self.name = name
        }
    }

    // MARK: - XMP packet

    /// Serialize `markers` into a full XMP packet (xpacket header + trailer,
    /// with padding) containing a single `xmpDM:Tracks` marker track. The
    /// structure mirrors what Premiere Pro emits for clip markers so it imports
    /// as native timeline markers.
    ///
    /// - Parameters:
    ///   - markers: ordered marker points (offset seconds + name).
    ///   - trackName: the marker track's `xmpDM:trackName`.
    ///   - trackType: the marker track's `xmpDM:trackType` ("Comment" is the
    ///     standard for named Premiere timeline markers).
    ///   - paddingBytes: trailing whitespace before `<?xpacket end="w"?>` so a
    ///     downstream tool can rewrite the packet in place (XMP convention).
    static func makeXMPPacket(
        markers: [MarkerPoint],
        trackName: String = "OpenPrompter Markers",
        trackType: String = "Comment",
        paddingBytes: Int = 2048
    ) -> String {
        var xml = ""
        // BOM inside the xpacket id is the XMP convention (matches Premiere).
        xml += "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
        xml += "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"OpenPrompter\">\n"
        xml += " <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        xml += "  <rdf:Description rdf:about=\"\"\n"
        xml += "    xmlns:xmpDM=\"http://ns.adobe.com/xmp/1.0/DynamicMedia/\">\n"
        xml += "   <xmpDM:Tracks>\n"
        xml += "    <rdf:Bag>\n"
        xml += "     <rdf:li rdf:parseType=\"Resource\">\n"
        xml += "      <xmpDM:trackName>\(xmlEscape(trackName))</xmpDM:trackName>\n"
        xml += "      <xmpDM:trackType>\(xmlEscape(trackType))</xmpDM:trackType>\n"
        xml += "      <xmpDM:frameRate>f\(adobeTickRate)</xmpDM:frameRate>\n"
        xml += "      <xmpDM:markers>\n"
        xml += "       <rdf:Seq>\n"
        for marker in markers {
            let ticks = ticks(forSeconds: marker.offsetSeconds)
            xml += "        <rdf:li rdf:parseType=\"Resource\">\n"
            xml += "         <xmpDM:startTime>\(ticks)</xmpDM:startTime>\n"
            xml += "         <xmpDM:duration>0</xmpDM:duration>\n"
            xml += "         <xmpDM:name>\(xmlEscape(marker.name))</xmpDM:name>\n"
            xml += "        </rdf:li>\n"
        }
        xml += "       </rdf:Seq>\n"
        xml += "      </xmpDM:markers>\n"
        xml += "     </rdf:li>\n"
        xml += "    </rdf:Bag>\n"
        xml += "   </xmpDM:Tracks>\n"
        xml += "  </rdf:Description>\n"
        xml += " </rdf:RDF>\n"
        xml += "</x:xmpmeta>\n"
        if paddingBytes > 0 {
            var pad = ""
            pad.reserveCapacity(paddingBytes + paddingBytes / 100 + 1)
            for i in 0..<paddingBytes {
                pad += " "
                if (i + 1) % 100 == 0 { pad += "\n" }
            }
            xml += pad
            xml += "\n"
        }
        xml += "<?xpacket end=\"w\"?>"
        return xml
    }

    /// Convert a non-negative second offset into Adobe ticks (rounded).
    static func ticks(forSeconds seconds: Double) -> Int64 {
        guard seconds > 0, seconds.isFinite else { return 0 }
        let value = (seconds * Double(adobeTickRate)).rounded()
        if value >= Double(Int64.max) { return Int64.max }
        return Int64(value)
    }

    /// Escape the five XML predefined entities for element text content.
    static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - MOV injection

    /// Inject `xmpPacket` into the QuickTime `.mov` at `fileURL` as an
    /// `moov/udta/XMP_` atom (creating `udta` if absent, replacing any existing
    /// `XMP_`). Only rewrites the trailing `moov` region; `mdat` and everything
    /// before `moov` are untouched, so chunk offsets stay valid.
    ///
    /// Returns `true` on success. On ANY structural surprise (no `moov`, `moov`
    /// not the last top-level atom, malformed boxes) it returns `false` and
    /// leaves the file exactly as it was — a marker write must never damage a
    /// recording.
    @discardableResult
    static func injectXMPIntoMOV(xmpPacket: Data, fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: fileURL) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return false }

        guard let moov = findTopLevelMoov(handle: handle, fileSize: fileSize) else { return false }
        // `moov` MUST be the last top-level atom — otherwise growing it would
        // shift `mdat` and invalidate every chunk offset. Bail rather than risk.
        guard moov.offset + moov.size == fileSize else { return false }
        guard moov.size <= UInt64(Int.max) else { return false }

        guard (try? handle.seek(toOffset: moov.offset)) != nil,
              let moovData = try? handle.read(upToCount: Int(moov.size)),
              moovData.count == Int(moov.size) else { return false }

        guard let newMoov = rebuildMoov(moovData: moovData, xmpPacket: xmpPacket) else { return false }

        do {
            try handle.seek(toOffset: moov.offset)
            try handle.write(contentsOf: newMoov)
            try handle.truncate(atOffset: moov.offset + UInt64(newMoov.count))
        } catch {
            return false
        }
        return true
    }

    // MARK: - Atom helpers (internal for unit tests)

    /// Scan top-level atoms and return the `moov` box's (offset, size), or nil
    /// if there is no `moov` or the box chain is malformed. Handles 32-bit,
    /// 64-bit (`size == 1`), and to-EOF (`size == 0`) box sizes.
    static func findTopLevelMoov(handle: FileHandle, fileSize: UInt64) -> (offset: UInt64, size: UInt64)? {
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
            var size = UInt64(readBE32(header, 0))
            let type = header.subdata(in: 4..<8)
            var headerLen: UInt64 = 8
            if size == 1 {
                guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else { return nil }
                size = readBE64(ext, 0)
                headerLen = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerLen, offset + size <= fileSize else { return nil }
            if type == Data("moov".utf8) {
                return (offset, size)
            }
            offset += size
        }
        return nil
    }

    /// Rebuild a `moov` atom's bytes with the marker `XMP_` atom added under
    /// `udta`. Pure `Data → Data?` so it is fully unit-testable. Returns nil on
    /// any malformed structure (caller then leaves the file untouched).
    static func rebuildMoov(moovData: Data, xmpPacket: Data) -> Data? {
        guard let (childrenStart, moovSize) = boxBodyStart(moovData, expectedType: "moov"),
              moovSize == UInt64(moovData.count) else { return nil }

        let children = moovData.subdata(in: childrenStart..<moovData.count)
        let xmpAtom = makeAtom(type: "XMP_", body: xmpPacket)

        var newChildren = Data()
        var foundUdta = false
        var index = 0
        while index + 8 <= children.count {
            guard let (childLen, childType) = boxLengthAndType(children, at: index) else { return nil }
            guard childLen >= 8, index + childLen <= children.count else { return nil }
            let childData = children.subdata(in: index..<(index + childLen))
            if childType == "udta" {
                foundUdta = true
                guard let rebuilt = udtaByAddingXMP(udtaData: childData, xmpAtom: xmpAtom) else { return nil }
                newChildren.append(rebuilt)
            } else {
                newChildren.append(childData)
            }
            index += childLen
        }
        guard index == children.count else { return nil }  // trailing garbage

        if !foundUdta {
            newChildren.append(makeAtom(type: "udta", body: xmpAtom))
        }

        let newSize = 8 + newChildren.count
        guard newSize <= Int(UInt32.max) else { return nil }
        var out = Data()
        out.append(contentsOf: beBytes32(UInt32(newSize)))
        out.append(Data("moov".utf8))
        out.append(newChildren)
        return out
    }

    /// Rebuild a `udta` atom, dropping any existing `XMP_` child and appending
    /// the new one. Returns nil on malformed structure.
    static func udtaByAddingXMP(udtaData: Data, xmpAtom: Data) -> Data? {
        guard let (bodyStart, udtaSize) = boxBodyStart(udtaData, expectedType: "udta"),
              udtaSize == UInt64(udtaData.count) else { return nil }
        let body = udtaData.subdata(in: bodyStart..<udtaData.count)

        var kept = Data()
        var index = 0
        while index + 8 <= body.count {
            guard let (childLen, childType) = boxLengthAndType(body, at: index) else { return nil }
            guard childLen >= 8, index + childLen <= body.count else { return nil }
            if childType != "XMP_" {
                kept.append(body.subdata(in: index..<(index + childLen)))
            }
            index += childLen
        }
        guard index == body.count else { return nil }
        kept.append(xmpAtom)

        let newSize = 8 + kept.count
        guard newSize <= Int(UInt32.max) else { return nil }
        var out = Data()
        out.append(contentsOf: beBytes32(UInt32(newSize)))
        out.append(Data("udta".utf8))
        out.append(kept)
        return out
    }

    /// Build a leaf atom: `[size:4][type:4][body]`. Caller guarantees the body
    /// keeps the total under 4 GiB (marker packets are a few KB).
    static func makeAtom(type: String, body: Data) -> Data {
        var out = Data()
        out.append(contentsOf: beBytes32(UInt32(8 + body.count)))
        out.append(Data(type.utf8))
        out.append(body)
        return out
    }

    /// For a box at the start of `data`, validate its type and return the body
    /// offset (past size/type, and any 64-bit largesize) plus the box size.
    /// Rejects `size == 0` (to-EOF) here — a nested box must be sized.
    private static func boxBodyStart(_ data: Data, expectedType: String) -> (bodyStart: Int, size: UInt64)? {
        guard data.count >= 8 else { return nil }
        var size = UInt64(readBE32(data, 0))
        var bodyStart = 8
        if size == 1 {
            guard data.count >= 16 else { return nil }
            size = readBE64(data, 8)
            bodyStart = 16
        }
        guard size >= UInt64(bodyStart) else { return nil }
        guard data.subdata(in: 4..<8) == Data(expectedType.utf8) else { return nil }
        return (bodyStart, size)
    }

    /// Read the child box at `offset` within `data`: its total length (bytes)
    /// and 4-char type. Handles 32/64-bit sizes; `size == 0` extends to the end
    /// of `data`. Returns nil if it runs past the end.
    private static func boxLengthAndType(_ data: Data, at offset: Int) -> (length: Int, type: String)? {
        guard offset + 8 <= data.count else { return nil }
        var size = UInt64(readBE32(data, offset))
        if size == 1 {
            guard offset + 16 <= data.count else { return nil }
            size = readBE64(data, offset + 8)
        } else if size == 0 {
            size = UInt64(data.count - offset)
        }
        guard size <= UInt64(data.count - offset) else { return nil }
        let type = String(decoding: data.subdata(in: (offset + 4)..<(offset + 8)), as: UTF8.self)
        return (Int(size), type)
    }

    // MARK: - Big-endian byte helpers

    static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    static func readBE64(_ data: Data, _ offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(data[base + i]) }
        return value
    }

    static func beBytes32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff),
         UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff),
         UInt8(value & 0xff)]
    }
}
