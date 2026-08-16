import Foundation
import ImageIO

/// 인스펙터에 보여줄 파일·촬영 정보 (EXIF)
struct PhotoInfo: Sendable {
    var camera: String?
    var lensModel: String?
    var fNumber: Double?
    var exposureTime: Double?
    var iso: Int?
    var focalLength: Double?
    var dateTimeOriginal: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileSizeBytes: Int?

    var shutterText: String? {
        guard let time = exposureTime, time > 0 else { return nil }
        return time >= 1 ? String(format: "%.1f초", time) : "1/\(Int((1 / time).rounded()))초"
    }

    var fileSizeText: String? {
        fileSizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    var resolutionText: String? {
        guard let width = pixelWidth, let height = pixelHeight else { return nil }
        return "\(width) × \(height) (\(String(format: "%.1f", Double(width * height) / 1_000_000))MP)"
    }

    var dateText: String? {
        // EXIF "2026:08:14 18:42:04" → "2026-08-14 18:42"
        guard let raw = dateTimeOriginal, raw.count >= 16 else { return dateTimeOriginal }
        let date = raw.prefix(10).replacingOccurrences(of: ":", with: "-")
        let start = raw.index(raw.startIndex, offsetBy: 11)
        let end = raw.index(start, offsetBy: 5)
        return "\(date) \(raw[start..<end])"
    }

    static func load(url: URL) -> PhotoInfo {
        var info = PhotoInfo()
        info.fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return info }
        info.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        info.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            info.camera = (tiff[kCGImagePropertyTIFFModel] as? String)
                ?? (tiff[kCGImagePropertyTIFFMake] as? String)
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            info.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
            info.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
            info.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first as? Int
            info.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            info.dateTimeOriginal = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            info.lensModel = exif[kCGImagePropertyExifLensModel] as? String
        }
        return info
    }
}
