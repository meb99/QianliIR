import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Records the displayed pictures (with markers and colour bar) as an H.264 .mov file.
final class VideoRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int
    private var start: Date?

    init(url: URL, width: Int, height: Int) throws {
        // H.264 needs even dimensions.
        self.width = width & ~1
        self.height = height & ~1
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "QianliIR", code: 1)
        }
        writer.startSession(atSourceTime: .zero)
    }

    var duration: TimeInterval { start.map { Date().timeIntervalSince($0) } ?? 0 }

    func append(_ image: CGImage) {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        let now = Date()
        if start == nil { start = now }
        let time = CMTime(seconds: now.timeIntervalSince(start!), preferredTimescale: 600)

        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: time)
    }

    func finish(completion: @escaping (URL) -> Void) {
        input.markAsFinished()
        let url = self.url
        writer.finishWriting { completion(url) }
    }
}
