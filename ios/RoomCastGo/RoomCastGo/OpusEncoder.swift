import Foundation

struct OpusEncoderError: LocalizedError {
    var code: Int32

    var errorDescription: String? {
        "The voice encoder did not start (Opus error \(code))."
    }
}

/// 48 kHz mono, 20 ms frames, Opus 32 kbps, VoIP. Matches the Mac Speech preset.
final class OpusEncoderBox {
    static let frameSamples = 960

    private var encoder: OpaquePointer?
    private var output = [UInt8](repeating: 0, count: 400)

    init() throws {
        var code: Int32 = 0
        guard let created = roomcast_opus_create(&code) else {
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
