#include "opus_bridge.h"

#include "opus.h"

OpusEncoder *roomcast_opus_create(int channels, int bitrate, int application, int *error_code) {
    int err = OPUS_OK;
    int ch = channels >= 2 ? 2 : 1;
    int app = application == OPUS_APPLICATION_AUDIO ? OPUS_APPLICATION_AUDIO : OPUS_APPLICATION_VOIP;
    if (bitrate < 6000) {
        bitrate = 6000;
    }
    OpusEncoder *encoder = opus_encoder_create(48000, ch, app, &err);
    if (error_code != 0) {
        *error_code = err;
    }
    if (err != OPUS_OK || encoder == 0) {
        if (encoder != 0) {
            opus_encoder_destroy(encoder);
        }
        return 0;
    }
    opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
    opus_encoder_ctl(encoder, OPUS_SET_VBR(1));
    opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(app == OPUS_APPLICATION_AUDIO ? OPUS_SIGNAL_MUSIC : OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(encoder, OPUS_SET_DTX(0));
    opus_encoder_ctl(encoder, OPUS_SET_LSB_DEPTH(16));
    return encoder;
}

int roomcast_opus_encode(
    OpusEncoder *encoder,
    const float *pcm,
    int frame_size,
    unsigned char *out,
    int max_bytes
) {
    if (encoder == 0 || pcm == 0 || out == 0 || frame_size <= 0 || max_bytes <= 0) {
        return OPUS_BAD_ARG;
    }
    return opus_encode_float(encoder, pcm, frame_size, out, max_bytes);
}

void roomcast_opus_destroy(OpusEncoder *encoder) {
    if (encoder != 0) {
        opus_encoder_destroy(encoder);
    }
}
