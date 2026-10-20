// A small C interface to WebRTC's AEC3 echo canceller, so Swift can call it
// without C++ interop. Mono audio, float samples in [-1, 1], 10 ms frames.

#ifndef CALL_ASSISTANT_ECHO_CANCELLER_H
#define CALL_ASSISTANT_ECHO_CANCELLER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ca_echo_canceller ca_echo_canceller;

/// sample_rate_hz is 16000, 32000 or 48000. NULL if WebRTC can't be set up.
ca_echo_canceller *ca_echo_canceller_create(int sample_rate_hz);
void ca_echo_canceller_destroy(ca_echo_canceller *canceller);

/// Samples in one 10 ms frame (160 at 16 kHz).
int ca_echo_canceller_frame_size(const ca_echo_canceller *canceller);

/// The far end: one frame of what the speakers are playing. 0 on success.
int ca_echo_canceller_add_far_end(ca_echo_canceller *canceller, const float *frame);

/// The near end: one frame from the mic, echo removed in place. 0 on success.
int ca_echo_canceller_process(ca_echo_canceller *canceller, float *frame);

#ifdef __cplusplus
}
#endif

#endif
