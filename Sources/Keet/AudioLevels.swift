import SwiftUI

/// A separate observation boundary for high-frequency microphone readings.
@MainActor
final class AudioLevels: ObservableObject {
    struct Reading: Equatable {
        var level: Float = 0
        var peakDb: Float = -120
        var noiseDb: Float = -120
    }

    @Published private(set) var reading = Reading()

    func update(level: Float, peakDb: Float = -120, noiseDb: Float = -120) {
        let next = Reading(level: level, peakDb: peakDb, noiseDb: noiseDb)
        if next != reading { reading = next }
    }

    func reset() { update(level: 0) }
}

struct LiveAudioMeter: View {
    @ObservedObject var levels: AudioLevels

    var body: some View { Meter(level: levels.reading.level) }
}

struct LiveAudioSeparation: View {
    @ObservedObject var levels: AudioLevels
    var prefix = ""

    var body: some View {
        if levels.reading.peakDb > -100 {
            let gap = levels.reading.peakDb - levels.reading.noiseDb
            Text("\(prefix)+\(Int(gap.rounded()))dB").font(.termSmall)
                .foregroundStyle(gap >= 30 ? Term.green : (gap >= 20 ? Term.amber : Term.red))
        }
    }
}

struct Meter: View {
    let level: Float
    var segments = 30

    var body: some View {
        GeometryReader { geo in
            let lit = Int((level * Float(segments)).rounded())
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    Rectangle()
                        .fill(i < lit ? color(i) : Color(white: 0.12))
                        .frame(width: max(1, (geo.size.width - CGFloat(segments - 1) * 2) / CGFloat(segments)))
                }
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }

    private func color(_ i: Int) -> Color {
        if i < Int(Double(segments) * 0.6) { return Term.green }
        if i < Int(Double(segments) * 0.85) { return Term.amber }
        return Term.red
    }
}
