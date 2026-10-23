import Foundation

struct OpusEncoderError: LocalizedError {
    var code: Int32

    var errorDescription: String? {
        "The audio encoder did not start (Opus error \(code))."
    }
}

/// 48 kHz, 20 ms frames. Voice is 32 kbps mono VoIP. Music is audio mode,
/// 128 kbps stereo or 96 kbps mono.
final class OpusEncoderBox {
    static let frameSamples = 960

    private var encoder: OpaquePointer?
    private var output = [UInt8](repeating: 0, count: 1500)

    init(music: Bool, channels: Int) throws {
        var code: Int32 = 0
        let count: Int32 = channels >= 2 ? 2 : 1
        let bitrate: Int32 = music ? (count == 2 ? 128_000 : 96_000) : 32_000
        // opus.h: OPUS_APPLICATION_VOIP = 2048, OPUS_APPLICATION_AUDIO = 2049.
        let application: Int32 = music ? 2049 : 2048
        guard let created = roomcast_opus_create(count, bitrate, application, &code) else {
            throw OpusEncoderError(code: code)
        }
        encoder = created
    }

    func encode(_ pcm: UnsafePointer<Float>) -> Data? {
        guard let encoder else { return nil }
        let written = roomcast_opus_encode(
            encoder,
            pcm,
            Int32(Self.frameSamples),
            &output,
            Int32(output.count)
        )
        guard written > 0 else { return nil }
        return Data(output.prefix(Int(written)))
    }

    deinit {
        if let encoder {
            roomcast_opus_destroy(encoder)
        }
    }
}
