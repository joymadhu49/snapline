import AppKit
import AVFoundation
import ScreenCaptureKit

/// Screen recording through SCStream into an MP4 file.
final class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = RecordingEngine()

    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var startedAt: Date?
    private var terminationContinuation: (() -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?
    private var borderWindow: RecordingBorderWindow?
    private var completion: ((URL?) -> Void)?
    private let sampleQueue = DispatchQueue(label: "com.joymadhu.snapline.samples")

    /// Starts recording a region of a screen. Pass the full screen frame to record the whole display.
    func start(globalRect: CGRect, screen: NSScreen, completion: @escaping (URL?) -> Void) {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        self.completion = completion
        Task { @MainActor in
            do {
                try await self.beginStream(globalRect: globalRect, screen: screen)
            } catch {
                NSLog("Snapline recording failed to start: \(error)")
                self.abortWriter()
                self.cleanup()
                completion(nil)
            }
        }
    }

    /// Stops and waits for the file to be finished, used on app termination.
    func stopForTermination(_ done: @escaping () -> Void) {
        guard isRecording else { done(); return }
        terminationContinuation = done
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if let pending = self?.terminationContinuation {
                self?.terminationContinuation = nil
                pending()
            }
        }
    }

    private func abortWriter() {
        if let writer, writer.status == .writing {
            writer.cancelWriting()
        }
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    @MainActor
    private func beginStream(globalRect: CGRect, screen: NSScreen) async throws {
        let settings = SettingsStore.shared
        let content = try await CaptureEngine.shareableContent()
        guard let display = CaptureEngine.scDisplay(for: screen, in: content) else {
            throw CaptureError.displayNotFound
        }

        // Exclude Snapline's own windows (status item, HUDs) from the recording.
        let myApp = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter
        if let myApp {
            filter = SCContentFilter(display: display, excludingApplications: [myApp], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let scale = screen.backingScaleFactor
        let isFullScreen = globalRect.equalTo(screen.frame)

        // Convert the global AppKit rect into display local top left origin points.
        let localTopLeft = CGRect(x: globalRect.origin.x - screen.frame.origin.x,
                                  y: screen.frame.maxY - globalRect.maxY,
                                  width: globalRect.width, height: globalRect.height)

        let config = SCStreamConfiguration()
        var pixelWidth = Int(localTopLeft.width * scale)
        var pixelHeight = Int(localTopLeft.height * scale)
        pixelWidth -= pixelWidth % 2
        pixelHeight -= pixelHeight % 2
        config.width = pixelWidth
        config.height = pixelHeight
        if !isFullScreen {
            config.sourceRect = localTopLeft
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.recordFPS))
        config.showsCursor = settings.recordShowCursor
        config.queueDepth = 6
        config.capturesAudio = settings.recordSystemAudio
        config.sampleRate = 48000
        config.channelCount = 2
        if #available(macOS 15.0, *), settings.recordMicrophone {
            config.captureMicrophone = true
        }

        let url = ImageWriter.uniqueURL(in: settings.directory(for: .recording),
                                        fileName: ImageWriter.suggestedFileName(ext: "mp4"))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, pixelWidth * pixelHeight * 6),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        if settings.recordSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            systemAudioInput = input
        }
        if #available(macOS 15.0, *), settings.recordMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            micInput = input
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if settings.recordSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if #available(macOS 15.0, *), settings.recordMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        guard writer.startWriting() else { throw CaptureError.captureFailed }

        self.writer = writer
        self.videoInput = videoInput
        self.outputURL = url
        self.stream = stream
        self.sessionStarted = false

        try await stream.startCapture()

        if !isFullScreen {
            let border = RecordingBorderWindow(globalRect: globalRect)
            border.orderFrontRegardless()
            borderWindow = border
        }

        isStarting = false
        isRecording = true
        startedAt = Date()
        SoundFX.recordStart()
        NotificationCenter.default.post(name: .snaplineRecordingStateChanged, object: nil)
    }

    func stop() {
        guard isRecording, let stream else { return }
        isRecording = false
        NotificationCenter.default.post(name: .snaplineRecordingStateChanged, object: nil)
        borderWindow?.orderOut(nil)
        borderWindow = nil
        Task {
            try? await stream.stopCapture()
            self.finishWriting()
        }
    }

    private func finishWriting() {
        guard let writer else {
            resumeTerminationIfNeeded()
            return
        }
        guard sessionStarted else {
            // No frame ever arrived: nothing playable exists, discard the stub file.
            let completion = self.completion
            abortWriter()
            cleanup()
            completion?(nil)
            resumeTerminationIfNeeded()
            return
        }
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        let url = outputURL
        let completion = self.completion
        writer.finishWriting { [weak self] in
            DispatchQueue.main.async {
                SoundFX.recordStop()
                self?.cleanup()
                completion?(writer.status == .completed ? url : nil)
                self?.resumeTerminationIfNeeded()
            }
        }
    }

    private func resumeTerminationIfNeeded() {
        if let pending = terminationContinuation {
            terminationContinuation = nil
            pending()
        }
    }

    private func cleanup() {
        isStarting = false
        stream = nil
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        micInput = nil
        sessionStarted = false
        startedAt = nil
        completion = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        isRecording = false
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }

        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  statusRaw == SCFrameStatus.complete.rawValue else { return }
            if !sessionStarted {
                sessionStarted = true
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
            return
        }

        guard sessionStarted else { return }
        switch type {
        case .audio:
            if let input = systemAudioInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        default:
            if #available(macOS 15.0, *), type == .microphone {
                if let input = micInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            NSLog("Snapline stream stopped with error: \(error)")
            self.isRecording = false
            NotificationCenter.default.post(name: .snaplineRecordingStateChanged, object: nil)
            self.borderWindow?.orderOut(nil)
            self.borderWindow = nil
            self.finishWriting()
        }
    }
}

/// Non interactive frame drawn just outside the recorded region.
final class RecordingBorderWindow: NSWindow {
    init(globalRect: CGRect) {
        let inset: CGFloat = -3
        super.init(contentRect: globalRect.insetBy(dx: inset, dy: inset),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = BorderView(frame: NSRect(origin: .zero, size: frame.size))
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
