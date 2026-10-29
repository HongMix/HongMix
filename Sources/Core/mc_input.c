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
    int64_t io_deadline_us;   // 0 = none
    int is_file;
    pthread_mutex_t srt_lock;     // guards srt_live (stats are read from the UI)
    mc_srt *srt_live;
};

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

typedef struct {
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
} session;

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
    free(s->bgra);
    free(s->abuf);
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

static int session_open(mc_input *in, session *s) {
    memset(s, 0, sizeof(*s));
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
    char *open_url = strdup(in->url);
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
            status(in, MC_STATE_CONNECTING, "SRT 접속 대기 중…");
        mc_srt *srt = mc_srt_open(open_url, 0, interrupt_cb, in, err, sizeof(err));
        if (!srt) {
            status(in, MC_STATE_ERROR, "%s", err);
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
        status(in, MC_STATE_CONNECTING, "SRT 연결됨 — 스트림 분석 중");
    }
    int ret = avformat_open_input(&s->fmt, forced ? NULL : (open_url ? open_url : in->url), forced, &opts);
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
    if (s->vidx < 0 && s->aidx < 0) return AVERROR_STREAM_NOT_FOUND;
    for (unsigned i = 0; i < s->fmt->nb_streams; i++) {
        if ((int)i != s->vidx && (int)i != s->aidx) s->fmt->streams[i]->discard = AVDISCARD_ALL;
    }
    s->frame = av_frame_alloc();
    s->swframe = av_frame_alloc();
    s->pkt = av_packet_alloc();
    s->base_wall_us = 0;
    s->base_pts_us = AV_NOPTS_VALUE;
    s->start_us = s->fmt->start_time != AV_NOPTS_VALUE ? s->fmt->start_time : 0;
    s->skip_until_us = 0;
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
        atomic_store(&in->nominal_fps_milli, (f >= 1 && f <= 240) ? (int)(f * 1000 + 0.5) : 0);
    }
    atomic_store(&in->duration_us, (in->is_file && s->fmt->duration > 0) ? (long long)s->fmt->duration : 0);
    return 0;
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
        // zero-copy: hand the decoder's IOSurface straight to the app (GPU converts it)
        int64_t pts = frame_pts_us(f, s->fmt->streams[s->vidx]->time_base);
        in->cb.on_pixelbuffer(in->cb.user, (void *)f->data[3], pts);
        return;
    }
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

static void deliver_audio(mc_input *in, session *s, AVFrame *f) {
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
    if (n > 0) in->cb.on_audio(in->cb.user, s->abuf, n);
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
        if (drives_clock) {
            pace(in, s, pos);
            if (in->is_file && pos != AV_NOPTS_VALUE) atomic_store(&in->position_us, (long long)pos);
        }
        if (video) {
            deliver_video(in, s, s->frame);
            s->need_frame = 0;
        } else if (atomic_load(&in->rate_milli) == 1000) deliver_audio(in, s, s->frame);  // mute when not 1x
        av_frame_unref(s->frame);
        if (atomic_load(&in->stop)) return -1;
    }
    return 0;
}

static void do_seek(mc_input *in, session *s, int64_t target_us) {
    if (target_us < 0) target_us = 0;
    av_seek_frame(s->fmt, -1, target_us + s->start_us, AVSEEK_FLAG_BACKWARD);
    if (s->vdec) avcodec_flush_buffers(s->vdec);
    if (s->adec) avcodec_flush_buffers(s->adec);
    s->base_pts_us = AV_NOPTS_VALUE;
    s->skip_until_us = target_us;
    s->need_frame = 1;
    atomic_store(&in->position_us, (long long)target_us);
    atomic_store(&in->finished, 0);
}

static int64_t start_point(mc_input *in) {
    long long m = atomic_load(&in->mark_in_us);
    return m > 0 ? m : 0;
}

/* End of media (or mark out). Returns 1 to keep reading, 0 to leave the session. */
static int handle_end(mc_input *in, session *s) {
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
        status(in, MC_STATE_CONNECTING, in->is_file ? "여는 중" : "연결 대기 중");
        int ret = session_open(in, &s);
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
                    // hold the current frame; re-anchor pacing when playback resumes
                    mc_sleep_us(20000);
                    s.base_pts_us = AV_NOPTS_VALUE;
                    continue;
                }
                long long mo = atomic_load(&in->mark_out_us);
                if (mo > 0 && atomic_load(&in->position_us) >= mo) {
                    if (!handle_end(in, &s)) break;
                    continue;
                }
            }
            in->io_deadline_us = in->is_file ? 0 : mc_now_us() + (int64_t)timeout_ms * 1000;
            ret = av_read_frame(s.fmt, s.pkt);
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
        session_end(in, &s);
        if (!reconnect && in->is_file) break;
        if (!atomic_load(&in->stop)) mc_sleep_us(500000);
    }
    status(in, MC_STATE_STOPPED, "중지됨");
    return NULL;
}

mc_input *mc_input_open(const mc_input_config *cfg, mc_callbacks cb) {
    if (!cfg || !cfg->url) return NULL;
    mc_input *in = (mc_input *)calloc(1, sizeof(mc_input));
    if (in) pthread_mutex_init(&in->srt_lock, NULL);
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
    avformat_network_init();
    if (pthread_create(&in->thread, NULL, input_thread, in) != 0) {
        free(in->url);
        free(in);
        return NULL;
    }
    return in;
}

void mc_input_set_paused(mc_input *in, int paused) {
    if (in) atomic_store(&in->paused, paused ? 1 : 0);
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
    pthread_join(in->thread, NULL);
    pthread_mutex_destroy(&in->srt_lock);
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

const char *mc_core_version(void) {
    static char buf[128];
    // runtime version of the FFmpeg that is actually loaded, and its license (LGPL build has no GPL parts)
    snprintf(buf, sizeof(buf), "FFmpeg %s · %s", av_version_info(), avcodec_license());
    return buf;
}
