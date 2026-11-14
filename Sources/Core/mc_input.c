#include <math.h>
// FFmpeg-based input: media files, SRT (caller/listener), RTMP, UDP/TS, HLS.
// Decodes video to BGRA and audio to 48 kHz stereo float, delivered via callbacks.
#include "mc_core.h"
#include "mc_util.h"
#define MC_SRT_INTERNAL 1
#include "mc_srt.h"

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/hwcontext.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdatomic.h>
#ifdef __APPLE__
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#endif

typedef struct session session;
#define FILE_AUDIO_LEAD_US 100000
typedef struct audio_chunk {
    float *samples;
    int frames;
    int64_t pos_us;            // media position; its deadline comes from the shared media clock
    int64_t queued_play_us;    // play clock when queued (fallback if the clock never starts)
    struct audio_chunk *next;
} audio_chunk;
// Audio more than this behind the shared clock is dropped instead of being played out of sync.
#define FILE_AUDIO_DROP_LATE_US 80000
// Compressed video packet (NULL pkt = end-of-stream drain marker).
typedef struct vpkt {
    AVPacket *pkt;
    int64_t dur_us;
    struct vpkt *next;
} vpkt;
// Compressed read-ahead limits (ffplay/mpv-style packet queue). Camera MP4s store video up to
// ~0.6 s before the matching audio; a decoded-frame cap alone (12 frames ≈ 0.2 s) blocked the
// demuxer before it reached that audio, so the mixer starved and picture + sound stuttered.
// Compressed packets are cheap (4K 80 Mb/s ≈ 30 MB for 3 s).
#define VPQ_MAX_US 3000000
#define VPQ_MAX_BYTES (256LL * 1024 * 1024)
#define VPQ_MAX_COUNT 1200
typedef struct video_chunk {
    AVFrame *frame;
    int64_t pos_us;             // timeline position (file position + loop offset)
    int64_t loop_off_us;        // loop offset it was decoded with (file position = pos_us - loop_off_us)
    unsigned generation;
    struct video_chunk *next;
} video_chunk;

struct mc_input {
    char *url;
    mc_input_config cfg;
    mc_callbacks cb;
    pthread_t thread;
    atomic_int stop;
    atomic_int restart;
    atomic_int paused;
    atomic_int loop;
    atomic_int finished;          // reached the end (or mark out) without looping
    atomic_int rate_milli;        // playback rate * 1000 (files)
    atomic_llong seek_req_us;     // -1 = none
    atomic_llong mark_in_us;      // -1 = none
    atomic_llong mark_out_us;     // -1 = none
    atomic_llong position_us;     // current media position (files)
    atomic_llong duration_us;     // 0 = unknown / live
    atomic_int nominal_fps_milli; // stream's declared frame rate * 1000 (0 = unknown)
    atomic_int video_decode_mode; // 0 = pending, 1 = VideoToolbox, 2 = software
    int64_t io_deadline_us;   // 0 = none
    int is_file;
    pthread_mutex_t srt_lock;     // guards srt_live (stats are read from the UI)
    mc_srt *srt_live;
    pthread_mutex_t next_lock;
    char *next_url;
    pthread_t preload_thread;
    int preload_running;
    session *preloaded;
    // File audio is released on its own clock. Waiting for audio PTS on the demux/video thread made
    // high-bitrate MP4 packet interleaving stall picture delivery for 100–200 ms at a time.
    pthread_t audio_thread;
    pthread_mutex_t audio_lock;
    pthread_cond_t audio_cond;
    audio_chunk *audio_head, *audio_tail;
    int64_t audio_queue_frames;       // guarded by audio_lock
    int64_t audio_queue_peak_frames;  // guarded by audio_lock
    uint64_t audio_late_chunks;       // guarded by audio_lock
    int64_t audio_max_lateness_us;    // guarded by audio_lock
    // "Play clock": monotonic time that stands still while paused. File audio deadlines use it so
    // queued audio survives a pause and resumes exactly where it stopped (guarded by audio_lock).
    int64_t pause_offset_us;
    int64_t paused_since_us;          // 0 = playing
    // Shared media clock (guarded by audio_lock), in play-clock time. The video presentation
    // thread sets it when it shows a frame after a start/seek/pause/rate change; audio follows it.
    // Two independent anchors drifted apart by the keyframe decode time after every seek.
    int clk_valid;
    int64_t clk_play_us, clk_pos_us;
    int clk_rate;
};

static int64_t play_clock_locked(mc_input *in, int64_t now) {
    int64_t t = now - in->pause_offset_us;
    if (in->paused_since_us) t -= now - in->paused_since_us;
    return t;
}

/* The clock master (video presentation, or audio pacing for audio-only files) re-anchored:
   media position pos_us is presented at monotonic time wall_us. */
static void publish_media_clock(mc_input *in, int64_t pos_us, int64_t wall_us, int rate) {
    pthread_mutex_lock(&in->audio_lock);
    in->clk_play_us = play_clock_locked(in, wall_us);
    in->clk_pos_us = pos_us;
    in->clk_rate = rate > 0 ? rate : 1000;
    in->clk_valid = 1;
    pthread_mutex_unlock(&in->audio_lock);
}

static void invalidate_media_clock(mc_input *in) {
    pthread_mutex_lock(&in->audio_lock);
    in->clk_valid = 0;
    pthread_mutex_unlock(&in->audio_lock);
}

static void clear_audio_queue(mc_input *in) {
    pthread_mutex_lock(&in->audio_lock);
    audio_chunk *p = in->audio_head;
    in->audio_head = in->audio_tail = NULL;
    in->audio_queue_frames = 0;
    pthread_mutex_unlock(&in->audio_lock);
    while (p) { audio_chunk *n = p->next; free(p->samples); free(p); p = n; }
}

static void queue_file_audio(mc_input *in, const float *samples, int frames, int64_t pos_us) {
    if (frames <= 0 || atomic_load(&in->stop)) return;
    audio_chunk *c = (audio_chunk *)calloc(1, sizeof(*c));
    if (!c) return;
    c->samples = (float *)malloc((size_t)frames * 2 * sizeof(float));
    if (!c->samples) { free(c); return; }
    memcpy(c->samples, samples, (size_t)frames * 2 * sizeof(float));
    c->frames = frames; c->pos_us = pos_us;
    pthread_mutex_lock(&in->audio_lock);
    c->queued_play_us = play_clock_locked(in, mc_now_us());
    if (in->audio_tail) in->audio_tail->next = c; else in->audio_head = c;
    in->audio_tail = c;
    in->audio_queue_frames += frames;
    if (in->audio_queue_frames > in->audio_queue_peak_frames)
        in->audio_queue_peak_frames = in->audio_queue_frames;
    pthread_cond_signal(&in->audio_cond);
    pthread_mutex_unlock(&in->audio_lock);
}

static void *audio_release_thread(void *opaque) {
    mc_input *in = (mc_input *)opaque;
#ifdef __APPLE__
    // Presentation deadlines are tighter than decode throughput. Avoid App Nap/default worker QoS
    // delaying a ready audio chunk while the UI or a 4K VideoToolbox session is busy.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    for (;;) {
        pthread_mutex_lock(&in->audio_lock);
        while (!in->audio_head && !atomic_load(&in->stop)) pthread_cond_wait(&in->audio_cond, &in->audio_lock);
        audio_chunk *c = in->audio_head;
        if (!c && atomic_load(&in->stop)) { pthread_mutex_unlock(&in->audio_lock); break; }
        if (in->paused_since_us && !atomic_load(&in->stop)) {
            // Paused: keep queued audio; the play clock is frozen so its deadlines stay valid.
            pthread_mutex_unlock(&in->audio_lock);
            mc_sleep_us(5000);
            continue;
        }
        int64_t released_us = play_clock_locked(in, mc_now_us());
        int64_t presentation_us = released_us;
        if (c->pos_us != AV_NOPTS_VALUE) {
            if (!in->clk_valid) {
                // Wait for the first presented video frame to start the clock. If video never
                // presents (broken stream), let audio start the clock itself after 0.5 s.
                if (released_us - c->queued_play_us < 500000) {
                    pthread_mutex_unlock(&in->audio_lock);
                    mc_sleep_us(2000);
                    continue;
                }
                int r = atomic_load(&in->rate_milli);
                in->clk_play_us = released_us + FILE_AUDIO_LEAD_US;
                in->clk_pos_us = c->pos_us;
                in->clk_rate = r > 0 ? r : 1000;
                in->clk_valid = 1;
            }
            presentation_us = in->clk_play_us + (c->pos_us - in->clk_pos_us) * 1000 / in->clk_rate;
        }
        int64_t wait = presentation_us - FILE_AUDIO_LEAD_US - released_us;
        if (wait > 0) { pthread_mutex_unlock(&in->audio_lock); mc_sleep_us(wait > 10000 ? 10000 : wait); continue; }
        in->audio_head = c->next;
        if (!in->audio_head) in->audio_tail = NULL;
        in->audio_queue_frames -= c->frames;
        if (in->audio_queue_frames < 0) in->audio_queue_frames = 0;
        // Measure missed media deadlines, not the intentional 100 ms early-release target.
        int64_t late_us = released_us - presentation_us;
        if (late_us > 0) {
            in->audio_late_chunks++;
            if (late_us > in->audio_max_lateness_us) in->audio_max_lateness_us = late_us;
        }
        pthread_mutex_unlock(&in->audio_lock);
        // Audio decoded before the frame the clock started on (e.g. while cued) is stale: playing
        // it would put sound behind picture for the rest of the clip.
        if (late_us <= FILE_AUDIO_DROP_LATE_US &&
            !atomic_load(&in->stop) && !atomic_load(&in->paused) && in->cb.on_audio)
            in->cb.on_audio(in->cb.user, c->samples, c->frames);
        free(c->samples); free(c);
    }
    return NULL;
}

static int interrupt_cb(void *opaque) {
    mc_input *in = (mc_input *)opaque;
    if (atomic_load(&in->stop)) return 1;
    if (in->io_deadline_us && mc_now_us() > in->io_deadline_us) return 1;
    return 0;
}

static void status(mc_input *in, int state, const char *fmt, ...) {
    if (!in->cb.on_status) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    in->cb.on_status(in->cb.user, state, buf);
}


static enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    }
    // fall back to the first software format
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*p);
        if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
    }
    return fmts[0];
}

static int detect_is_file(const char *url) {
    if (strncmp(url, "file:", 5) == 0) return 1;
    return strstr(url, "://") == NULL;
}

struct session {
    AVFormatContext *fmt;
    AVCodecContext *vdec, *adec;
    int vidx, aidx;
    AVBufferRef *hw_device;
    struct SwsContext *sws;
    int sws_w, sws_h, sws_fmt, sws_cs, sws_range;
    uint8_t *bgra;
    int bgra_size;
#ifdef __APPLE__
    // Software-decoded YUV is repacked into NV12 IOSurfaces and converted to RGB on the GPU,
    // instead of a full-frame CPU sws_scale to BGRA (≈12 ms/frame for 1080p 4:2:2 10-bit).
    CVPixelBufferPoolRef nv12_pool;
    int nv12_w, nv12_h, nv12_full;
#endif
    SwrContext *swr;
    int swr_rate, swr_fmt;
    int swr_rate_milli;           // playback rate the resampler was built for (rate conform)
    AVChannelLayout swr_layout;
    float *abuf;
    int abuf_frames;
    AVFrame *frame, *swframe;
    AVPacket *pkt;
    mc_srt *srt;                  // direct libsrt transport (srt:// URLs)
    AVIOContext *srt_pb;
    // pacing
    int64_t base_wall_us;
    int64_t base_pts_us;
    // Audio packets are decoded by the demux thread while video is presented on a separate
    // thread. Keep an independent audio clock so audio timing cannot race the video clock.
    int64_t audio_base_wall_us;
    int64_t audio_base_pts_us;
    int audio_cur_rate_milli;
    int64_t last_pts_us;
    int64_t start_us;        // container start time
    int64_t skip_until_us;   // drop frames before this position after a seek
    // Gapless looping: pacing, the media clock and the audio/video queues run on a timeline that keeps
    // counting across loop wraps (timeline = file position + loop_off_us). Before, every wrap threw the
    // decoded tail away, waited for the queues to drain and restarted the clock from the first new
    // frame, so audio had a hole of one frame + seek + keyframe decode (~45 ms) at every loop point.
    int64_t loop_off_us;
    int64_t vend_us, aend_us;    // timeline end of the video / audio decoded in this pass (0 = none)
    int cur_rate_milli;
    int64_t slack_min_us;        // live pacing: smallest "early" margin seen in the current window
    int64_t slack_t0_us;
    int64_t drain_us;            // live pacing: latency still to remove, spread over many frames
    int drain_backlog;           // the drain was asked for by the SRT receive backlog (not cancelled by a late frame)
    int64_t prev_live_pts_us;
    int64_t live_t0_us;          // when live pacing (re)started
    int need_frame;          // show one frame after a seek even while paused
    int nominal_fps_milli;
    AVPacket **pre_pkts;
    int pre_count, pre_cap, pre_index;
    // File decoding must never sleep on presentation timestamps. The demux/decode thread fills
    // this bounded queue while a dedicated presentation thread releases frames on the media clock.
    // That lets interleaved audio packets continue to be decoded ahead instead of starving the
    // CoreAudio mixer every time the next video frame is early.
    pthread_t video_thread;
    pthread_mutex_t video_lock;
    pthread_cond_t video_cond;
    video_chunk *video_head, *video_tail;
    int video_count;
    int video_thread_running;
    int video_stop;
    atomic_uint video_generation;
    // Files: demux → compressed packet queue → dedicated video decode thread → frame queue.
    // The demuxer never waits on decoded-frame backpressure, so interleaved audio keeps flowing.
    pthread_t vdec_thread;
    int vdec_running;
    atomic_int vdec_stop;
    atomic_int vflush;            // seek in progress: decode thread discards its output
    pthread_mutex_t vdec_lock;    // held by the decode thread while it uses s->vdec
    pthread_mutex_t vpq_lock;
    pthread_cond_t vpq_cond;
    vpkt *vpq_head, *vpq_tail;
    int vpq_count;
    int vpq_busy;                 // decode thread is working on a popped packet
    int64_t vpq_bytes, vpq_dur_us;
    AVFrame *vframe;              // decode-thread frame (s->frame belongs to the demux thread)
};

static void vpq_clear_locked(session *s) {
    vpkt *p = s->vpq_head;
    s->vpq_head = s->vpq_tail = NULL;
    s->vpq_count = 0;
    s->vpq_bytes = s->vpq_dur_us = 0;
    while (p) { vpkt *n = p->next; av_packet_free(&p->pkt); free(p); p = n; }
    pthread_cond_broadcast(&s->vpq_cond);
}

static void session_sync_init(session *s) {
    pthread_mutex_init(&s->video_lock, NULL);
    pthread_cond_init(&s->video_cond, NULL);
    pthread_mutex_init(&s->vdec_lock, NULL);
    pthread_mutex_init(&s->vpq_lock, NULL);
    pthread_cond_init(&s->vpq_cond, NULL);
}

static void session_sync_destroy(session *s) {
    pthread_mutex_destroy(&s->video_lock);
    pthread_cond_destroy(&s->video_cond);
    pthread_mutex_destroy(&s->vdec_lock);
    pthread_mutex_destroy(&s->vpq_lock);
    pthread_cond_destroy(&s->vpq_cond);
}

static void clear_video_queue_locked(session *s) {
    video_chunk *p = s->video_head;
    s->video_head = s->video_tail = NULL;
    s->video_count = 0;
    while (p) {
        video_chunk *n = p->next;
        av_frame_free(&p->frame);
        free(p);
        p = n;
    }
    pthread_cond_broadcast(&s->video_cond);
}

static void clear_video_queue(session *s) {
    pthread_mutex_lock(&s->video_lock);
    clear_video_queue_locked(s);
    pthread_mutex_unlock(&s->video_lock);
}

static void session_close(session *s) {
    if (s->vdec) avcodec_free_context(&s->vdec);
    if (s->adec) avcodec_free_context(&s->adec);
    if (s->fmt) avformat_close_input(&s->fmt);
    if (s->srt_pb) {
        av_freep(&s->srt_pb->buffer);
        avio_context_free(&s->srt_pb);
    }
    if (s->hw_device) av_buffer_unref(&s->hw_device);
    if (s->sws) sws_freeContext(s->sws);
#ifdef __APPLE__
    if (s->nv12_pool) { CVPixelBufferPoolRelease(s->nv12_pool); s->nv12_pool = NULL; }
#endif
    if (s->swr) swr_free(&s->swr);
    av_channel_layout_uninit(&s->swr_layout);
    av_frame_free(&s->frame);
    av_frame_free(&s->vframe);
    av_frame_free(&s->swframe);
    av_packet_free(&s->pkt);
    for (int i = 0; i < s->pre_count; i++) av_packet_free(&s->pre_pkts[i]);
    free(s->pre_pkts);
    free(s->bgra);
    free(s->abuf);
    clear_video_queue(s);
    pthread_mutex_lock(&s->vpq_lock);
    vpq_clear_locked(s);
    pthread_mutex_unlock(&s->vpq_lock);
    session_sync_destroy(s);
    memset(s, 0, sizeof(*s));
}

/* Close a session and its SRT transport (hidden from the stats reader first). */
static void session_end(mc_input *in, session *s) {
    pthread_mutex_lock(&in->srt_lock);
    in->srt_live = NULL;
    pthread_mutex_unlock(&in->srt_lock);
    mc_srt *srt = s->srt;
    session_close(s);
    mc_srt_close(srt);
}

static AVCodecContext *open_decoder(mc_input *in, session *s, AVStream *st, int video) {
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) return NULL;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return NULL;
    if (avcodec_parameters_to_context(ctx, st->codecpar) < 0) {
        avcodec_free_context(&ctx);
        return NULL;
    }
    ctx->pkt_timebase = st->time_base;
    if (video) {
        ctx->thread_count = 0;  // auto
        if (in->cfg.hwaccel) {
            if (av_hwdevice_ctx_create(&s->hw_device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
                ctx->hw_device_ctx = av_buffer_ref(s->hw_device);
                ctx->get_format = get_hw_format;
            }
        }
    }
    if (avcodec_open2(ctx, codec, NULL) < 0) {
        avcodec_free_context(&ctx);
        return NULL;
    }
    return ctx;
}

static int session_open(mc_input *in, session *s, const char *url, int publish) {
    memset(s, 0, sizeof(*s));
    session_sync_init(s);
    atomic_init(&s->video_generation, 1);
    s->vidx = s->aidx = -1;
    s->fmt = avformat_alloc_context();
    if (!s->fmt) return AVERROR(ENOMEM);
    s->fmt->interrupt_callback.callback = interrupt_cb;
    s->fmt->interrupt_callback.opaque = in;

    AVDictionary *opts = NULL;
    if (!in->is_file) {
        if (in->cfg.low_latency) {
            av_dict_set(&opts, "probesize", "1000000", 0);
            av_dict_set(&opts, "analyzeduration", "1000000", 0);
        }
    }
    // RTMP server mode: "rtmp://0.0.0.0:1935/live/key?listen=1" -> option listen=1 on the bare URL
    char *open_url = strdup(url);
    // RTSP transport: "rtsp://…#tcp" or "rtsp://…#udp"
    if (open_url && strncmp(open_url, "rtsp", 4) == 0) {
        char *hash = strrchr(open_url, '#');
        if (hash && (strcmp(hash, "#tcp") == 0 || strcmp(hash, "#udp") == 0)) {
            av_dict_set(&opts, "rtsp_transport", hash + 1, 0);
            *hash = 0;
        }
    }
    // Transport stream over UDP: generous FIFO so bursts don't drop
    if (open_url && strncmp(open_url, "udp://", 6) == 0) {
        av_dict_set(&opts, "overrun_nonfatal", "1", 0);
        av_dict_set(&opts, "fifo_size", "1000000", 0);
    }
    if (open_url && strncmp(open_url, "rtmp", 4) == 0) {
        char *q = strstr(open_url, "?listen=1");
        if (!q) q = strstr(open_url, "&listen=1");
        if (q) {
            memmove(q, q + 9, strlen(q + 9) + 1);
            av_dict_set(&opts, "listen", "1", 0);
            av_dict_set(&opts, "timeout", "-1", 0);
        } else {
            av_dict_set(&opts, "rw_timeout", "10000000", 0);
        }
    }
    in->io_deadline_us = 0;  // allow listeners to wait indefinitely
    const AVInputFormat *forced = NULL;
    if (open_url && strncmp(open_url, "srt://", 6) == 0 && mc_srt_supported()) {
        // direct libsrt: same behaviour as FFmpeg's srt:// plus live link statistics
        char err[256] = {0};
        if (strstr(open_url, "mode=listener") || strstr(open_url, "listen=1"))
            if (publish) status(in, MC_STATE_CONNECTING, "SRT 접속 대기 중…");
        mc_srt *srt = mc_srt_open(open_url, 0, interrupt_cb, in, err, sizeof(err));
        if (!srt) {
            if (publish) status(in, MC_STATE_ERROR, "%s", err);
            free(open_url);
            av_dict_free(&opts);
            return AVERROR(EIO);
        }
        uint8_t *iobuf = (uint8_t *)av_malloc(65536);
        s->srt_pb = avio_alloc_context(iobuf, 65536, 0, srt, (int (*)(void *, uint8_t *, int))mc_srt_read, NULL, NULL);
        s->srt = srt;
        s->fmt->pb = s->srt_pb;
        s->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
        forced = av_find_input_format("mpegts");
        pthread_mutex_lock(&in->srt_lock);
        in->srt_live = srt;
        pthread_mutex_unlock(&in->srt_lock);
        if (publish) status(in, MC_STATE_CONNECTING, "SRT 연결됨 — 스트림 분석 중");
    }
    int ret = avformat_open_input(&s->fmt, forced ? NULL : (open_url ? open_url : url), forced, &opts);
    free(open_url);
    av_dict_free(&opts);
    if (ret < 0) {
        s->fmt = NULL;  // freed by avformat_open_input on failure
        return ret;
    }
    in->io_deadline_us = mc_now_us() + 10000000;
    ret = avformat_find_stream_info(s->fmt, NULL);
    if (ret < 0) return ret;

    s->vidx = av_find_best_stream(s->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    s->aidx = av_find_best_stream(s->fmt, AVMEDIA_TYPE_AUDIO, -1, s->vidx, NULL, 0);
    if (s->vidx >= 0) {
        s->vdec = open_decoder(in, s, s->fmt->streams[s->vidx], 1);
        if (!s->vdec) s->vidx = -1;
    }
    if (s->aidx >= 0) {
        s->adec = open_decoder(in, s, s->fmt->streams[s->aidx], 0);
        if (!s->adec) s->aidx = -1;
    }
    if (publish && in->cb.on_audio_presence)
        in->cb.on_audio_presence(in->cb.user, s->aidx >= 0 ? 1 : 0);
    if (s->vidx < 0 && s->aidx < 0) return AVERROR_STREAM_NOT_FOUND;
    for (unsigned i = 0; i < s->fmt->nb_streams; i++) {
        if ((int)i != s->vidx && (int)i != s->aidx) s->fmt->streams[i]->discard = AVDISCARD_ALL;
    }
    s->frame = av_frame_alloc();
    s->vframe = av_frame_alloc();
    s->swframe = av_frame_alloc();
    s->pkt = av_packet_alloc();
    s->base_wall_us = 0;
    s->base_pts_us = AV_NOPTS_VALUE;
    s->audio_base_wall_us = 0;
    s->audio_base_pts_us = AV_NOPTS_VALUE;
    s->audio_cur_rate_milli = 1000;
    s->start_us = s->fmt->start_time != AV_NOPTS_VALUE ? s->fmt->start_time : 0;
    s->skip_until_us = 0;
    // A cued file still needs one decoded picture for the preview monitor.
    s->need_frame = in->is_file ? 1 : 0;
    s->cur_rate_milli = 1000;
    if (s->vidx >= 0) {
        AVStream *vs = s->fmt->streams[s->vidx];
        // Declared rate for the format label. Phone videos are variable-rate (avg e.g. 31.58), so snap to
        // the broadcast rate they were shot at: avg if standard, else r_frame_rate, else nearest standard.
        static const double std_rates[] = {23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88, 120};
        double avg = vs->avg_frame_rate.num > 0 && vs->avg_frame_rate.den > 0 ? av_q2d(vs->avg_frame_rate) : 0;
        double rr = vs->r_frame_rate.num > 0 && vs->r_frame_rate.den > 0 ? av_q2d(vs->r_frame_rate) : 0;
        double f = avg > 0 ? avg : rr, best = 0, bestd = 1e9;
        for (unsigned k = 0; k < sizeof(std_rates) / sizeof(std_rates[0]); k++) {
            double d = fabs(std_rates[k] - f) / std_rates[k];
            if (d < bestd) { bestd = d; best = std_rates[k]; }
        }
        if (bestd > 0.005) {
            int rr_std = 0;
            for (unsigned k = 0; k < sizeof(std_rates) / sizeof(std_rates[0]); k++)
                if (rr > 0 && fabs(std_rates[k] - rr) / std_rates[k] < 0.005) rr_std = 1;
            if (rr_std && avg > 0 && fabs(rr - avg) / rr < 0.15) f = rr;
            else if (bestd < 0.08) f = best;
        }
        s->nominal_fps_milli = (f >= 1 && f <= 240) ? (int)(f * 1000 + 0.5) : 0;
        if (publish) atomic_store(&in->nominal_fps_milli, s->nominal_fps_milli);
    }
    if (publish) atomic_store(&in->duration_us, (in->is_file && s->fmt->duration > 0) ? (long long)s->fmt->duration : 0);
    return 0;
}

static int64_t frame_pts_us(AVFrame *f, AVRational tb);
typedef struct { mc_input *in; char *url; } preload_job;

static void *preload_next(void *opaque) {
    preload_job *job = (preload_job *)opaque;
    session *s = (session *)calloc(1, sizeof(*s));
    int ok = s && session_open(job->in, s, job->url, 0) == 0;
    // Read ahead packets without decoding. Keeping their original interleaving preserves A/V sync,
    // while removing demux/index I/O from the on-air hand-off.
    int64_t audio_us = 0;
    // Cache two seconds of interleaved packets. This does not touch the original file and makes
    // high-bitrate 4K -> 1080p and 44.1 -> 48 kHz list transitions independent of storage latency.
    while (ok && audio_us < 2000000 && s->pre_count < 4096) {
        AVPacket *p = av_packet_alloc();
        if (!p || av_read_frame(s->fmt, p) < 0) { av_packet_free(&p); break; }
        if (s->pre_count == s->pre_cap) {
            int nc = s->pre_cap ? s->pre_cap * 2 : 64;
            AVPacket **np = (AVPacket **)realloc(s->pre_pkts, (size_t)nc * sizeof(*np));
            if (!np) { av_packet_free(&p); ok = 0; break; }
            s->pre_pkts = np; s->pre_cap = nc;
        }
        s->pre_pkts[s->pre_count++] = p;
        if (p->stream_index == s->aidx) {
            AVRational tb = s->fmt->streams[s->aidx]->time_base;
            audio_us += p->duration > 0 ? av_rescale_q(p->duration, tb, (AVRational){1, 1000000}) : 20000;
        }
    }
    pthread_mutex_lock(&job->in->next_lock);
    if (ok && job->in->next_url && strcmp(job->in->next_url, job->url) == 0 && !atomic_load(&job->in->stop)) {
        if (job->in->preloaded) { session_end(job->in, job->in->preloaded); free(job->in->preloaded); }
        job->in->preloaded = s;
        s = NULL;
    }
    job->in->preload_running = 0;
    pthread_mutex_unlock(&job->in->next_lock);
    if (s) { session_end(job->in, s); free(s); }
    free(job->url);
    free(job);
    return NULL;
}

static int64_t frame_pts_us(AVFrame *f, AVRational tb) {
    int64_t pts = f->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) pts = f->pts;
    if (pts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return av_rescale_q(pts, tb, (AVRational){1, 1000000});
}

static int wake_requested(mc_input *in) {
    return atomic_load(&in->stop) || atomic_load(&in->restart) || atomic_load(&in->seek_req_us) >= 0;
}

/* pts_us is the media position (start time removed). */
/* Files: play at their own speed. Live streams (SRT/RTMP/UDP…): small jitter buffer — frames are
   released on their timestamps (+80 ms) instead of whenever the network delivered them, so bursts
   don't become uneven motion. Latency stays bounded: falling >300 ms behind or running >600 ms
   ahead re-anchors the clock. */
#define LIVE_JITTER_US 80000
static void pace(mc_input *in, session *s, int64_t pts_us) {
    int live = !in->is_file && in->cfg.realtime < 0;
    int realtime = in->cfg.realtime < 0 ? 1 : in->cfg.realtime;
    if (!realtime || pts_us == AV_NOPTS_VALUE) return;
    if (live) {
        int64_t now = mc_now_us();
        if (s->base_pts_us == AV_NOPTS_VALUE || pts_us < s->last_pts_us - 1000000 || pts_us > s->last_pts_us + 5000000) {
            s->base_pts_us = pts_us;
            s->base_wall_us = now + LIVE_JITTER_US;
            s->slack_t0_us = 0;
            s->drain_us = 0;
            s->drain_backlog = 0;
            s->prev_live_pts_us = 0;
            s->live_t0_us = now;
        }
        // nominal frame spacing (clamped) — used to spread latency corrections invisibly
        int64_t fdt = s->prev_live_pts_us ? pts_us - s->prev_live_pts_us : 33333;
        if (fdt < 4000 || fdt > 100000) fdt = 33333;
        s->prev_live_pts_us = pts_us;
        s->last_pts_us = pts_us;
        int64_t target = s->base_wall_us + (pts_us - s->base_pts_us);
        if (now - target > 300000 || target - now > 2000000) {      // long stall / big jump: start over
            s->base_pts_us = pts_us;
            s->base_wall_us = now + LIVE_JITTER_US;
            target = s->base_wall_us;
            s->slack_t0_us = 0;
            s->drain_us = 0;
            s->drain_backlog = 0;
        } else if (now > target) {
            // Frame is late: show it now. Only a lateness of more than a frame (the source really
            // arrived late: network stall, slower sender clock) moves the clock and gives the buffer
            // more room. Smaller lateness is our own decode / wake-up jitter — moving the clock for it
            // made 60 fps SRT play ~2.7 % slow, so libsrt's buffer grew until it overflowed and dropped
            // packets (2.2.0). The jitter margin absorbs it instead.
            int64_t late = now - target;
            target = now;
            if (late > fdt) {
                s->base_wall_us += late;
                // short of buffer, not long: stop a slack drain — but never a drain the SRT backlog
                // asked for (that backlog is real and only grows if we stop)
                if (!s->drain_backlog) s->drain_us = 0;
            }
        }
        // Gradual drain: play slightly fast (4 %, or 8 % while more than 200 ms is pending) until
        // caught up. Every frame still gets its own slot — even motion, no multi-frame bursts.
        if (s->drain_us > 0) {
            // 4 %, 8 % above 200 ms, 12.5 % above 1 s still to remove
            int64_t step = s->drain_us > 1000000 ? fdt / 8 : s->drain_us > 200000 ? fdt / 12 : fdt / 25;
            if (step > s->drain_us) step = s->drain_us;
            s->base_wall_us -= step;
            target -= step;
            s->drain_us -= step;
            if (s->drain_us <= 0) s->drain_backlog = 0;
        }
        // Every second: if every frame in the window was early by more than the jitter margin (or
        // libsrt is holding backlog beyond its latency), schedule a drain of the excess.
        int64_t slack = target - now;
        if (s->slack_t0_us == 0) { s->slack_t0_us = now; s->slack_min_us = slack; }
        if (slack < s->slack_min_us) s->slack_min_us = slack;
        if (now - s->slack_t0_us > 1000000) {
            int backlog = s->srt ? mc_srt_backlog_ms(s->srt) : 0;
            if (s->drain_us == 0 || (backlog > 250 && !s->drain_backlog)) {
                int64_t want = 0;
                // libsrt already de-jitters (TSBPD); our own hold and the demuxer also show up in its
                // buffer (~60–90 ms), so drain only a clear excess, with hysteresis. A backlog drain
                // runs to the end (a late frame can't cancel it); a slack drain stops at a late frame.
                if (backlog > 250) {
                    want = (int64_t)(backlog - 100) * 1000;               // hysteresis: 250 → 100
                    if (want > 3000000) want = 3000000;
                    s->drain_backlog = 1;
                } else if (s->slack_min_us > LIVE_JITTER_US / 2) {
                    want = s->slack_min_us - LIVE_JITTER_US / 4;
                    if (want > 600000) want = 600000;
                    s->drain_backlog = 0;
                }
                if (want > s->drain_us) s->drain_us = want;
            }
            s->slack_t0_us = now;
            s->slack_min_us = target - now;
        }
        while (target > now && !wake_requested(in)) {
            int64_t d = target - now;
            mc_sleep_us(d > 20000 ? 20000 : d);
            now = mc_now_us();
        }
        return;
    }
    int rate = atomic_load(&in->rate_milli);
    if (rate < 50) rate = 50;
    if (s->base_pts_us == AV_NOPTS_VALUE || pts_us < s->last_pts_us - 1000000 ||
        pts_us > s->last_pts_us + 5000000 || rate != s->cur_rate_milli) {
        // first frame, discontinuity or rate change: re-anchor
        s->base_pts_us = pts_us;
        s->base_wall_us = mc_now_us();
        s->cur_rate_milli = rate;
        publish_media_clock(in, pts_us, s->base_wall_us, rate);
    }
    s->last_pts_us = pts_us;
    int64_t target = s->base_wall_us + (pts_us - s->base_pts_us) * 1000 / rate;
    int64_t now = mc_now_us();
    while (target > now && !wake_requested(in)) {
        int64_t d = target - now;
        mc_sleep_us(d > 20000 ? 20000 : d);
        now = mc_now_us();
    }
}

#ifdef __APPLE__
typedef struct {
    const AVFrame *src;
    uint8_t *y, *uv;
    size_t ys, uvs;
    int w, h, cw, ch;      // luma size, NV12 chroma plane size (in UV pairs / rows)
    int shift;             // 0 = 8-bit source, 2 = 10-bit source
    int vsub;              // source chroma is full height (4:2:2) → average 2 rows
    int planar;            // 1 = separate U/V planes, 0 = already NV12
} nv12_job;

#define NV12_BANDS 8

static void nv12_band(void *ctx, size_t band) {
    const nv12_job *j = (const nv12_job *)ctx;
    const AVFrame *f = j->src;
    int y0 = (int)(band * (size_t)j->h / NV12_BANDS), y1 = (int)((band + 1) * (size_t)j->h / NV12_BANDS);
    for (int y = y0; y < y1; y++) {
        uint8_t *d = j->y + (size_t)y * j->ys;
        if (j->shift == 0) {
            memcpy(d, f->data[0] + (size_t)y * f->linesize[0], (size_t)j->w);
        } else {
            const uint16_t *sl = (const uint16_t *)(f->data[0] + (size_t)y * f->linesize[0]);
            for (int x = 0; x < j->w; x++) d[x] = (uint8_t)((sl[x] >> 2) > 255 ? 255 : (sl[x] >> 2));
        }
    }
    int c0 = (int)(band * (size_t)j->ch / NV12_BANDS), c1 = (int)((band + 1) * (size_t)j->ch / NV12_BANDS);
    for (int cy = c0; cy < c1; cy++) {
        uint8_t *d = j->uv + (size_t)cy * j->uvs;
        if (!j->planar) {
            memcpy(d, f->data[1] + (size_t)cy * f->linesize[1], (size_t)j->cw * 2);
            continue;
        }
        int sy = j->vsub ? cy * 2 : cy;
        int sy2 = j->vsub ? (sy + 1 < j->h ? sy + 1 : sy) : sy;
        if (j->shift == 0) {
            const uint8_t *u = f->data[1] + (size_t)sy * f->linesize[1], *v = f->data[2] + (size_t)sy * f->linesize[2];
            const uint8_t *u2 = f->data[1] + (size_t)sy2 * f->linesize[1], *v2 = f->data[2] + (size_t)sy2 * f->linesize[2];
            for (int x = 0; x < j->cw; x++) {
                d[2 * x] = (uint8_t)((u[x] + u2[x] + 1) >> 1);
                d[2 * x + 1] = (uint8_t)((v[x] + v2[x] + 1) >> 1);
            }
        } else {
            const uint16_t *u = (const uint16_t *)(f->data[1] + (size_t)sy * f->linesize[1]);
            const uint16_t *v = (const uint16_t *)(f->data[2] + (size_t)sy * f->linesize[2]);
            const uint16_t *u2 = (const uint16_t *)(f->data[1] + (size_t)sy2 * f->linesize[1]);
            const uint16_t *v2 = (const uint16_t *)(f->data[2] + (size_t)sy2 * f->linesize[2]);
            for (int x = 0; x < j->cw; x++) {
                int uu = (u[x] + u2[x] + 4) >> 3, vv = (v[x] + v2[x] + 4) >> 3;   // avg of 2, 10 → 8 bit
                d[2 * x] = (uint8_t)(uu > 255 ? 255 : uu);
                d[2 * x + 1] = (uint8_t)(vv > 255 ? 255 : vv);
            }
        }
    }
}

/// Returns 1 when the frame was delivered as an NV12 IOSurface (GPU does YUV→RGB), 0 to fall back.
static int deliver_nv12(mc_input *in, session *s, AVFrame *f, AVFrame *src, int cs, int range) {
    if (!in->cb.on_pixelbuffer) return 0;
    int shift, vsub, planar;
    switch (src->format) {
    case AV_PIX_FMT_YUV420P: case AV_PIX_FMT_YUVJ420P: shift = 0; vsub = 0; planar = 1; break;
    case AV_PIX_FMT_YUV422P: case AV_PIX_FMT_YUVJ422P: shift = 0; vsub = 1; planar = 1; break;
    case AV_PIX_FMT_YUV420P10LE: shift = 2; vsub = 0; planar = 1; break;
    case AV_PIX_FMT_YUV422P10LE: shift = 2; vsub = 1; planar = 1; break;
    case AV_PIX_FMT_NV12: shift = 0; vsub = 0; planar = 0; break;
    default: return 0;
    }
    int w = src->width, h = src->height;
    if (w < 2 || h < 2) return 0;
    if (!s->nv12_pool || s->nv12_w != w || s->nv12_h != h || s->nv12_full != range) {
        if (s->nv12_pool) { CVPixelBufferPoolRelease(s->nv12_pool); s->nv12_pool = NULL; }
        OSType pf = range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        CFNumberRef cfw = CFNumberCreate(NULL, kCFNumberIntType, &w);
        CFNumberRef cfh = CFNumberCreate(NULL, kCFNumberIntType, &h);
        CFNumberRef cff = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
        CFDictionaryRef ios = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *keys[] = {kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey,
                              kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey};
        const void *vals[] = {cfw, cfh, cff, ios, kCFBooleanTrue};
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CVPixelBufferPoolCreate(NULL, NULL, attrs, &s->nv12_pool);
        CFRelease(attrs); CFRelease(ios); CFRelease(cff); CFRelease(cfh); CFRelease(cfw);
        s->nv12_w = w; s->nv12_h = h; s->nv12_full = range;
        if (!s->nv12_pool) return 0;
    }
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, s->nv12_pool, &pb) != kCVReturnSuccess || !pb) return 0;
    CVPixelBufferLockBaseAddress(pb, 0);
    nv12_job j = {
        .src = src,
        .y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0),
        .uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1),
        .ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
        .uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
        .w = w, .h = h,
        .cw = (int)CVPixelBufferGetWidthOfPlane(pb, 1), .ch = (int)CVPixelBufferGetHeightOfPlane(pb, 1),
        .shift = shift, .vsub = vsub, .planar = planar,
    };
    if (!vsub && planar) j.ch = j.ch < (h + 1) / 2 ? j.ch : (h + 1) / 2;
    dispatch_apply_f(NV12_BANDS, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), &j, nv12_band);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                          (cs == AVCOL_SPC_BT709 || cs == AVCOL_SPC_BT2020_NCL || cs == AVCOL_SPC_BT2020_CL)
                              ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                          kCVAttachmentMode_ShouldPropagate);
    int64_t pts = frame_pts_us(f, s->fmt->streams[s->vidx]->time_base);
    in->cb.on_pixelbuffer(in->cb.user, (void *)pb, pts);
    CVPixelBufferRelease(pb);
    return 1;
}
#endif

static void deliver_video(mc_input *in, session *s, AVFrame *f) {
    AVFrame *src = f;
    if (f->format == AV_PIX_FMT_VIDEOTOOLBOX && f->data[3] && in->cb.on_pixelbuffer) {
        atomic_store(&in->video_decode_mode, 1);
        // zero-copy: hand the decoder's IOSurface straight to the app (GPU converts it)
        int64_t pts = frame_pts_us(f, s->fmt->streams[s->vidx]->time_base);
        in->cb.on_pixelbuffer(in->cb.user, (void *)f->data[3], pts);
        return;
    }
    atomic_store(&in->video_decode_mode, 2);
    if (f->format == AV_PIX_FMT_VIDEOTOOLBOX || (f->hw_frames_ctx != NULL)) {
        av_frame_unref(s->swframe);
        if (av_hwframe_transfer_data(s->swframe, f, 0) < 0) return;
        s->swframe->color_range = f->color_range;
        s->swframe->colorspace = f->colorspace;
        src = s->swframe;
    }
    int w = src->width, h = src->height;
    if (w <= 0 || h <= 0) return;
    int cs = src->colorspace;
    if (cs == AVCOL_SPC_UNSPECIFIED) cs = (h >= 720) ? AVCOL_SPC_BT709 : AVCOL_SPC_BT470BG;
    int range = src->color_range == AVCOL_RANGE_JPEG ? 1 : 0;
    if (src->format == AV_PIX_FMT_YUVJ420P || src->format == AV_PIX_FMT_YUVJ422P ||
        src->format == AV_PIX_FMT_YUVJ444P) range = 1;
#ifdef __APPLE__
    if (deliver_nv12(in, s, f, src, cs, range)) return;
#endif
    if (!s->sws || s->sws_w != w || s->sws_h != h || s->sws_fmt != src->format || s->sws_cs != cs ||
        s->sws_range != range) {
        if (s->sws) sws_freeContext(s->sws);
        s->sws = mc_sws_get(w, h, src->format, w, h, AV_PIX_FMT_BGRA, SWS_BILINEAR);
        if (!s->sws) return;
        int sws_cs = SWS_CS_ITU601;
        if (cs == AVCOL_SPC_BT709) sws_cs = SWS_CS_ITU709;
        else if (cs == AVCOL_SPC_BT2020_NCL || cs == AVCOL_SPC_BT2020_CL) sws_cs = SWS_CS_BT2020;
        const int *inv = sws_getCoefficients(sws_cs);
        const int *tbl = sws_getCoefficients(SWS_CS_DEFAULT);
        sws_setColorspaceDetails(s->sws, inv, range, tbl, 1, 0, 1 << 16, 1 << 16);
        s->sws_w = w;
        s->sws_h = h;
        s->sws_fmt = src->format;
        s->sws_cs = cs;
        s->sws_range = range;
        int need = w * h * 4;
        if (need > s->bgra_size) {
            free(s->bgra);
            s->bgra = (uint8_t *)malloc(need);
            s->bgra_size = s->bgra ? need : 0;
        }
    }
    if (!s->bgra) return;
    uint8_t *dst[4] = {s->bgra, NULL, NULL, NULL};
    int dst_stride[4] = {w * 4, 0, 0, 0};
    sws_scale(s->sws, (const uint8_t *const *)src->data, src->linesize, 0, h, dst, dst_stride);
    if (in->cb.on_video) {
        int64_t pts = frame_pts_us(f, s->fmt->streams[s->vidx]->time_base);
        in->cb.on_video(in->cb.user, s->bgra, w, h, w * 4, pts);
    }
}

// Keep a short decoded lead so demux reaches interleaved audio packets without retaining a large
// 4K VideoToolbox surface queue. Twelve frames is about 200 ms at 60 fps.
#define FILE_VIDEO_QUEUE_MAX 12

static int queue_file_video(mc_input *in, session *s, AVFrame *f, int64_t pos_us) {
    video_chunk *c = (video_chunk *)calloc(1, sizeof(*c));
    if (!c) return -1;
    c->frame = av_frame_clone(f);
    if (!c->frame) { free(c); return -1; }
    c->pos_us = pos_us;
    c->loop_off_us = s->loop_off_us;
    c->generation = atomic_load(&s->video_generation);
    pthread_mutex_lock(&s->video_lock);
    while (s->video_count >= FILE_VIDEO_QUEUE_MAX && !s->video_stop && !wake_requested(in) &&
           !atomic_load(&s->vflush) && !atomic_load(&s->vdec_stop)) {
        // Timed polling keeps seek/restart responsive even when the queue is full and no consumer
        // signal is generated for the command itself.
        pthread_mutex_unlock(&s->video_lock);
        mc_sleep_us(2000);
        pthread_mutex_lock(&s->video_lock);
    }
    if (s->video_stop || wake_requested(in) || atomic_load(&s->vflush) || atomic_load(&s->vdec_stop)) {
        pthread_mutex_unlock(&s->video_lock);
        av_frame_free(&c->frame); free(c);
        return -1;
    }
    if (s->video_tail) s->video_tail->next = c; else s->video_head = c;
    s->video_tail = c;
    s->video_count++;
    pthread_cond_broadcast(&s->video_cond);
    pthread_mutex_unlock(&s->video_lock);
    return 0;
}

static void *video_release_thread(void *opaque) {
    struct { mc_input *in; session *s; } *ctx = opaque;
    mc_input *in = ctx->in;
    session *s = ctx->s;
    free(ctx);
#ifdef __APPLE__
    // A decoded frame that is already due must outrank background decode/UI work. This mirrors the
    // dedicated high-priority presentation path used by broadcast players.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    for (;;) {
        pthread_mutex_lock(&s->video_lock);
        while (!s->video_head && !s->video_stop)
            pthread_cond_wait(&s->video_cond, &s->video_lock);
        if (s->video_stop && !s->video_head) {
            pthread_mutex_unlock(&s->video_lock);
            break;
        }
        video_chunk *c = s->video_head;
        s->video_head = c->next;
        if (!s->video_head) s->video_tail = NULL;
        s->video_count--;
        pthread_cond_broadcast(&s->video_cond);
        pthread_mutex_unlock(&s->video_lock);

        unsigned generation = atomic_load(&s->video_generation);
        if (c->generation == generation) {
            int waited_for_pause = 0;
            while (atomic_load(&in->paused) && !atomic_load(&in->stop) &&
                   c->generation == atomic_load(&s->video_generation)) {
                waited_for_pause = 1;
                mc_sleep_us(5000);
            }
            if (atomic_load(&in->stop)) {
                av_frame_free(&c->frame); free(c);
                continue;
            }
            // Pausing changes wall time; force the next frame to establish a fresh anchor.
            if (waited_for_pause) s->base_pts_us = AV_NOPTS_VALUE;
            // Never present a backlog as a burst. If decode fell more than 1.5 frame periods
            // behind, discard this stale frame and let the queue catch up to the current clock.
            // This is the same real-time policy used by live production renderers: current motion
            // is preferable to showing old frames rapidly after a temporary decode stall.
            int rate = atomic_load(&in->rate_milli);
            if (rate < 50) rate = 50;
            int64_t period_us = s->nominal_fps_milli > 0
                ? 1000000000LL / s->nominal_fps_milli
                : 16667;
            if (s->base_pts_us != AV_NOPTS_VALUE && c->pos_us != AV_NOPTS_VALUE &&
                c->pos_us >= s->base_pts_us) {
                int64_t target_us = s->base_wall_us +
                    (c->pos_us - s->base_pts_us) * 1000 / rate;
                if (mc_now_us() - target_us > period_us * 3 / 2) {
                    s->last_pts_us = c->pos_us;
                    if (in->cb.on_video_drop) in->cb.on_video_drop(in->cb.user);
                    av_frame_free(&c->frame);
                    free(c);
                    continue;
                }
            }
            pace(in, s, c->pos_us);
            // A seek/restart can happen while pace is sleeping. Never flash a stale pre-seek frame.
            if (c->generation == atomic_load(&s->video_generation) && !atomic_load(&in->stop)) {
                if (c->pos_us != AV_NOPTS_VALUE)
                    atomic_store(&in->position_us, (long long)(c->pos_us - c->loop_off_us));
                deliver_video(in, s, c->frame);
                s->need_frame = 0;
            }
        }
        av_frame_free(&c->frame);
        free(c);
    }
    return NULL;
}

static int decode_packet(mc_input *in, session *s, AVCodecContext *dec, AVPacket *pkt, int video, AVFrame *fr);

static int start_video_thread(mc_input *in, session *s) {
    if (!in->is_file || s->vidx < 0) return 0;
    struct { mc_input *in; session *s; } *ctx = malloc(sizeof(*ctx));
    if (!ctx) return -1;
    ctx->in = in; ctx->s = s;
    s->video_stop = 0;
    if (pthread_create(&s->video_thread, NULL, video_release_thread, ctx) != 0) {
        free(ctx);
        return -1;
    }
    s->video_thread_running = 1;
    return 0;
}

static void stop_video_thread(session *s, int drain) {
    if (!s->video_thread_running) return;
    if (drain) {
        pthread_mutex_lock(&s->video_lock);
        while (s->video_count > 0) pthread_cond_wait(&s->video_cond, &s->video_lock);
        pthread_mutex_unlock(&s->video_lock);
    }
    pthread_mutex_lock(&s->video_lock);
    s->video_stop = 1;
    if (!drain) clear_video_queue_locked(s);
    pthread_cond_broadcast(&s->video_cond);
    pthread_mutex_unlock(&s->video_lock);
    pthread_join(s->video_thread, NULL);
    s->video_thread_running = 0;
}

static void deliver_audio(mc_input *in, session *s, AVFrame *f, int64_t pos_us) {
    if (!in->cb.on_audio) return;
    // Small rate offsets (59.94 ↔ 60 conform, ±1 %) keep audio: the resampler treats the source as
    // slightly slower/faster (0.1 % = 1.7 cents of pitch — inaudible) so audio stays locked to video.
    int arate = in->is_file ? atomic_load(&in->rate_milli) : 1000;
    if (arate < 990 || arate > 1010) arate = 1000;
    if (!s->swr || s->swr_rate != f->sample_rate || s->swr_fmt != f->format || s->swr_rate_milli != arate ||
        av_channel_layout_compare(&s->swr_layout, &f->ch_layout) != 0) {
        swr_free(&s->swr);
        AVChannelLayout out_layout = AV_CHANNEL_LAYOUT_STEREO;
        AVChannelLayout in_layout;
        if (f->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || f->ch_layout.nb_channels <= 0) {
            av_channel_layout_default(&in_layout, f->ch_layout.nb_channels > 0 ? f->ch_layout.nb_channels : 2);
        } else {
            av_channel_layout_copy(&in_layout, &f->ch_layout);
        }
        if (swr_alloc_set_opts2(&s->swr, &out_layout, AV_SAMPLE_FMT_FLT, MC_AUDIO_RATE, &in_layout,
                                (enum AVSampleFormat)f->format, (int)((int64_t)f->sample_rate * arate / 1000), 0, NULL) < 0 ||
            swr_init(s->swr) < 0) {
            swr_free(&s->swr);
            av_channel_layout_uninit(&in_layout);
            return;
        }
        av_channel_layout_uninit(&s->swr_layout);
        av_channel_layout_copy(&s->swr_layout, &f->ch_layout);
        av_channel_layout_uninit(&in_layout);
        s->swr_rate = f->sample_rate;
        s->swr_fmt = f->format;
        s->swr_rate_milli = arate;
    }
    int out_max = swr_get_out_samples(s->swr, f->nb_samples);
    if (out_max <= 0) return;
    if (out_max > s->abuf_frames) {
        free(s->abuf);
        s->abuf = (float *)malloc((size_t)out_max * 2 * sizeof(float));
        s->abuf_frames = s->abuf ? out_max : 0;
        if (!s->abuf) return;
    }
    uint8_t *out[1] = {(uint8_t *)s->abuf};
    int n = swr_convert(s->swr, out, out_max, (const uint8_t **)f->extended_data, f->nb_samples);
    if (n > 0) {
        if (in->is_file && pos_us != AV_NOPTS_VALUE) {
            int64_t end = pos_us + (int64_t)n * arate * 1000 / MC_AUDIO_RATE;   // media µs of n samples
            if (end > s->aend_us) s->aend_us = end;
        }
        if (in->is_file) queue_file_audio(in, s->abuf, n, pos_us);
        else in->cb.on_audio(in->cb.user, s->abuf, n);
    }
}

static int decode_packet(mc_input *in, session *s, AVCodecContext *dec, AVPacket *pkt, int video, AVFrame *fr) {
    int ret = avcodec_send_packet(dec, pkt);
    if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) return 0;  // skip corrupt packet
    for (;;) {
        ret = avcodec_receive_frame(dec, fr);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) break;
        AVRational tb = s->fmt->streams[video ? s->vidx : s->aidx]->time_base;
        int64_t pts = frame_pts_us(fr, tb);
        int64_t pos = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : pts - s->start_us;
        if (pos != AV_NOPTS_VALUE && s->skip_until_us > 0 && pos < s->skip_until_us - 2000) {
            av_frame_unref(fr);  // still before the seek target
            continue;
        }
        if (video && atomic_load(&s->vflush)) {
            av_frame_unref(fr);   // a seek is replacing this stream position
            continue;
        }
        if (in->is_file && pos != AV_NOPTS_VALUE) {
            long long mo = atomic_load(&in->mark_out_us);
            if (mo > 0 && pos >= mo) { av_frame_unref(fr); continue; }   // past Mark Out
        }
        int drives_clock = video || s->vidx < 0;
        int64_t tl = pos == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : pos + s->loop_off_us;   // timeline position
        if (video && in->is_file && tl != AV_NOPTS_VALUE) {
            AVRational vtb = s->fmt->streams[s->vidx]->time_base;
            int64_t d = fr->duration > 0 ? av_rescale_q(fr->duration, vtb, (AVRational){1, 1000000})
                      : (s->nominal_fps_milli > 0 ? 1000000000LL / s->nominal_fps_milli : 16667);
            if (tl + d > s->vend_us) s->vend_us = tl + d;
        }
        // File audio must also be paced by its own PTS. MP4 commonly stores the final audio chunk
        // before the final video packets; delivering it immediately made the audio ring run dry
        // 200–350 ms before picture EOF, heard as a playlist transition dropout.
        if (drives_clock && !(in->is_file && video && s->video_thread_running)) {
            pace(in, s, tl);
            if (in->is_file && drives_clock && pos != AV_NOPTS_VALUE) atomic_store(&in->position_us, (long long)pos);
        }
        if (video) {
            if (in->is_file && s->video_thread_running && atomic_load(&in->paused)) {
                // Keep a still preview while cued, without building a 4K frame queue or starting audio.
                if (s->need_frame) {
                    if (pos != AV_NOPTS_VALUE) atomic_store(&in->position_us, (long long)pos);
                    deliver_video(in, s, fr);
                    s->need_frame = 0;
                }
            } else if (in->is_file && s->video_thread_running) {
                queue_file_video(in, s, fr, tl);
            }
            else {
                deliver_video(in, s, fr);
                s->need_frame = 0;
            }
        } else if ((in->is_file || !atomic_load(&in->paused)) && atomic_load(&in->rate_milli) >= 990 &&
                   atomic_load(&in->rate_milli) <= 1010) {
            // Files: decoded audio is held on the play clock while paused (e.g. the packets read to
            // show the cue frame), so resuming has no audio hole.
            // The audio thread releases it FILE_AUDIO_LEAD_US ahead of the shared media clock.
            deliver_audio(in, s, fr, tl);
        }
        av_frame_unref(fr);
        if (atomic_load(&in->stop)) return -1;
    }
    return 0;
}

static void *video_decode_thread(void *opaque) {
    struct { mc_input *in; session *s; } *ctx = opaque;
    mc_input *in = ctx->in;
    session *s = ctx->s;
    free(ctx);
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
    for (;;) {
        pthread_mutex_lock(&s->vpq_lock);
        for (;;) {
            if (atomic_load(&s->vdec_stop)) break;
            // Paused: decode only the cue/seek still, keep the rest queued for resume.
            int hold = (atomic_load(&in->paused) && !s->need_frame) || atomic_load(&s->vflush);
            if (s->vpq_head && !hold) break;
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += 10 * 1000000;
            if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
            pthread_cond_timedwait(&s->vpq_cond, &s->vpq_lock, &ts);
        }
        pthread_mutex_unlock(&s->vpq_lock);
        if (atomic_load(&s->vdec_stop)) break;
        // Lock order: vdec_lock → vpq_lock (do_seek uses the same order).
        pthread_mutex_lock(&s->vdec_lock);
        if (atomic_load(&s->vflush)) {
            // Darwin mutexes are not fair: yield the decoder to a pending seek instead of
            // re-taking the lock and burning through seconds of stale packets.
            pthread_mutex_unlock(&s->vdec_lock);
            mc_sleep_us(1000);
            continue;
        }
        pthread_mutex_lock(&s->vpq_lock);
        vpkt *p = s->vpq_head;
        if (p) {
            s->vpq_head = p->next;
            if (!s->vpq_head) s->vpq_tail = NULL;
            s->vpq_count--;
            s->vpq_bytes -= p->pkt ? p->pkt->size : 0;
            s->vpq_dur_us -= p->dur_us;
            s->vpq_busy = 1;
            pthread_cond_broadcast(&s->vpq_cond);
        }
        pthread_mutex_unlock(&s->vpq_lock);
        if (p) {
            if (p->pkt) {
                decode_packet(in, s, s->vdec, p->pkt, 1, s->vframe);
            } else {
                decode_packet(in, s, s->vdec, NULL, 1, s->vframe);   // drain at end of file
                avcodec_flush_buffers(s->vdec);
            }
            av_packet_free(&p->pkt);
            free(p);
            pthread_mutex_lock(&s->vpq_lock);
            s->vpq_busy = 0;
            pthread_cond_broadcast(&s->vpq_cond);
            pthread_mutex_unlock(&s->vpq_lock);
        }
        pthread_mutex_unlock(&s->vdec_lock);
    }
    return NULL;
}

static int start_vdec_thread(mc_input *in, session *s) {
    if (!in->is_file || s->vidx < 0 || !s->video_thread_running) return 0;
    struct { mc_input *in; session *s; } *ctx = malloc(sizeof(*ctx));
    if (!ctx) return -1;
    ctx->in = in; ctx->s = s;
    atomic_store(&s->vdec_stop, 0);
    atomic_store(&s->vflush, 0);
    if (pthread_create(&s->vdec_thread, NULL, video_decode_thread, ctx) != 0) { free(ctx); return -1; }
    s->vdec_running = 1;
    return 0;
}

static void stop_vdec_thread(session *s) {
    if (!s->vdec_running) return;
    atomic_store(&s->vdec_stop, 1);
    pthread_mutex_lock(&s->vpq_lock);
    pthread_cond_broadcast(&s->vpq_cond);
    pthread_mutex_unlock(&s->vpq_lock);
    pthread_mutex_lock(&s->video_lock);
    pthread_cond_broadcast(&s->video_cond);
    pthread_mutex_unlock(&s->video_lock);
    pthread_join(s->vdec_thread, NULL);
    s->vdec_running = 0;
    pthread_mutex_lock(&s->vpq_lock);
    vpq_clear_locked(s);
    pthread_mutex_unlock(&s->vpq_lock);
}

static void vpq_timed_wait(session *s, int ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += (long)ms * 1000000;
    if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
    pthread_cond_timedwait(&s->vpq_cond, &s->vpq_lock, &ts);
}

/* Demux thread: hand a video packet (or NULL = drain marker) to the decode thread.
   Takes ownership of pkt's data. Returns -1 when a command (seek/stop/restart) interrupted the wait. */
static int vpq_push(mc_input *in, session *s, AVPacket *pkt) {
    vpkt *p = (vpkt *)calloc(1, sizeof(*p));
    if (!p) return -1;
    if (pkt) {
        p->pkt = av_packet_alloc();
        if (!p->pkt) { free(p); return -1; }
        av_packet_move_ref(p->pkt, pkt);
        AVRational tb = s->fmt->streams[s->vidx]->time_base;
        p->dur_us = p->pkt->duration > 0 ? av_rescale_q(p->pkt->duration, tb, (AVRational){1, 1000000})
                  : (s->nominal_fps_milli > 0 ? 1000000000LL / s->nominal_fps_milli : 16667);
    }
    pthread_mutex_lock(&s->vpq_lock);
    while (s->vpq_count > 0 && !atomic_load(&s->vdec_stop) && !wake_requested(in) &&
           (s->vpq_dur_us >= VPQ_MAX_US || s->vpq_bytes >= VPQ_MAX_BYTES || s->vpq_count >= VPQ_MAX_COUNT))
        vpq_timed_wait(s, 10);
    if (atomic_load(&s->vdec_stop) || wake_requested(in)) {
        pthread_mutex_unlock(&s->vpq_lock);
        av_packet_free(&p->pkt);
        free(p);
        return -1;
    }
    if (s->vpq_tail) s->vpq_tail->next = p; else s->vpq_head = p;
    s->vpq_tail = p;
    s->vpq_count++;
    s->vpq_bytes += p->pkt ? p->pkt->size : 0;
    s->vpq_dur_us += p->dur_us;
    pthread_cond_broadcast(&s->vpq_cond);
    pthread_mutex_unlock(&s->vpq_lock);
    return 0;
}

/* Wait until the decode thread consumed every queued packet. 0 if a command interrupted it. */
static int vpq_wait_drained(mc_input *in, session *s) {
    pthread_mutex_lock(&s->vpq_lock);
    while ((s->vpq_count > 0 || s->vpq_busy) && !atomic_load(&s->vdec_stop) && !wake_requested(in))
        vpq_timed_wait(s, 10);
    int ok = s->vpq_count == 0 && !s->vpq_busy;
    pthread_mutex_unlock(&s->vpq_lock);
    return ok;
}

static void do_seek(mc_input *in, session *s, int64_t target_us) {
    // Stop the decode thread's output first, then take the decoder from it.
    atomic_store(&s->vflush, 1);
    invalidate_media_clock(in);
    clear_audio_queue(in);
    atomic_fetch_add(&s->video_generation, 1);
    clear_video_queue(s);
    if (s->vdec_running) pthread_mutex_lock(&s->vdec_lock);
    pthread_mutex_lock(&s->vpq_lock);
    vpq_clear_locked(s);
    pthread_mutex_unlock(&s->vpq_lock);
    clear_video_queue(s);
    if (target_us < 0) target_us = 0;
    av_seek_frame(s->fmt, -1, target_us + s->start_us, AVSEEK_FLAG_BACKWARD);
    if (s->vdec) avcodec_flush_buffers(s->vdec);
    if (s->adec) avcodec_flush_buffers(s->adec);
    s->base_pts_us = AV_NOPTS_VALUE;
    s->audio_base_pts_us = AV_NOPTS_VALUE;
    s->skip_until_us = target_us;
    s->loop_off_us = 0;          // queues and clock were thrown away: the timeline restarts here
    s->vend_us = s->aend_us = 0;
    s->need_frame = 1;
    atomic_store(&in->position_us, (long long)target_us);
    atomic_store(&in->finished, 0);
    atomic_store(&s->vflush, 0);
    if (s->vdec_running) pthread_mutex_unlock(&s->vdec_lock);
}

static int64_t start_point(mc_input *in) {
    long long m = atomic_load(&in->mark_in_us);
    return m > 0 ? m : 0;
}

static int has_queued_next(mc_input *in) {
    pthread_mutex_lock(&in->next_lock);
    int yes = in->next_url != NULL;
    pthread_mutex_unlock(&in->next_lock);
    return yes;
}

/* Gapless loop wrap at end of file. The decoders are already drained and flushed (EOF path) and the
   video decode thread is idle. Unlike do_seek, the decoded tail stays queued and the media clock keeps
   running: the next pass is decoded while the tail is presented, and its timestamps continue where
   this pass ended, so neither the pacer nor the audio release thread sees a discontinuity. */
static void loop_wrap(mc_input *in, session *s) {
    int64_t sp = start_point(in);
    int64_t end = s->vend_us > s->aend_us ? s->vend_us : s->aend_us;
    if (end <= 0) { do_seek(in, s, sp); return; }   // nothing decoded this pass: plain seek
    // Audio track shorter than the picture: fill the rest with silence so the mixer doesn't run dry.
    int64_t hole = s->aend_us > 0 ? end - s->aend_us : 0;
    int arate = atomic_load(&in->rate_milli);
    if (hole > 1000 && hole < 1000000 && s->aidx >= 0 && in->cb.on_audio && arate >= 990 && arate <= 1010) {
        int frames = (int)(hole * MC_AUDIO_RATE / 1000000);
        float *z = (float *)calloc((size_t)frames * 2, sizeof(float));
        if (z) queue_file_audio(in, z, frames, s->aend_us);
        free(z);
    }
    av_seek_frame(s->fmt, -1, sp + s->start_us, AVSEEK_FLAG_BACKWARD);
    if (s->adec) avcodec_flush_buffers(s->adec);
    s->skip_until_us = sp;
    s->loop_off_us = end - sp;
    s->vend_us = s->aend_us = end;
    atomic_store(&in->finished, 0);
}

/* End of media (or mark out). Returns 1 to keep reading, 0 to leave the session.
   seamless = called at the demuxer's end of file with the decoders drained (gapless loop possible). */
static int handle_end(mc_input *in, session *s, int seamless) {
    // A pre-opened next session (also used for a one-item loop) is warmer and preserves the queued
    // tail than seeking the active VideoToolbox decoder after EOF.
    if (has_queued_next(in)) return 0;
    if (atomic_load(&in->loop)) {
        if (seamless) loop_wrap(in, s);
        else do_seek(in, s, start_point(in));
        return 1;
    }
    atomic_store(&in->finished, 1);
    status(in, MC_STATE_STOPPED, "재생 완료");
    while (!wake_requested(in)) mc_sleep_us(20000);
    return !atomic_load(&in->stop);
}

static void *input_thread(void *arg) {
    mc_input *in = (mc_input *)arg;
    int timeout_ms = in->cfg.timeout_ms > 0 ? in->cfg.timeout_ms : 5000;
    int attempt = 0;
    while (!atomic_load(&in->stop)) {
        session s;
        atomic_store(&in->video_decode_mode, 0);
        status(in, MC_STATE_CONNECTING, in->is_file ? "여는 중" : "연결 대기 중");
        session *ready = NULL;
        pthread_mutex_lock(&in->next_lock);
        ready = in->preloaded;
        in->preloaded = NULL;
        pthread_mutex_unlock(&in->next_lock);
        int ret;
        if (ready) {
            s = *ready;
            // pthread synchronization objects cannot be copied. The preloader never starts the
            // presentation thread, so replace the copied pristine objects with local ones.
            session_sync_destroy(ready);
            session_sync_init(&s);
            s.video_head = s.video_tail = NULL;
            s.video_count = s.video_thread_running = s.video_stop = 0;
            atomic_init(&s.video_generation, 1);
            s.vpq_head = s.vpq_tail = NULL;
            s.vpq_count = s.vpq_busy = s.vdec_running = 0;
            s.vpq_bytes = s.vpq_dur_us = 0;
            atomic_init(&s.vdec_stop, 0);
            atomic_init(&s.vflush, 0);
            free(ready);
            atomic_store(&in->duration_us, s.fmt && s.fmt->duration > 0 ? (long long)s.fmt->duration : 0);
            atomic_store(&in->nominal_fps_milli, s.nominal_fps_milli);
            if (in->cb.on_audio_presence)
                in->cb.on_audio_presence(in->cb.user, s.aidx >= 0 ? 1 : 0);
            ret = 0;
        } else {
            ret = session_open(in, &s, in->url, 1);
        }
        if (ret < 0) {
            char err[128];
            av_strerror(ret, err, sizeof(err));
            session_end(in, &s);
            if (atomic_load(&in->stop)) break;
            status(in, MC_STATE_ERROR, "열기 실패: %s", err);
            if (in->is_file) break;
            attempt++;
            int64_t wait = attempt < 5 ? 1000000 : 3000000;
            int64_t until = mc_now_us() + wait;
            while (!atomic_load(&in->stop) && mc_now_us() < until) mc_sleep_us(50000);
            continue;
        }
        attempt = 0;
        status(in, MC_STATE_RUNNING, "%s%s%s",
               s.vdec ? s.vdec->codec->name : "",
               (s.vdec && s.adec) ? " + " : "",
               s.adec ? s.adec->codec->name : "");
        if (start_video_thread(in, &s) != 0 || start_vdec_thread(in, &s) != 0) {
            status(in, MC_STATE_ERROR, "비디오 출력 스케줄러 시작 실패");
            stop_vdec_thread(&s);
            stop_video_thread(&s, 0);
            session_end(in, &s);
            break;
        }
        if (in->is_file && atomic_load(&in->mark_in_us) > 0) do_seek(in, &s, start_point(in));
        int reconnect = 0;
        while (!atomic_load(&in->stop)) {
            if (in->is_file) {
                long long req = atomic_exchange(&in->seek_req_us, -1);
                if (atomic_exchange(&in->restart, 0)) {
                    do_seek(in, &s, start_point(in));
                    if (!atomic_load(&in->finished)) status(in, MC_STATE_RUNNING, "재생");
                } else if (req >= 0) {
                    do_seek(in, &s, req);
                }
                if (atomic_load(&in->paused) && !(s.need_frame && s.vidx >= 0)) {
                    // Hold the current frame. Re-anchor both media clocks on resume:
                    // otherwise queued file audio has deadlines from before the pause
                    // and is released in a burst when playback starts again.
                    // Video re-anchors on resume. File audio runs on the play clock, which stood
                    // still during the pause, so its anchor and queued deadlines remain valid.
                    mc_sleep_us(20000);
                    s.base_pts_us = AV_NOPTS_VALUE;
                    continue;
                }
                long long mo = atomic_load(&in->mark_out_us);
                if (mo > 0 && atomic_load(&in->position_us) >= mo) {
                    if (!handle_end(in, &s, 0)) break;
                    continue;
                }
            }
            in->io_deadline_us = in->is_file ? 0 : mc_now_us() + (int64_t)timeout_ms * 1000;
            if (s.pre_index < s.pre_count) {
                av_packet_move_ref(s.pkt, s.pre_pkts[s.pre_index]);
                av_packet_free(&s.pre_pkts[s.pre_index]);
                s.pre_index++;
                ret = 0;
            } else {
                ret = av_read_frame(s.fmt, s.pkt);
            }
            if (ret >= 0 && in->is_file) {
                // With seconds of read-ahead, Mark Out is reached by the demuxer long before it is
                // on screen: treat it like end of file (DTS ≤ PTS, so every earlier frame is read).
                long long mo2 = atomic_load(&in->mark_out_us);
                int clock_idx = s.vidx >= 0 ? s.vidx : s.aidx;
                if (mo2 > 0 && s.pkt->stream_index == clock_idx) {
                    int64_t ts = s.pkt->dts != AV_NOPTS_VALUE ? s.pkt->dts : s.pkt->pts;
                    if (ts != AV_NOPTS_VALUE &&
                        av_rescale_q(ts, s.fmt->streams[clock_idx]->time_base, (AVRational){1, 1000000}) - s.start_us >= mo2) {
                        av_packet_unref(s.pkt);
                        ret = AVERROR_EOF;
                    }
                }
            }
            if (ret < 0) {
                if (ret == AVERROR_EOF && in->is_file) {
                    if (s.vdec_running) {
                        // Let the decode thread present the tail, then reuse the normal end logic.
                        if (vpq_push(in, &s, NULL) < 0 || !vpq_wait_drained(in, &s)) continue;
                    } else if (s.vdec) {
                        decode_packet(in, &s, s.vdec, NULL, 1, s.frame);
                        avcodec_flush_buffers(s.vdec);
                    }
                    if (s.adec) decode_packet(in, &s, s.adec, NULL, 0, s.frame);
                    if (s.adec) avcodec_flush_buffers(s.adec);
                    // Looping keeps the decoded tail queued (loop_wrap) — no drain-and-wait here.
                    if (!handle_end(in, &s, 1)) break;
                    continue;
                }
                if (atomic_load(&in->stop)) break;
                char err[128];
                av_strerror(ret, err, sizeof(err));
                status(in, MC_STATE_ERROR, "신호 끊김: %s — 재연결", err);
                reconnect = 1;
                break;
            }
            if (s.pkt->stream_index == s.vidx) {
                if (s.vdec_running) vpq_push(in, &s, s.pkt);   // never blocks on decoded frames
                else decode_packet(in, &s, s.vdec, s.pkt, 1, s.frame);
            } else if (s.pkt->stream_index == s.aidx) {
                decode_packet(in, &s, s.adec, s.pkt, 0, s.frame);
            }
            av_packet_unref(s.pkt);
        }
        // At a natural file boundary present every queued picture before closing its decoder.
        // Commands and shutdown discard stale queued frames instead.
        int natural_end = !atomic_load(&in->stop) && !atomic_load(&in->restart) &&
                          atomic_load(&in->seek_req_us) < 0;
        stop_vdec_thread(&s);
        stop_video_thread(&s, natural_end);
        if (natural_end && in->is_file) {
            // Release the tail of this file's audio on its own clock before the next file
            // (playlist) restarts positions at zero.
            int64_t until = mc_now_us() + 1000000;
            for (;;) {
                pthread_mutex_lock(&in->audio_lock);
                int empty = in->audio_head == NULL;
                pthread_mutex_unlock(&in->audio_lock);
                if (empty || wake_requested(in) || mc_now_us() > until) break;
                mc_sleep_us(2000);
            }
        }
        if (in->is_file) { clear_audio_queue(in); invalidate_media_clock(in); }
        session_end(in, &s);
        char *next = NULL;
        pthread_mutex_lock(&in->next_lock);
        next = in->next_url;
        in->next_url = NULL;
        pthread_mutex_unlock(&in->next_lock);
        if (next && !atomic_load(&in->stop)) {
            free(in->url);
            in->url = next;
            in->cfg.url = in->url;
            atomic_store(&in->position_us, 0);
            atomic_store(&in->duration_us, 0);
            atomic_store(&in->finished, 0);
            continue;
        }
        free(next);
        if (!reconnect && in->is_file) break;
        if (!atomic_load(&in->stop)) mc_sleep_us(500000);
    }
    status(in, MC_STATE_STOPPED, "중지됨");
    return NULL;
}

mc_input *mc_input_open(const mc_input_config *cfg, mc_callbacks cb) {
    if (!cfg || !cfg->url) return NULL;
    mc_input *in = (mc_input *)calloc(1, sizeof(mc_input));
    if (in) {
        pthread_mutex_init(&in->srt_lock, NULL); pthread_mutex_init(&in->next_lock, NULL);
        pthread_mutex_init(&in->audio_lock, NULL); pthread_cond_init(&in->audio_cond, NULL);
    }
    if (!in) return NULL;
    in->cfg = *cfg;
    in->url = strdup(cfg->url);
    in->cfg.url = in->url;
    in->cb = cb;
    in->is_file = detect_is_file(cfg->url);
    atomic_init(&in->stop, 0);
    atomic_init(&in->restart, 0);
    atomic_init(&in->paused, 0);
    atomic_init(&in->loop, cfg->loop ? 1 : 0);
    atomic_init(&in->finished, 0);
    atomic_init(&in->rate_milli, 1000);
    atomic_init(&in->seek_req_us, -1);
    atomic_init(&in->mark_in_us, -1);
    atomic_init(&in->mark_out_us, -1);
    atomic_init(&in->position_us, 0);
    atomic_init(&in->duration_us, 0);
    atomic_init(&in->nominal_fps_milli, 0);
    atomic_init(&in->video_decode_mode, 0);
    avformat_network_init();
    if (pthread_create(&in->audio_thread, NULL, audio_release_thread, in) != 0) {
        pthread_mutex_destroy(&in->audio_lock); pthread_cond_destroy(&in->audio_cond);
        pthread_mutex_destroy(&in->srt_lock); pthread_mutex_destroy(&in->next_lock);
        free(in->url); free(in); return NULL;
    }
    if (pthread_create(&in->thread, NULL, input_thread, in) != 0) {
        atomic_store(&in->stop, 1); pthread_cond_signal(&in->audio_cond); pthread_join(in->audio_thread, NULL);
        pthread_mutex_destroy(&in->audio_lock); pthread_cond_destroy(&in->audio_cond);
        pthread_mutex_destroy(&in->srt_lock); pthread_mutex_destroy(&in->next_lock);
        free(in->url);
        free(in);
        return NULL;
    }
    return in;
}

void mc_input_set_paused(mc_input *in, int paused) {
    if (!in) return;
    pthread_mutex_lock(&in->audio_lock);
    int64_t now = mc_now_us();
    if (paused && !in->paused_since_us) in->paused_since_us = now;
    else if (!paused && in->paused_since_us) {
        in->pause_offset_us += now - in->paused_since_us;
        in->paused_since_us = 0;
    }
    atomic_store(&in->paused, paused ? 1 : 0);
    pthread_cond_signal(&in->audio_cond);
    pthread_mutex_unlock(&in->audio_lock);
}

void mc_input_set_loop(mc_input *in, int loop) {
    if (in) atomic_store(&in->loop, loop ? 1 : 0);
}

void mc_input_restart(mc_input *in) {
    if (in) atomic_store(&in->restart, 1);
}

void mc_input_seek(mc_input *in, int64_t position_us) {
    if (in) atomic_store(&in->seek_req_us, (long long)(position_us < 0 ? 0 : position_us));
}

void mc_input_set_marks(mc_input *in, int64_t in_us, int64_t out_us) {
    if (!in) return;
    atomic_store(&in->mark_in_us, (long long)in_us);
    atomic_store(&in->mark_out_us, (long long)out_us);
}

void mc_input_set_rate(mc_input *in, double rate) {
    if (!in) return;
    if (rate < 0.05) rate = 0.05;
    if (rate > 4) rate = 4;
    atomic_store(&in->rate_milli, (int)(rate * 1000 + 0.5));
}

void mc_input_queue_next(mc_input *in, const char *url) {
    if (!in || !url || !url[0]) return;
    char *copy = strdup(url);
    if (!copy) return;
    pthread_mutex_lock(&in->next_lock);
    free(in->next_url);
    in->next_url = copy;
    if (!in->preload_running) {
        preload_job *job = (preload_job *)calloc(1, sizeof(*job));
        if (job) {
            job->in = in;
            job->url = strdup(url);
            if (job->url) {
                in->preload_running = 1;
                if (pthread_create(&in->preload_thread, NULL, preload_next, job) == 0) {
                    pthread_detach(in->preload_thread);
                } else {
                    in->preload_running = 0;
                    free(job->url); free(job);
                }
            } else free(job);
        }
    }
    pthread_mutex_unlock(&in->next_lock);
}

double mc_input_nominal_fps(mc_input *in) {
    return in ? atomic_load(&in->nominal_fps_milli) / 1000.0 : 0;
}

void mc_input_get_position(mc_input *in, int64_t *position_us, int64_t *duration_us, int *finished) {
    if (!in) return;
    if (position_us) *position_us = atomic_load(&in->position_us);
    if (duration_us) *duration_us = atomic_load(&in->duration_us);
    if (finished) *finished = atomic_load(&in->finished);
}

void mc_input_close(mc_input *in) {
    if (!in) return;
    atomic_store(&in->stop, 1);
    pthread_mutex_lock(&in->audio_lock); pthread_cond_signal(&in->audio_cond); pthread_mutex_unlock(&in->audio_lock);
    pthread_join(in->thread, NULL);
    pthread_join(in->audio_thread, NULL);
    clear_audio_queue(in);
    for (;;) {
        pthread_mutex_lock(&in->next_lock);
        int running = in->preload_running;
        pthread_mutex_unlock(&in->next_lock);
        if (!running) break;
        mc_sleep_us(1000);
    }
    pthread_mutex_lock(&in->next_lock);
    free(in->next_url);
    in->next_url = NULL;
    session *ready = in->preloaded;
    in->preloaded = NULL;
    pthread_mutex_unlock(&in->next_lock);
    if (ready) { session_end(in, ready); free(ready); }
    pthread_mutex_destroy(&in->srt_lock);
    pthread_mutex_destroy(&in->next_lock);
    pthread_mutex_destroy(&in->audio_lock);
    pthread_cond_destroy(&in->audio_cond);
    free(in->url);
    free(in);
}

int mc_input_srt_stats(mc_input *in, mc_srt_stats *out) {
    memset(out, 0, sizeof(*out));
    if (!in) return 0;
    pthread_mutex_lock(&in->srt_lock);
    int ok = in->srt_live != NULL;
    if (ok) mc_srt_get_stats(in->srt_live, out);
    pthread_mutex_unlock(&in->srt_lock);
    return ok;
}

int mc_input_video_decode_mode(mc_input *in) {
    return in ? atomic_load(&in->video_decode_mode) : 0;
}

int mc_input_get_audio_queue_stats(mc_input *in, mc_input_audio_queue_stats *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!in || !in->is_file) return 0;
    pthread_mutex_lock(&in->audio_lock);
    out->queued_frames = in->audio_queue_frames;
    out->peak_queued_frames = in->audio_queue_peak_frames;
    out->late_chunks = in->audio_late_chunks;
    out->max_lateness_us = in->audio_max_lateness_us;
    pthread_mutex_unlock(&in->audio_lock);
    return 1;
}

void mc_input_reset_audio_queue_stats(mc_input *in) {
    if (!in) return;
    pthread_mutex_lock(&in->audio_lock);
    in->audio_queue_peak_frames = in->audio_queue_frames;
    in->audio_late_chunks = 0;
    in->audio_max_lateness_us = 0;
    pthread_mutex_unlock(&in->audio_lock);
}

const char *mc_core_version(void) {
    static char buf[128];
    // runtime version of the FFmpeg that is actually loaded, and its license (LGPL build has no GPL parts)
    snprintf(buf, sizeof(buf), "FFmpeg %s · %s", av_version_info(), avcodec_license());
    return buf;
}
