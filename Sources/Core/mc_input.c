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

typedef struct session session;
#define FILE_AUDIO_LEAD_US 100000
typedef struct audio_chunk {
    float *samples;
    int frames;
    int64_t target_us;
    struct audio_chunk *next;
} audio_chunk;
typedef struct video_chunk {
    AVFrame *frame;
    int64_t pos_us;
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
};

static void clear_audio_queue(mc_input *in) {
    pthread_mutex_lock(&in->audio_lock);
    audio_chunk *p = in->audio_head;
    in->audio_head = in->audio_tail = NULL;
    pthread_mutex_unlock(&in->audio_lock);
    while (p) { audio_chunk *n = p->next; free(p->samples); free(p); p = n; }
}

static void queue_file_audio(mc_input *in, const float *samples, int frames, int64_t target_us) {
    if (frames <= 0 || atomic_load(&in->stop) || atomic_load(&in->paused)) return;
    audio_chunk *c = (audio_chunk *)calloc(1, sizeof(*c));
    if (!c) return;
    c->samples = (float *)malloc((size_t)frames * 2 * sizeof(float));
    if (!c->samples) { free(c); return; }
    memcpy(c->samples, samples, (size_t)frames * 2 * sizeof(float));
    c->frames = frames; c->target_us = target_us;
    pthread_mutex_lock(&in->audio_lock);
    if (in->audio_tail) in->audio_tail->next = c; else in->audio_head = c;
    in->audio_tail = c;
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
        int64_t wait = c ? c->target_us - mc_now_us() : 0;
        if (wait > 0) { pthread_mutex_unlock(&in->audio_lock); mc_sleep_us(wait > 10000 ? 10000 : wait); continue; }
        in->audio_head = c->next;
        if (!in->audio_head) in->audio_tail = NULL;
        pthread_mutex_unlock(&in->audio_lock);
        if (!atomic_load(&in->stop) && !atomic_load(&in->paused) && in->cb.on_audio)
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
    SwrContext *swr;
    int swr_rate, swr_fmt;
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
    int cur_rate_milli;
    int64_t slack_min_us;        // live pacing: smallest "early" margin seen in the current window
    int64_t slack_t0_us;
    int64_t drain_us;            // live pacing: latency still to remove, spread over many frames
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
};

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
    if (s->swr) swr_free(&s->swr);
    av_channel_layout_uninit(&s->swr_layout);
    av_frame_free(&s->frame);
    av_frame_free(&s->swframe);
    av_packet_free(&s->pkt);
    for (int i = 0; i < s->pre_count; i++) av_packet_free(&s->pre_pkts[i]);
    free(s->pre_pkts);
    free(s->bgra);
    free(s->abuf);
    clear_video_queue(s);
    pthread_mutex_destroy(&s->video_lock);
    pthread_cond_destroy(&s->video_cond);
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
    pthread_mutex_init(&s->video_lock, NULL);
    pthread_cond_init(&s->video_cond, NULL);
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
        } else if (now > target) {
            // frame arrived late: show it now and give the buffer that much more room
            s->base_wall_us += now - target;
            target = now;
            s->drain_us = 0;       // we're short of buffer, not long — stop draining
        }
        // Gradual drain: play slightly fast (4 %, or 8 % while more than 200 ms is pending) until
        // caught up. Every frame still gets its own slot — even motion, no multi-frame bursts.
        if (s->drain_us > 0) {
            int64_t step = s->drain_us > 200000 ? fdt / 12 : fdt / 25;
            if (step > s->drain_us) step = s->drain_us;
            s->base_wall_us -= step;
            target -= step;
            s->drain_us -= step;
        }
        // Every second: if every frame in the window was early by more than the jitter margin (or
        // libsrt is holding backlog beyond its latency), schedule a drain of the excess.
        int64_t slack = target - now;
        if (s->slack_t0_us == 0) { s->slack_t0_us = now; s->slack_min_us = slack; }
        if (slack < s->slack_min_us) s->slack_min_us = slack;
        if (now - s->slack_t0_us > 1000000) {
            if (s->drain_us == 0) {
                int backlog = s->srt ? mc_srt_backlog_ms(s->srt) : 0;
                int64_t want = 0;
                // libsrt already de-jitters (TSBPD); our own hold and the demuxer also show up in its
                // buffer (~60–90 ms), so drain only a clear excess, with hysteresis. A late frame cancels
                // the drain, so it can never fight the jitter target.
                if (backlog > 250) want = (int64_t)(backlog - 100) * 1000;   // hysteresis: 250 → 100
                else if (s->slack_min_us > LIVE_JITTER_US / 2) want = s->slack_min_us - LIVE_JITTER_US / 4;
                if (want > 600000) want = 600000;
                s->drain_us = want;
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
    c->generation = atomic_load(&s->video_generation);
    pthread_mutex_lock(&s->video_lock);
    while (s->video_count >= FILE_VIDEO_QUEUE_MAX && !s->video_stop && !wake_requested(in)) {
        // Timed polling keeps seek/restart responsive even when the queue is full and no consumer
        // signal is generated for the command itself.
        pthread_mutex_unlock(&s->video_lock);
        mc_sleep_us(2000);
        pthread_mutex_lock(&s->video_lock);
    }
    if (s->video_stop || wake_requested(in)) {
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
                    atomic_store(&in->position_us, (long long)c->pos_us);
                deliver_video(in, s, c->frame);
                s->need_frame = 0;
            }
        }
        av_frame_free(&c->frame);
        free(c);
    }
    return NULL;
}

static int decode_packet(mc_input *in, session *s, AVCodecContext *dec, AVPacket *pkt, int video);

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

static void deliver_audio(mc_input *in, session *s, AVFrame *f, int64_t target_us) {
    if (!in->cb.on_audio) return;
    if (!s->swr || s->swr_rate != f->sample_rate || s->swr_fmt != f->format ||
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
                                (enum AVSampleFormat)f->format, f->sample_rate, 0, NULL) < 0 ||
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
        if (in->is_file) queue_file_audio(in, s->abuf, n, target_us);
        else in->cb.on_audio(in->cb.user, s->abuf, n);
    }
}

static int decode_packet(mc_input *in, session *s, AVCodecContext *dec, AVPacket *pkt, int video) {
    int ret = avcodec_send_packet(dec, pkt);
    if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) return 0;  // skip corrupt packet
    for (;;) {
        ret = avcodec_receive_frame(dec, s->frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) break;
        AVRational tb = s->fmt->streams[video ? s->vidx : s->aidx]->time_base;
        int64_t pts = frame_pts_us(s->frame, tb);
        int64_t pos = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : pts - s->start_us;
        if (pos != AV_NOPTS_VALUE && s->skip_until_us > 0 && pos < s->skip_until_us - 2000) {
            av_frame_unref(s->frame);  // still before the seek target
            continue;
        }
        int drives_clock = video || s->vidx < 0;
        // File audio must also be paced by its own PTS. MP4 commonly stores the final audio chunk
        // before the final video packets; delivering it immediately made the audio ring run dry
        // 200–350 ms before picture EOF, heard as a playlist transition dropout.
        if (drives_clock && !(in->is_file && video && s->video_thread_running)) {
            pace(in, s, pos);
            if (in->is_file && drives_clock && pos != AV_NOPTS_VALUE) atomic_store(&in->position_us, (long long)pos);
        }
        if (video) {
            if (in->is_file && s->video_thread_running && atomic_load(&in->paused)) {
                // Keep a still preview while cued, without building a 4K frame queue or starting audio.
                if (s->need_frame) {
                    if (pos != AV_NOPTS_VALUE) atomic_store(&in->position_us, (long long)pos);
                    deliver_video(in, s, s->frame);
                    s->need_frame = 0;
                }
            } else if (in->is_file && s->video_thread_running) {
                queue_file_video(in, s, s->frame, pos);
            }
            else {
                deliver_video(in, s, s->frame);
                s->need_frame = 0;
            }
        } else if (!atomic_load(&in->paused) && atomic_load(&in->rate_milli) == 1000) {
            int64_t target = mc_now_us();
            if (in->is_file && pos != AV_NOPTS_VALUE) {
                int rate = atomic_load(&in->rate_milli); if (rate < 50) rate = 50;
                if (s->audio_base_pts_us == AV_NOPTS_VALUE || s->audio_cur_rate_milli != rate) {
                    s->audio_base_pts_us = pos;
                    s->audio_base_wall_us = target;
                    s->audio_cur_rate_milli = rate;
                }
                target = s->audio_base_wall_us + (pos - s->audio_base_pts_us) * 1000 / rate;
            }
            // Feed a short lead so the mixer can absorb ordinary callback jitter without
            // allowing several hundred milliseconds of file audio to accumulate ahead of video.
            if (in->is_file) target -= FILE_AUDIO_LEAD_US;
            deliver_audio(in, s, s->frame, target);
        }
        av_frame_unref(s->frame);
        if (atomic_load(&in->stop)) return -1;
    }
    return 0;
}

static void do_seek(mc_input *in, session *s, int64_t target_us) {
    clear_audio_queue(in);
    atomic_fetch_add(&s->video_generation, 1);
    clear_video_queue(s);
    if (target_us < 0) target_us = 0;
    av_seek_frame(s->fmt, -1, target_us + s->start_us, AVSEEK_FLAG_BACKWARD);
    if (s->vdec) avcodec_flush_buffers(s->vdec);
    if (s->adec) avcodec_flush_buffers(s->adec);
    s->base_pts_us = AV_NOPTS_VALUE;
    s->audio_base_pts_us = AV_NOPTS_VALUE;
    s->skip_until_us = target_us;
    s->need_frame = 1;
    atomic_store(&in->position_us, (long long)target_us);
    atomic_store(&in->finished, 0);
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

/* End of media (or mark out). Returns 1 to keep reading, 0 to leave the session. */
static int handle_end(mc_input *in, session *s) {
    // A pre-opened next session (also used for a one-item loop) is warmer and preserves the queued
    // tail than seeking the active VideoToolbox decoder after EOF.
    if (has_queued_next(in)) return 0;
    if (atomic_load(&in->loop)) {
        do_seek(in, s, start_point(in));
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
            pthread_mutex_destroy(&ready->video_lock);
            pthread_cond_destroy(&ready->video_cond);
            pthread_mutex_init(&s.video_lock, NULL);
            pthread_cond_init(&s.video_cond, NULL);
            s.video_head = s.video_tail = NULL;
            s.video_count = s.video_thread_running = s.video_stop = 0;
            atomic_init(&s.video_generation, 1);
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
        if (start_video_thread(in, &s) != 0) {
            status(in, MC_STATE_ERROR, "비디오 출력 스케줄러 시작 실패");
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
                    mc_sleep_us(20000);
                    s.base_pts_us = AV_NOPTS_VALUE;
                    s.audio_base_pts_us = AV_NOPTS_VALUE;
                    continue;
                }
                long long mo = atomic_load(&in->mark_out_us);
                if (mo > 0 && atomic_load(&in->position_us) >= mo) {
                    if (!handle_end(in, &s)) break;
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
            if (ret < 0) {
                if (ret == AVERROR_EOF && in->is_file) {
                    if (s.vdec) decode_packet(in, &s, s.vdec, NULL, 1);
                    if (s.adec) decode_packet(in, &s, s.adec, NULL, 0);
                    if (s.vdec) avcodec_flush_buffers(s.vdec);
                    if (s.adec) avcodec_flush_buffers(s.adec);
                    if (!handle_end(in, &s)) break;
                    continue;
                }
                if (atomic_load(&in->stop)) break;
                char err[128];
                av_strerror(ret, err, sizeof(err));
                status(in, MC_STATE_ERROR, "신호 끊김: %s — 재연결", err);
                reconnect = 1;
                break;
            }
            if (s.pkt->stream_index == s.vidx) decode_packet(in, &s, s.vdec, s.pkt, 1);
            else if (s.pkt->stream_index == s.aidx) decode_packet(in, &s, s.adec, s.pkt, 0);
            av_packet_unref(s.pkt);
        }
        // At a natural file boundary present every queued picture before closing its decoder.
        // Commands and shutdown discard stale queued frames instead.
        int natural_end = !atomic_load(&in->stop) && !atomic_load(&in->restart) &&
                          atomic_load(&in->seek_req_us) < 0;
        stop_video_thread(&s, natural_end);
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
    atomic_store(&in->paused, paused ? 1 : 0);
    if (paused && in->is_file) clear_audio_queue(in);
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

const char *mc_core_version(void) {
    static char buf[128];
    // runtime version of the FFmpeg that is actually loaded, and its license (LGPL build has no GPL parts)
    snprintf(buf, sizeof(buf), "FFmpeg %s · %s", av_version_info(), avcodec_license());
    return buf;
}
