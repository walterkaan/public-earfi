#ifndef ROOMCAST_OPUS_BRIDGE_H
#define ROOMCAST_OPUS_BRIDGE_H

/* 48 kHz, 20 ms frames. Voice is 1 channel, 32 kbps, application 2048 (VoIP).
   Music is application 2049 (audio): 2 channels at 128 kbps, or 1 at 96. */
typedef struct OpusEncoder OpusEncoder;

OpusEncoder *roomcast_opus_create(int channels, int bitrate, int application, int *error_code);
int roomcast_opus_encode(
    OpusEncoder *encoder,
    const float *pcm,
    int frame_size,
    unsigned char *out,
    int max_bytes);
void roomcast_opus_destroy(OpusEncoder *encoder);

#endif
