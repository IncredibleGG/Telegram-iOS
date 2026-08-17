import Foundation
import AVFoundation
import UIKit

// LuminaGram: strip photo metadata / EXIF on send (privacy bucket). Lives in this module,
// rather than TelegramUIPreferences alongside the rest of the Lumina* files, because the
// call sites that need it (FetchPhotoLibraryImageResource.swift in LocalMediaResources,
// LegacyMediaPickers.swift in LegacyMediaPickerUI) already depend on ImageCompression for
// compressImageToJPEG/compressImage - this adds zero new BUILD dependency edges for either
// of them. The *setting* (LuminaSettingsCache.settings.stripPhotoMetadata) is read by the
// callers, one layer up, which do already depend on TelegramUIPreferences or gained that
// dependency alongside this feature; this file itself only knows how to strip, never whether.
//
// WHY ImageIO's container-level properties API rather than decode-and-recompress. Both
// compressImageToJPEG and compressImage(_:quality:) in ImageCompression.swift (this same
// module) already build their output from image.cgImage - a decoded pixel buffer, which
// never carried EXIF/GPS/TIFF to begin with - so *those* paths are already metadata-free by
// construction. But that only covers photos that get recompressed at all: a "send without
// compression" / "send as file" path can upload a picked asset's ORIGINAL bytes untouched,
// which is exactly the gap desktop's lumina_exif_strip.cpp documents as "leakier still" for
// its own C++ upload pipeline. This function is for that gap: it edits the container's
// metadata dictionaries in place via CGImageDestinationAddImageFromSource, WITHOUT decoding
// or re-encoding the pixel data - so unlike a UIImage round trip it costs no quality or
// dimensions, and unlike desktop's hand-rolled JPEG/TIFF-IFD parser it works on any format
// ImageIO can read (JPEG, HEIC, PNG, TIFF) because ImageIO owns the parsing, not this file.
//
// WHAT IS REMOVED. GPS (location) + EXIF (camera make/model/lens/serial number/sub-second
// timestamps) + TIFF (the container-level camera make/model some formats duplicate there).
// Broader than desktop, which only zeroes GPS and deliberately leaves camera info alone; this
// bucket's brief is "location + camera info", so both are dropped here.
//
// WHAT IS DELIBERATELY NOT TOUCHED. Orientation lives in the top-level image properties
// dictionary (kCGImagePropertyOrientation), not inside GPS/EXIF/TIFF, so it survives
// untouched and a stripped photo still renders the right way up - the same property desktop's
// parser goes out of its way to preserve. IPTC/XMP location fields are not read by this
// function either (ImageIO exposes them under separate dictionary keys this file does not
// list), matching desktop's own documented gap for non-EXIF location carriers.
public enum LuminaExifStripResult {
    case unchanged // Parsed fine, no GPS/EXIF/TIFF dictionary present - nothing to remove.
    case stripped  // At least one of GPS/EXIF/TIFF was present and has been dropped.
    case failed    // Not an ImageIO-readable image, or ImageIO could not re-encode it.
}

public enum LuminaExifStrip {
    // The parser/editor, on its own - the thing worth reasoning about in isolation. Never
    // throws; classifies instead, exactly like desktop's StripResult, so a caller can decide
    // what "could not strip" should mean for its own upload path.
    public static func stripLocationAndCameraInfo(_ data: Data) -> (result: LuminaExifStripResult, data: Data) {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return (.failed, data)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let type = CGImageSourceGetType(source) else {
            return (.failed, data)
        }
        guard let originalProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            // No readable properties at all - nothing to strip, and nothing to fail on either.
            return (.unchanged, data)
        }

        let gpsKey = kCGImagePropertyGPSDictionary as String
        let exifKey = kCGImagePropertyExifDictionary as String
        let tiffKey = kCGImagePropertyTIFFDictionary as String

        let hasAnything = originalProperties[gpsKey] != nil || originalProperties[exifKey] != nil || originalProperties[tiffKey] != nil
        if !hasAnything {
            return (.unchanged, data)
        }

        // Setting a key to kCFNull here tells CGImageDestinationAddImageFromSource to drop
        // that dictionary from the output rather than copy it from the source - the
        // documented ImageIO idiom for removing metadata without decoding pixels.
        let removalProperties: [String: Any] = [
            gpsKey: kCFNull,
            exifKey: kCFNull,
            tiffKey: kCFNull,
        ]

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, count, nil) else {
            return (.failed, data)
        }
        for index in 0 ..< count {
            CGImageDestinationAddImageFromSource(destination, source, index, removalProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            return (.failed, data)
        }
        return (.stripped, output as Data)
    }

    // What the send pipeline actually calls. Collapses the three-way result the same
    // direction desktop's two call sites do on StripResult.Failed: never blocks a send over a
    // metadata edge case: if this device could not parse or re-encode the container, upload
    // the original bytes rather than a possibly-corrupt output. That is a real, documented
    // trade-off (a photo whose container ImageIO cannot round-trip keeps its metadata), not
    // an oversight - matching desktop's own comment that a Failed buffer must never be the
    // one that gets uploaded, and the caller falls back to the original instead.
    public static func stripForUpload(_ data: Data) -> Data {
        let (result, output) = stripLocationAndCameraInfo(data)
        switch result {
        case .stripped:
            return output
        case .unchanged, .failed:
            return data
        }
    }
}
