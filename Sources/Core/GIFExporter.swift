import AppKit

/// Converts an MP4 recording to GIF using Homebrew ffmpeg when available.
enum GIFExporter {
    static var ffmpegPath: String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { ffmpegPath != nil }

    static func export(mp4URL: URL, completion: @escaping (URL?) -> Void) {
        guard let ffmpeg = ffmpegPath else {
            completion(nil)
            return
        }
        let gifURL = ImageWriter.uniqueURL(in: SettingsStore.shared.directory(for: .gif),
                                           fileName: mp4URL.deletingPathExtension()
                                               .appendingPathExtension("gif").lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-y", "-i", mp4URL.path,
                "-vf", "fps=12,scale='min(iw,800)':-2:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer",
                "-loop", "0",
                gifURL.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                DispatchQueue.main.async {
                    completion(process.terminationStatus == 0 ? gifURL : nil)
                }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
