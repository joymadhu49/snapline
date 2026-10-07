import AppKit
import UniformTypeIdentifiers

/// Saving, clipboard, naming, and post processing for captured images.
enum ImageWriter {

    static func suggestedFileName(prefix: String = "Snapline", ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date())).\(ext)"
    }

    static func uniqueURL(in directory: URL, fileName: String) -> URL {
        var url = directory.appendingPathComponent(fileName)
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) || isReserved(url) {
            url = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return url
    }

    // MARK: Background writes

    /// Encoding a Retina capture to PNG takes about 100 ms, and it used to
    /// happen twice (file and clipboard) on the main thread between mouse up
    /// and the card appearing, which is what made capturing feel sticky. Now
    /// the file name is chosen up front and the encode runs here, once.
    private static let writeQueue = DispatchQueue(label: "com.joymadhu.Snapline.write", qos: .userInitiated)
    private static let reservationLock = NSLock()
    /// Names handed out but not written yet, so two captures in the same
    /// second cannot both claim "Snapline … at 12.00.01.png".
    private static var reserved: Set<String> = []

    private static func isReserved(_ url: URL) -> Bool {
        reservationLock.lock(); defer { reservationLock.unlock() }
        return reserved.contains(url.path)
    }

    private static func reserve(_ url: URL) {
        reservationLock.lock(); reserved.insert(url.path); reservationLock.unlock()
    }

    private static func release(_ url: URL) {
        reservationLock.lock(); reserved.remove(url.path); reservationLock.unlock()
    }

    /// Blocks until every queued capture is on disk. Only a drag or paste in
    /// the first moments after a capture ever actually waits here.
    static func waitForPendingWrites() {
        writeQueue.sync {}
    }

    /// Picks the capture's file now and writes it in the background, then puts
    /// it on the clipboard from the same single encode. `completion` runs on
    /// the main thread once the file exists (nil if the write failed).
    static func writeInBackground(_ image: CGImage, scale: CGFloat, saveToFolder: Bool, copy: Bool,
                                  completion: @escaping (URL?) -> Void) -> URL {
        let settings = SettingsStore.shared
        let format = settings.imageFormat
        let quality = settings.jpgQuality
        let directory = saveToFolder ? settings.directory(for: .screenshot) : cacheDirectory
        let url = uniqueURL(in: directory, fileName: suggestedFileName(ext: format.fileExtension))
        reserve(url)
        writeQueue.async {
            let fileData = ImageWriter.data(for: image, format: format, jpgQuality: quality, scale: scale)
            var written = false
            if let fileData {
                do { try fileData.write(to: url); written = true }
                catch { NSLog("Snapline save error: \(error.localizedDescription)") }
            }
            ImageWriter.release(url)
            var clip: (png: Data?, tiff: Data?)?
            if copy {
                let rep = ImageWriter.bitmapRep(for: image, scale: scale)
                let png = format == .png ? fileData : rep.representation(using: .png, properties: [:])
                clip = (png, rep.tiffRepresentation)
                if let png { ImageWriter.rememberPNG(png, for: image) }
            }
            DispatchQueue.main.async {
                if let clip { ImageWriter.writeClipboard(png: clip.png, tiff: clip.tiff, fileURL: written ? url : nil) }
                completion(written ? url : nil)
            }
        }
        return url
    }

    /// Writes an already rendered image (the editor's result) to `url` on the
    /// same serial queue as capture writes, so it lands after the capture's
    /// own first write and a drag that waits on `waitForPendingWrites` gets the
    /// edited file. `png` is reused when the caller already encoded it; the
    /// clipboard, when asked for, is filled from the same encode. A file that
    /// cannot be overwritten falls back to a new one in the screenshots folder.
    /// `completion` runs on the main thread with the file actually written.
    static func exportInBackground(_ image: CGImage, scale: CGFloat, to url: URL, png: Data?, copy: Bool,
                                   completion: @escaping (URL?) -> Void) {
        let ext = url.pathExtension.lowercased()
        let format: ImageFormat = ext == "jpg" || ext == "jpeg" ? .jpg : .png
        let settings = SettingsStore.shared
        let quality = settings.jpgQuality
        let fallbackDirectory = settings.directory(for: .screenshot)
        reserve(url)
        writeQueue.async {
            var pngData = png
            if pngData == nil, format == .png || copy {
                pngData = ImageWriter.data(for: image, format: .png, jpgQuality: quality, scale: scale)
            }
            let fileData = format == .png ? pngData : ImageWriter.data(for: image, format: .jpg, jpgQuality: quality, scale: scale)
            var written: URL?
            if let fileData {
                if (try? fileData.write(to: url)) != nil {
                    written = url
                } else {
                    let fallback = uniqueURL(in: fallbackDirectory, fileName: suggestedFileName(ext: format.fileExtension))
                    if (try? fileData.write(to: fallback)) != nil { written = fallback }
                }
            }
            ImageWriter.release(url)
            if let pngData { ImageWriter.rememberPNG(pngData, for: image) }
            let tiff = copy ? ImageWriter.bitmapRep(for: image, scale: scale).tiffRepresentation : nil
            DispatchQueue.main.async {
                if copy { ImageWriter.writeClipboard(png: pngData, tiff: tiff, fileURL: written) }
                completion(written)
            }
        }
    }

    /// Clipboard for an image whose PNG bytes are already in hand.
    static func copyToClipboard(_ image: CGImage, png: Data?, scale: CGFloat = 1, fileURL: URL? = nil) {
        if let png { rememberPNG(png, for: image) }
        let rep = bitmapRep(for: image, scale: scale)
        writeClipboard(png: png ?? rep.representation(using: .png, properties: [:]),
                       tiff: rep.tiffRepresentation, fileURL: fileURL)
    }

    /// A card's thumbnail: the capture scaled to cover `size` points at 2x.
    /// Drawing a 5K frame into a 260 point card on every render was a waste of
    /// GPU upload and main thread time during the slide in.
    static func thumbnail(for image: CGImage, covering size: CGSize) -> CGImage {
        let target = CGSize(width: size.width * 2, height: size.height * 2)
        let ratio = max(target.width / CGFloat(image.width), target.height / CGFloat(image.height))
        guard ratio < 1 else { return image }
        let width = max(1, Int(CGFloat(image.width) * ratio))
        let height = max(1, Int(CGFloat(image.height) * ratio))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: PNG reuse

    /// The last few PNG encodes, so clicking a card to copy it again does not
    /// re-encode the same pixels on the main thread every time.
    private static var recentPNGs: [(image: CGImage, png: Data)] = []

    private static func rememberPNG(_ png: Data, for image: CGImage) {
        reservationLock.lock(); defer { reservationLock.unlock() }
        recentPNGs.removeAll { $0.image === image }
        recentPNGs.append((image, png))
        if recentPNGs.count > 4 { recentPNGs.removeFirst() }
    }

    private static func cachedPNG(for image: CGImage) -> Data? {
        reservationLock.lock(); defer { reservationLock.unlock() }
        return recentPNGs.first { $0.image === image }?.png
    }

    private static func bitmapRep(for image: CGImage, scale: CGFloat) -> NSBitmapImageRep {
        let factor = max(1, scale)
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / factor, height: CGFloat(image.height) / factor)
        return rep
    }

    private static func writeClipboard(png: Data?, tiff: Data?, fileURL: URL?) {
        let item = NSPasteboardItem()
        if let png { _ = item.setData(png, forType: .png) }
        if let tiff { _ = item.setData(tiff, forType: .tiff) }
        if let fileURL {
            _ = item.setString(fileURL.absoluteString, forType: .fileURL)
            _ = item.setString(fileURL.path, forType: .string)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Optionally downsamples a 2x capture to 1x.
    static func applyRetinaDownscale(_ image: CGImage, scale: CGFloat) -> CGImage {
        guard SettingsStore.shared.downscaleRetina, scale > 1 else { return image }
        let width = Int(CGFloat(image.width) / scale)
        let height = Int(CGFloat(image.height) / scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Scale stamps proper dpi so retina captures open and paste at their logical size.
    static func data(for image: CGImage, format: ImageFormat, jpgQuality: Double, scale: CGFloat = 1) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        let factor = max(1, scale)
        rep.size = CGSize(width: CGFloat(image.width) / factor, height: CGFloat(image.height) / factor)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: jpgQuality])
        }
    }

    @discardableResult
    static func save(_ image: CGImage, to directory: URL? = nil, format: ImageFormat? = nil, scale: CGFloat = 1) -> URL? {
        let settings = SettingsStore.shared
        let fmt = format ?? settings.imageFormat
        let dir = directory ?? settings.directory(for: .screenshot)
        guard let data = data(for: image, format: fmt, jpgQuality: settings.jpgQuality, scale: scale) else { return nil }
        let url = uniqueURL(in: dir, fileName: suggestedFileName(ext: fmt.fileExtension))
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("Snapline save error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Puts one capture on the clipboard in every flavour a paste target may ask
    /// for: the bitmap for editors and chat apps, the file URL for Finder, and
    /// the POSIX path so a paste into a terminal or an agent prompt is the path.
    static func copyToClipboard(_ image: CGImage, scale: CGFloat = 1, fileURL: URL? = nil) {
        let rep = bitmapRep(for: image, scale: scale)
        // A capture's PNG file already holds exactly these pixels, so reading
        // it back beats encoding them again.
        let fromFile = fileURL.flatMap { $0.pathExtension.lowercased() == "png" ? try? Data(contentsOf: $0) : nil }
        let png = cachedPNG(for: image) ?? fromFile ?? rep.representation(using: .png, properties: [:])
        if let png { rememberPNG(png, for: image) }
        writeClipboard(png: png, tiff: rep.tiffRepresentation, fileURL: fileURL)
    }

    /// Same idea for a file that already exists, image or recording.
    /// A PNG goes on as the file's own bytes; any other format, and the TIFF
    /// flavour, are only converted if a paste target actually asks for them.
    static func copyFileToClipboard(_ url: URL) {
        let item = NSPasteboardItem()
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            var lazyTypes: [NSPasteboard.PasteboardType] = [.tiff]
            if type.conforms(to: .png), let data = try? Data(contentsOf: url) {
                _ = item.setData(data, forType: .png)
            } else {
                lazyTypes.insert(.png, at: 0)
            }
            let provider = FileImageProvider(url: url)
            FileImageProvider.current = provider
            _ = item.setDataProvider(provider, forTypes: lazyTypes)
        }
        _ = item.setString(url.absoluteString, forType: .fileURL)
        _ = item.setString(url.path, forType: .string)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Captures the user chose not to save still need a file on disk, otherwise
    /// there is no path to drag out or paste. Those land here instead.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Snapline/Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real file for this capture, reusing the saved one when there is one.
    static func persistentFile(for image: CGImage, scale: CGFloat = 1, existing: URL? = nil) -> URL? {
        if let existing, FileManager.default.fileExists(atPath: existing.path) { return existing }
        return save(image, to: cacheDirectory, scale: scale)
    }
}

enum SoundFX {
    static func capture() {
        guard SettingsStore.shared.playSounds else { return }
        NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)?.play()
    }

    static func recordStart() {
        guard SettingsStore.shared.playSounds else { return }
        NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)?.play()
    }

    static func recordStop() {
        guard SettingsStore.shared.playSounds else { return }
        NSSound(contentsOfFile: "/System/Library/Sounds/Bottle.aiff", byReference: true)?.play()
    }
}

/// Converts an image file to another pasteboard flavour on demand, so copying
/// from the history costs a file read rather than a decode and two encodes.
final class FileImageProvider: NSObject, NSPasteboardItemDataProvider {
    /// The pasteboard does not keep its data providers alive; this does, until
    /// the next copy replaces it.
    static var current: FileImageProvider?
    private let url: URL

    init(url: URL) { self.url = url }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return }
        let converted = type == .png ? rep.representation(using: .png, properties: [:]) : rep.tiffRepresentation
        if let converted { _ = item.setData(converted, forType: type) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if FileImageProvider.current === self { FileImageProvider.current = nil }
    }
}
