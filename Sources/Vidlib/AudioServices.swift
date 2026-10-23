import AVFoundation
import Accelerate
import AppKit
import MediaToolbox

enum AudioGain {
  static func clamped(_ db: Double) -> Double { db.isFinite ? min(48, max(-96, db)) : 0 }
  static func linear(_ db: Double) -> Float { Float(pow(10, clamped(db) / 20)) }
  static func normalizationDB(peak: Float, targetDB: Double = -1) -> Double? {
    guard peak.isFinite, peak > 0 else { return nil }
    return clamped(targetDB - 20 * log10(Double(peak)))
  }
  static func apply(_ samples: UnsafeMutablePointer<Float>, count: Int, db: Double) {
    var multiplier = linear(db)
    vDSP_vsmul(samples, 1, &multiplier, samples, 1, vDSP_Length(count))
  }
}

struct AudioAnalysis: Codable {
  var peaks: [Float]
  var peak: Float
  var frames: Int64
  var sampleRate: Double

  func image() -> CGImage? {
    let width = 480
    let height = 270
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 0.075, green: 0.09, blue: 0.11, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setStrokeColor(CGColor(red: 0.33, green: 0.78, blue: 0.84, alpha: 1))
    context.setLineWidth(1.3)
    let scale = Double(max(peak, 0.000001))
    for (i, value) in peaks.enumerated() {
      let x = 12 + Double(i) / Double(max(1, peaks.count - 1)) * 456
      let amplitude = max(0.6, min(1, Double(value) / scale) * 105)
      context.move(to: CGPoint(x: x, y: 135 - amplitude))
      context.addLine(to: CGPoint(x: x, y: 135 + amplitude))
    }
    context.strokePath()
    return context.makeImage()
  }
}

actor AudioAnalyzer {
  /// Bounded-memory streaming scan. Float samples above 0 dBFS are kept intact.
  func analyze(url: URL, bins: Int = 480) throws -> AudioAnalysis {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)
    else { throw CocoaError(.fileReadUnknown) }
    var peaks = [Float](repeating: 0, count: max(1, bins))
    var peak: Float = 0
    let total = max(Int64(1), file.length)
    var offset: Int64 = 0
    while file.framePosition < file.length {
      try Task.checkCancellation()
      try file.read(into: buffer)
      let count = Int(buffer.frameLength)
      guard count > 0, let channels = buffer.floatChannelData else { break }
      for frame in 0..<count {
        let bin = min(
          peaks.count - 1, Int(Double(offset + Int64(frame)) / Double(total) * Double(peaks.count)))
        for channel in 0..<Int(buffer.format.channelCount) {
          let sample = abs(channels[channel][frame])
          guard sample.isFinite else { continue }
          peaks[bin] = max(peaks[bin], sample)
          peak = max(peak, sample)
        }
      }
      offset += Int64(count)
    }
    return AudioAnalysis(
      peaks: peaks, peak: peak, frames: offset, sampleRate: file.processingFormat.sampleRate)
  }
}

private final class GainTapState {
  let gainDB: Double
  var float32 = false
  init(_ db: Double) { gainDB = db }
}

enum AudioGainTap {
  static func make(db: Double) throws -> MTAudioProcessingTap {
    let state = Unmanaged.passRetained(GainTapState(db))
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: state.toOpaque(),
      init: { _, clientInfo, storage in
        storage.pointee = clientInfo
      },
      finalize: { tap in
        Unmanaged<GainTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
      },
      prepare: { tap, _, format in
        let state = Unmanaged<GainTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
          .takeUnretainedValue()
        state.float32 =
          format.pointee.mFormatID == kAudioFormatLinearPCM
          && format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
          && format.pointee.mBitsPerChannel == 32
      }, unprepare: { _ in },
      process: { tap, frames, _, buffers, framesOut, flagsOut in
        let status = MTAudioProcessingTapGetSourceAudio(
          tap, frames, buffers, flagsOut, nil, framesOut)
        guard status == noErr else {
          framesOut.pointee = 0
          return
        }
        let state = Unmanaged<GainTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
          .takeUnretainedValue()
        guard state.float32 else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
          guard let data = buffer.mData else { continue }
          AudioGain.apply(
            data.assumingMemoryBound(to: Float.self),
            count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, db: state.gainDB)
        }
      })
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    guard status == noErr, let tap else {
      state.release()
      throw NSError(
        domain: NSOSStatusErrorDomain, code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "Could not initialize audio preview gain."])
    }
    return tap
  }
}
