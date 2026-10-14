import Foundation

@main
struct FileSizeRegression {
    static func main() throws {
        let sizes: [UInt64] = [0, 42, UInt64(UInt32.max), UInt64(UInt32.max) + 1,
                               10 * 1024 * 1024 * 1024, 5 * 1024 * 1024 * 1024 * 1024]
        let entries = sizes.enumerated().map { index, size in
            LegacyDirectoryEntry(name: Data("file-\(index).iso".utf8), size: size,
                                 timestamp: 123, fileType: 0, creator: 0, flags: 0)
        } + [LegacyDirectoryEntry(name: Data("folder".utf8), size: 7, timestamp: 123,
                                  fileType: 0x464c4452, creator: 0, flags: LegacyDirectoryFlags.folder)]
        let listing = LegacyDirectoryListing(currentPath: Data("shared".utf8), entries: entries)
        let classicPayload = try listing.encoded()
        var decoded = try LegacyDirectoryListing.decode(classicPayload)
        precondition(decoded.entries.map(\.size) == entries.map { UInt64(UInt32(clamping: $0.size)) },
                     "Classic replies retain their 32-bit sizes and fallback behavior")
        // A modern extension augments the unchanged Classic payload.
        try ModernFileSizeField.applyDirectorySizes(ModernFileSizeField.encodeDirectorySizes(entries), to: &decoded)
        precondition(decoded == listing, "Modern listings must retain exact sizes above 4 GiB")
        let reencoded = try decoded.encoded()
        precondition(reencoded == classicPayload, "Modern metadata must not alter Classic bytes")

        var offset = 0
        var combined: [LegacyDirectoryEntry] = []
        repeat {
            let page = try listing.page(startingAt: offset, maximumEncodedBytes: 90)
            var decodedPage = try LegacyDirectoryListing.decode(page.listing.encoded())
            try ModernFileSizeField.applyDirectorySizes(ModernFileSizeField.encodeDirectorySizes(page.listing.entries),
                                                        to: &decodedPage)
            combined += decodedPage.entries
            guard let next = page.nextOffset else { break }
            offset = next
        } while true
        precondition(combined == entries, "Size metadata must match each paginated entry")
        for size in sizes {
            let metadata = LegacyFileInfoMetadata(flags: 0, size: size, created: 11, modified: 22,
                                                  finderInfo: Data(repeating: 0, count: 16))
            let classic = try metadata.encoded()
            precondition(classic.count == 30, "File info must keep its historical layout")
            let decodedMetadata = try LegacyFileInfoMetadata.decode(classic)
            precondition(decodedMetadata.size == UInt64(UInt32(clamping: size)))
            let modernSize = try ModernFileSizeField.decodeSize(LegacyWire.uint64BE(size))
            precondition(modernSize == size, "Modern file info must retain the full size")
        }
        for malformed in [Data(), Data(repeating: 0, count: entries.count * 8 - 1),
                          Data(repeating: 0, count: entries.count * 8 + 1)] {
            do {
                try ModernFileSizeField.applyDirectorySizes(malformed, to: &decoded)
                fatalError("Invalid directory-size payload accepted")
            } catch is LegacyProtocolError {}
        }
        for count in [0, 7, 9] {
            do {
                _ = try ModernFileSizeField.decodeSize(Data(repeating: 0, count: count))
                fatalError("Invalid file-info size accepted")
            } catch is LegacyProtocolError {}
        }
        let classicQuery = LegacyFileSearchQuery(text: Data("large.iso".utf8))
        let modernQuery = LegacyFileSearchQuery(text: classicQuery.text, supports64BitSizes: true)
        let decodedClassicQuery = try LegacyFileSearchQuery.decode(classicQuery.encoded())
        let decodedModernQuery = try LegacyFileSearchQuery.decode(modernQuery.encoded())
        precondition(!decodedClassicQuery.supports64BitSizes && decodedModernQuery.supports64BitSizes)
        for modernSizes in [false, true] {
            let result = LegacyFileSearchResult(name: Data("large.iso".utf8), creator: 0, fileType: 0,
                                                size: sizes[4], timestamp: 123, path: Data("large.iso".utf8))
            var cursor = LegacyByteCursor(try LegacyFileSearchTransfer.resultFrame([result], modernSizes: modernSizes))
            let signal = try cursor.readUInt8()
            let count = try cursor.readUInt32BE()
            let format = try cursor.readUInt32BE()
            precondition(signal == 1 && count == 1 && format == (modernSizes ? 1 : 0))
            let nameLength = Int(try cursor.readUInt8())
            _ = try cursor.readBytes(count: nameLength + 8)
            let size = modernSizes ? try cursor.readUInt64BE() : UInt64(try cursor.readUInt32BE())
            precondition(size == (modernSizes ? result.size : UInt64(UInt32.max)))
            _ = try cursor.readUInt32BE()
            let path = try cursor.readString16()
            precondition(path == result.path)
            try cursor.requireEnd()
            precondition(result.directoryEntry.size == result.size)
        }
        var empty = LegacyDirectoryListing(currentPath: Data(), entries: [])
        try ModernFileSizeField.applyDirectorySizes(Data(), to: &empty)
        print("PASS: exact modern file sizes, Classic compatibility, pagination, and malformed payloads")
    }
}
