/* Encodes a sine with the vendored bridge and decodes it with libopus.
   Run by scripts/test-opus.sh. Not part of the iOS target. */
#include "opus_bridge.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "opus.h"

enum { kRate = 48000, kFrame = 960, kFrames = 50 };

/* Opus delays the waveform. Score the best alignment, not sample 0. */
static float best_correlation(const float *a, const float *b, int count) {
    float best = -1.0f;
    int max_lag = 2400;
    if (max_lag > count / 2) {
        max_lag = count / 2;
    }
    for (int lag = 0; lag <= max_lag; lag++) {
        double dot = 0;
        double aa = 0;
        double bb = 0;
        int n = count - lag;
        for (int i = 0; i < n; i++) {
            double x = a[i];
            double y = b[i + lag];
            dot += x * y;
            aa += x * x;
            bb += y * y;
        }
        if (aa < 1e-8 || bb < 1e-8) {
            continue;
        }
        float corr = (float)(dot / sqrt(aa * bb));
        if (corr > best) {
            best = corr;
        }
    }
    return best;
}

int main(void) {
    int err = 0;
    OpusEncoder *encoder = roomcast_opus_create(1, 32000, OPUS_APPLICATION_VOIP, &err);
    if (encoder == 0) {
        fprintf(stderr, "encoder create failed: %d\n", err);
        return 1;
    }
    OpusDecoder *decoder = opus_decoder_create(kRate, 1, &err);
    if (decoder == 0) {
        fprintf(stderr, "decoder create failed: %d\n", err);
        return 1;
    }

    float pcm[kFrame * kFrames];
    float decoded[kFrame * kFrames];
    unsigned char packet[512];
    for (int frame = 0; frame < kFrames; frame++) {
        float *in = pcm + frame * kFrame;
        float *out = decoded + frame * kFrame;
        for (int i = 0; i < kFrame; i++) {
            double t = (double)(frame * kFrame + i) / (double)kRate;
            in[i] = (float)(0.2 * sin(2.0 * 3.141592653589793 * 220.0 * t));
        }
        int bytes = roomcast_opus_encode(encoder, in, kFrame, packet, (int)sizeof packet);
        if (bytes < 1) {
            fprintf(stderr, "encode failed: %d\n", bytes);
            return 1;
        }
        if (bytes > 120) {
            fprintf(stderr, "packet too large for 32 kbps: %d\n", bytes);
            return 1;
        }
        int samples = opus_decode_float(decoder, packet, bytes, out, kFrame, 0);
        if (samples != kFrame) {
            fprintf(stderr, "decode failed: %d\n", samples);
            return 1;
        }
    }
    float corr = best_correlation(pcm, decoded, kFrame * kFrames);
    printf("best correlation: %g\n", corr);
    if (!(corr > 0.95f)) {
        fprintf(stderr, "decoded sine does not match the input\n");
        return 1;
    }
    roomcast_opus_destroy(encoder);
    opus_decoder_destroy(decoder);

    /* Music mode: stereo audio at 128 kbps, and mono audio at 96 kbps. */
    OpusEncoder *music = roomcast_opus_create(2, 128000, OPUS_APPLICATION_AUDIO, &err);
    if (music == 0) {
        fprintf(stderr, "music encoder create failed: %d\n", err);
        return 1;
    }
    float stereo[kFrame * 2];
    for (int i = 0; i < kFrame; i++) {
        double t = (double)i / (double)kRate;
        stereo[i * 2] = (float)(0.2 * sin(2.0 * 3.141592653589793 * 220.0 * t));
        stereo[i * 2 + 1] = stereo[i * 2];
    }
    unsigned char music_packet[1500];
    int music_bytes = roomcast_opus_encode(music, stereo, kFrame, music_packet, (int)sizeof music_packet);
    if (music_bytes < 1) {
        fprintf(stderr, "music encode failed: %d\n", music_bytes);
        return 1;
    }
    roomcast_opus_destroy(music);
    OpusEncoder *music_mono = roomcast_opus_create(1, 96000, OPUS_APPLICATION_AUDIO, &err);
    if (music_mono == 0) {
        fprintf(stderr, "mono music encoder create failed: %d\n", err);
        return 1;
    }
    roomcast_opus_destroy(music_mono);
    return 0;
}
