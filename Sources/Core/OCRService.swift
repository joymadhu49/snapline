import AppKit
import Vision

/// On device text recognition through Apple Vision.
enum OCRService {
    static func recognizeText(in image: CGImage, completion: @escaping (String?) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation],
                  !observations.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
