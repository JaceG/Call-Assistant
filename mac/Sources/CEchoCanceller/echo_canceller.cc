#include "echo_canceller.h"

#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

struct ca_echo_canceller {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
};

extern "C" ca_echo_canceller *ca_echo_canceller_create(int sample_rate_hz) {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm = webrtc::AudioProcessingBuilder().Create();
  if (!apm) {
    return nullptr;
  }
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;       // AEC3
  config.echo_canceller.mobile_mode = false;
  config.high_pass_filter.enabled = true;     // AEC3 expects it
  config.noise_suppression.enabled = false;   // leave the voice untouched for recognition
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  apm->ApplyConfig(config);
  return new ca_echo_canceller{apm, webrtc::StreamConfig(sample_rate_hz, 1)};
}

extern "C" void ca_echo_canceller_destroy(ca_echo_canceller *canceller) {
  delete canceller;
}

extern "C" int ca_echo_canceller_frame_size(const ca_echo_canceller *canceller) {
  return static_cast<int>(canceller->stream.num_frames());
}

extern "C" int ca_echo_canceller_add_far_end(ca_echo_canceller *canceller, const float *frame) {
  const float *channels[1] = {frame};
  return canceller->apm->AnalyzeReverseStream(channels, canceller->stream);
}

extern "C" int ca_echo_canceller_process(ca_echo_canceller *canceller, float *frame) {
  float *channels[1] = {frame};
  return canceller->apm->ProcessStream(channels, canceller->stream, canceller->stream, channels);
}
