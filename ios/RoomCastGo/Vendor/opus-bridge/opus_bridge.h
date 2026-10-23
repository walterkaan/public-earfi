#ifndef ROOMCAST_OPUS_BRIDGE_H
#define ROOMCAST_OPUS_BRIDGE_H

/* 48 kHz mono Opus, 20 ms frames, 32 kbps, VoIP. One encoder per broadcast. */
typedef struct OpusEncoder OpusEncoder;

OpusEncoder *roomcast_opus_create(int *error_code);
int roomcast_opus_encode(
    OpusEncoder *encoder,
    const float *pcm,
    int frame_size,
    unsigned char *out,
    int max_bytes);
void roomcast_opus_destroy(OpusEncoder *encoder);

#endif
