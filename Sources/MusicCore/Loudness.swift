import AVFoundation
import Foundation

/// Integrated loudness in LUFS (ITU-R BS.1770 / EBU R128): K-weighting, 400 ms blocks with 75% overlap,
/// absolute gate at -70 LUFS and relative gate 10 LU below the ungated mean.
/// Returns nil for silent or unreadable files.
public func integratedLoudness(of url: URL) -> Double? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    return integratedLoudness(of: file)
}

public func integratedLoudness(of file: AVAudioFile) -> Double? {
    let format = file.processingFormat
    let rate = format.sampleRate
    let channels = min(Int(format.channelCount), 2)          // L and R (weight 1.0 each); extra channels ignored
    guard channels > 0, rate > 0 else { return nil }
    var filters = (0..<channels).map { _ in KWeighting(sampleRate: rate) }

    // Mean square energy per 100 ms sub-block; a 400 ms block is 4 consecutive sub-blocks.
    let subLength = Int((rate * 0.1).rounded())
    var subEnergies: [Double] = []
    var acc = [Double](repeating: 0, count: channels)
    var accCount = 0

    let chunk: AVAudioFrameCount = 65_536
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
    file.framePosition = 0
    while file.framePosition < file.length {
        do { try file.read(into: buffer, frameCount: chunk) } catch { break }
        let n = Int(buffer.frameLength)
        guard n > 0, let data = buffer.floatChannelData else { break }
        for i in 0..<n {
            for c in 0..<channels {
                let y = filters[c].process(Double(data[c][i]))
                acc[c] += y * y
            }
            accCount += 1
            if accCount == subLength {
                // Mono files play as dual mono (both speakers), so count them twice to match what is heard.
                subEnergies.append(acc.reduce(0) { $0 + $1 / Double(subLength) } * (channels == 1 ? 2 : 1))
                for c in 0..<channels { acc[c] = 0 }
                accCount = 0
            }
        }
    }
    file.framePosition = 0
    guard subEnergies.count >= 4 else { return nil }

    var blocks: [Double] = []
    blocks.reserveCapacity(subEnergies.count - 3)
    for j in 0...(subEnergies.count - 4) {
        blocks.append((subEnergies[j] + subEnergies[j + 1] + subEnergies[j + 2] + subEnergies[j + 3]) / 4)
    }
    func lufs(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
    let absGated = blocks.filter { $0 > 0 && lufs($0) > -70 }
    guard !absGated.isEmpty else { return nil }
    let relThreshold = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
    let gated = absGated.filter { lufs($0) > relThreshold }
    guard !gated.isEmpty else { return nil }
    return lufs(gated.reduce(0, +) / Double(gated.count))
}

/// The two-stage K-weighting filter (high shelf + high pass), with coefficients derived for any sample rate.
struct KWeighting {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate rate: Double) {
        // Same design as libebur128 (and ffmpeg's ebur128 filter): bilinear transform with prewarping.
        do {   // stage 1: +4 dB high shelf around 1.7 kHz (models the head)
            let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
            let k = tan(Double.pi * f0 / rate), vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            shelf = Biquad(b0: (vh + vb * k / q + k * k), b1: 2 * (k * k - vh), b2: (vh - vb * k / q + k * k),
                           a0: a0, a1: 2 * (k * k - 1), a2: 1 - k / q + k * k)
        }
        do {   // stage 2: high pass around 38 Hz
            let f0 = 38.13547087602444, q = 0.5003270373238773
            let k = tan(Double.pi * f0 / rate)
            let a0 = 1 + k / q + k * k
            highPass = Biquad(b0: a0, b1: -2 * a0, b2: a0, a0: a0, a1: 2 * (k * k - 1), a2: 1 - k / q + k * k)
        }
    }

    mutating func process(_ x: Double) -> Double { highPass.process(shelf.process(x)) }
}

struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0; self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Turns each playlist's median track loudness into a `#WEIGHT:` percentage. The loudest-needing
/// (quietest) playlist gets 100%; louder ones are turned down so all playlists play at the same level.
/// Matches VLC's cubic volume curve: weight = 10^((reference - L) / 60), normalized to the maximum.
public func playlistWeights(medianLoudness: [String: Double]) -> [String: Int] {
    let raw = medianLoudness.mapValues { pow(10, (-36.4 - $0) / 60) }
    guard let top = raw.values.max(), top > 0 else { return [:] }
    return raw.mapValues { Int(($0 / top * 100).rounded()) }
}
