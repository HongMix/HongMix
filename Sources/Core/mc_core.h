// BraceletMix media core — public C API consumed by the Swift engine.
// All audio crossing this API is 48 kHz, 2-channel, interleaved float32.
// All video crossing this API is 8-bit BGRA (premultiplied alpha is NOT assumed).
#ifndef MC_CORE_H
#define MC_CORE_H

#include <stdint.h>
#include <stddef.h>
#include "mc_srt.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MC_AUDIO_RATE 48000
#define MC_AUDIO_CHANNELS 2

enum {
    MC_STATE_IDLE = 0,
    MC_STATE_CONNECTING = 1,
    MC_STATE_RUNNING = 2,
    MC_STATE_ERROR = 3,
    MC_STATE_STOPPED = 4
};

typedef void (*mc_video_cb)(void *user, const uint8_t *bgra, int width, int height, int stride, int64_t pts_us);
typedef void (*mc_audio_cb)(void *user, const float *stereo, int frames);
typedef void (*mc_status_cb)(void *user, int state, const char *message);
/* Hardware-decoded frame (macOS: CVPixelBufferRef, usually NV12 IOSurface). Only valid during the call;
   retain it to keep it. When set, VideoToolbox frames skip the CPU download + BGRA conversion. */
typedef void (*mc_pixelbuffer_cb)(void *user, void *pixel_buffer, int64_t pts_us);

typedef struct {
    mc_video_cb on_video;
    mc_audio_cb on_audio;
    mc_status_cb on_status;
    void *user;
    mc_pixelbuffer_cb on_pixelbuffer;
} mc_callbacks;

/* ------------------------------------------------------------------ */
/* FFmpeg input: files, SRT (caller/listener), RTMP pull, HLS, UDP ... */
/* ------------------------------------------------------------------ */
typedef struct mc_input mc_input;

typedef struct {
    const char *url;      // file path or URL (srt://, rtmp://, udp://, http(s)://)
    int loop;             // loop files at EOF
    int realtime;         // -1 = auto (files paced, live not), 0 = off, 1 = on
    int low_latency;      // nobuffer / small probe for live
    int hwaccel;          // try VideoToolbox decode
    int timeout_ms;       // no-data timeout before reconnect (live), 0 = 5000
} mc_input_config;

mc_input *mc_input_open(const mc_input_config *cfg, mc_callbacks cb);
void mc_input_close(mc_input *in);
void mc_input_restart(mc_input *in);       // seek to start (files)
void mc_input_set_paused(mc_input *in, int paused);  // files: pause/resume playback
void mc_input_set_loop(mc_input *in, int loop);
void mc_input_seek(mc_input *in, int64_t position_us);              // files
void mc_input_set_marks(mc_input *in, int64_t in_us, int64_t out_us); // -1 = no mark
void mc_input_set_rate(mc_input *in, double rate);                  // files: 0.05 ... 4.0 (audio muted when != 1)
double mc_input_nominal_fps(mc_input *in);                          // declared stream rate, 0 = unknown
void mc_input_get_position(mc_input *in, int64_t *position_us, int64_t *duration_us, int *finished);
/* SRT link statistics (1 = this input is a connected SRT session). Any thread. */
int mc_input_srt_stats(mc_input *in, mc_srt_stats *out);

/* ------------------------------------------------------------------ */
/* FFmpeg output: RTMP/RTMPS, SRT, UDP streaming and file recording    */
/* ------------------------------------------------------------------ */
typedef struct mc_output mc_output;

typedef struct {
    const char *url;          // rtmp://..., srt://..., /path/file.mov
    const char *format;       // optional muxer override ("flv", "mpegts", "mov", "mp4")
    int width, height;
    int fps_num, fps_den;
    int video_kbps;           // ignored for ProRes
    int audio_kbps;
    const char *video_codec;  // "h264", "hevc", "prores"
    int keyint_frames;        // GOP length; 0 = 2 seconds
    int reconnect;            // auto reconnect on network failure
    int hardware;             // prefer VideoToolbox encoders
    int pixelbuffer_input;    // frames arrive via mc_output_push_pixelbuffer (zero-copy to VideoToolbox)
    int delay_ms;             // broadcast delay: encoded packets are held this long before going out (0 = live)
    int extra_audio_tracks;   // multitrack recording: extra stereo audio tracks (0…MC_MAX_XTRACKS), fed by
                              // mc_output_push_audio_tracks (track 1 = the normal audio)
} mc_output_config;

#define MC_MAX_XTRACKS 8

typedef struct {
    int state;
    int64_t frames_encoded;
    int64_t frames_dropped;
    int64_t bytes_written;
    double kbps;              // measured over the last ~second
    int queue_depth;
    char encoder[48];
    int delay_buffered_ms;    // broadcast delay: how much is currently held back
} mc_output_stats;

mc_output *mc_output_open(const mc_output_config *cfg, mc_status_cb status, void *user);
void mc_output_push_video(mc_output *out, const uint8_t *bgra, int stride, int64_t tick);
/* macOS: BGRA IOSurface CVPixelBufferRef from the mixer. Retained until encoded — no CPU copy or
   colour conversion when the encoder is VideoToolbox (the hardware converts BGRA→YUV). */
void mc_output_push_pixelbuffer(mc_output *out, void *pixel_buffer, int64_t tick);
void mc_output_push_audio(mc_output *out, const float *stereo, int frames);
/* Multitrack: main stereo + cfg.extra_audio_tracks extra stereo buffers, pushed together (sample-aligned). */
void mc_output_push_audio_tracks(mc_output *out, const float *stereo, const float *const *extra, int nextra, int frames);
void mc_output_get_stats(mc_output *out, mc_output_stats *stats);
int mc_output_srt_stats(mc_output *out, mc_srt_stats *stats);   /* 1 = connected SRT session */
void mc_output_close(mc_output *out);
/* Broadcast delay "dump": throw away everything held back (from the newest keyframe on, the output
   goes out live) and stop delaying until the output restarts. */
void mc_output_dump_delay(mc_output *out);

/* ------------------------------------------------------------------ */
/* NDI (runtime-loaded libndi)                                          */
/* ------------------------------------------------------------------ */
int mc_ndi_available(void);                         // 1 if libndi could be loaded
const char *mc_ndi_version(void);
// Fills buf with newline-separated source names; returns the count.
int mc_ndi_list_sources(char *buf, int bufsize, int wait_ms);
// Comma-separated extra IPs for discovery across subnets (e.g. "10.0.0.5,192.168.1.20").
void mc_ndi_set_extra_ips(const char *ips);

typedef struct mc_ndi_recv mc_ndi_recv;
mc_ndi_recv *mc_ndi_recv_open(const char *source_name, int low_bandwidth, mc_callbacks cb);
void mc_ndi_recv_set_tally(mc_ndi_recv *r, int program, int preview);
void mc_ndi_recv_close(mc_ndi_recv *r);

typedef struct mc_ndi_send mc_ndi_send;
mc_ndi_send *mc_ndi_send_open(const char *name, int fps_num, int fps_den);
void mc_ndi_send_video(mc_ndi_send *s, const uint8_t *bgra, int width, int height, int stride);
void mc_ndi_send_audio(mc_ndi_send *s, const float *stereo, int frames);
int mc_ndi_send_connections(mc_ndi_send *s);
void mc_ndi_send_close(mc_ndi_send *s);

/* ------------------------------------------------------------------ */
/* Blackmagic DeckLink                                                  */
/* ------------------------------------------------------------------ */
int mc_decklink_available(void);                    // 1 if built with SDK and driver present
// Fills buf with newline-separated device names (index order); returns count.
int mc_decklink_list(char *buf, int bufsize);

typedef struct mc_dl_in mc_dl_in;
mc_dl_in *mc_decklink_in_open(int device_index, mc_callbacks cb, char *err, int errlen);
void mc_decklink_in_close(mc_dl_in *in);

typedef struct mc_dl_out mc_dl_out;
mc_dl_out *mc_decklink_out_open(int device_index, int width, int height, int fps_num, int fps_den,
                                char *err, int errlen);
void mc_decklink_out_video(mc_dl_out *o, const uint8_t *bgra, int stride);
void mc_decklink_out_audio(mc_dl_out *o, const float *stereo, int frames);
void mc_decklink_out_close(mc_dl_out *o);

/* ------------------------------------------------------------------ */
/* Pixel / sample helpers (exposed for tests)                           */
/* ------------------------------------------------------------------ */
void mc_uyvy_to_bgra(const uint8_t *src, int src_stride, uint8_t *dst, int dst_stride, int width, int height);
void mc_bgra_to_uyvy(const uint8_t *src, int src_stride, uint8_t *dst, int dst_stride, int width, int height);
void mc_s32_to_float(const int32_t *src, float *dst, int samples);
void mc_float_to_s32(const float *src, int32_t *dst, int samples);

const char *mc_core_version(void);

#ifdef __cplusplus
}
#endif
#endif
