// FFmpeg-based output: RTMP/RTMPS (FLV), SRT/UDP (MPEG-TS) streaming and file recording.
// Video encoders prefer VideoToolbox (h264/hevc/prores) and fall back to software.
#include "mc_core.h"
#include "mc_util.h"
#define MC_SRT_INTERNAL 1
#include "mc_srt.h"

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdatomic.h>
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#endif

#define VQ_SLOTS 8

typedef struct {
    uint8_t *data;   // BGRA copy (mc_output_push_video), allocated on first use
    void *pb;        // retained CVPixelBufferRef (mc_output_push_pixelbuffer)
    int64_t tick;
} vslot;

static void pb_release(void *pb) {
#ifdef __APPLE__
    if (pb) CFRelease((CFTypeRef)pb);
#else
    (void)pb;
#endif
}

struct mc_output {
    mc_output_config cfg;
    char *url, *format, *vcodec;
    mc_status_cb status_cb;
    void *user;
    int is_network;

    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    atomic_int stop;
    atomic_int abort_io;

    // queues (lock)
    vslot vq[VQ_SLOTS];
    int vq_head, vq_count;
    mc_audio_fifo afifo;
    mc_audio_fifo xfifo[MC_MAX_XTRACKS];   // multitrack: written/read in lockstep with afifo
    int nx;                                // extra tracks in use
    int need_sync;       // next pushed video frame re-anchors timestamps
    int accepting;       // accept frames/audio
    int64_t base_tick;

    // stats (lock)
    mc_output_stats stats;
    int64_t kbps_bytes, kbps_t0;

    int64_t io_deadline_us;
    pthread_mutex_t srt_lock;
    mc_srt *srt_live;

    // broadcast delay (output thread only, except dump_req)
    AVPacket **dq;            // FIFO of held packets
    int64_t *dq_release;      // wall time (us) each may go out
    int dq_head, dq_count, dq_cap;
    atomic_int dump_req;
    int delay_off;            // set after a dump: no delay until restart
};

typedef struct {
    AVFormatContext *oc;
    AVCodecContext *venc, *aenc;
    AVStream *vst, *ast;
    struct SwsContext *sws;
#ifdef __APPLE__
    VTPixelTransferSessionRef xfer;   // BGRA → NV12/2vuy on the GPU for VideoToolbox
    CVPixelBufferPoolRef yuv_pool;
#endif
    int64_t audio_pts;
    mc_srt *srt;
    float *achunk;
    int achunk_frames;
    AVCodecContext *xenc[MC_MAX_XTRACKS];
    AVStream *xst[MC_MAX_XTRACKS];
    int64_t xpts[MC_MAX_XTRACKS];
    float *xchunk;
} osession;

static void afifo_clear_all(mc_output *o) {
    mc_afifo_clear(&o->afifo);
    for (int i = 0; i < o->nx; i++) mc_afifo_clear(&o->xfifo[i]);
}

// lock held
static void vq_drop_head(mc_output *o) {
    vslot *v = &o->vq[o->vq_head];
    pb_release(v->pb);
    v->pb = NULL;
    o->vq_head = (o->vq_head + 1) % VQ_SLOTS;
    o->vq_count--;
}

// lock held
static void vq_clear(mc_output *o) {
    while (o->vq_count > 0) vq_drop_head(o);
}

static void ostatus(mc_output *o, int state, const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    pthread_mutex_lock(&o->lock);
    o->stats.state = state;
    pthread_mutex_unlock(&o->lock);
    if (o->status_cb) o->status_cb(o->user, state, buf);
}

static int ointerrupt(void *opaque) {
    mc_output *o = (mc_output *)opaque;
    if (atomic_load(&o->abort_io)) return 1;
    if (o->io_deadline_us && mc_now_us() > o->io_deadline_us) return 1;
    return 0;
}

static const char *guess_format(const char *url) {
    if (strncmp(url, "rtmp://", 7) == 0 || strncmp(url, "rtmps://", 8) == 0) return "flv";
    if (strncmp(url, "srt://", 6) == 0 || strncmp(url, "udp://", 6) == 0 || strncmp(url, "rtp://", 6) == 0)
        return "mpegts";
    return NULL;  // decide by extension
}

static void set_color(AVCodecContext *c) {
    c->color_range = AVCOL_RANGE_MPEG;
    c->colorspace = AVCOL_SPC_BT709;
    c->color_primaries = AVCOL_PRI_BT709;
    c->color_trc = AVCOL_TRC_BT709;
}

static AVCodecContext *try_open_video(mc_output *o, const char *name, const enum AVPixelFormat *fmts,
                                      int global_header) {
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    if (!codec) return NULL;
    int fps_num = o->cfg.fps_num, fps_den = o->cfg.fps_den;
    int gop = o->cfg.keyint_frames > 0 ? o->cfg.keyint_frames : (2 * fps_num + fps_den - 1) / fps_den;
    for (int i = 0; fmts[i] != AV_PIX_FMT_NONE; i++) {
        AVCodecContext *c = avcodec_alloc_context3(codec);
        if (!c) return NULL;
        c->width = o->cfg.width;
        c->height = o->cfg.height;
        c->time_base = (AVRational){fps_den, fps_num};
        c->framerate = (AVRational){fps_num, fps_den};
        c->sample_aspect_ratio = (AVRational){1, 1};
        c->pix_fmt = fmts[i];
        if (fmts[i] == AV_PIX_FMT_VIDEOTOOLBOX) {
            // frames are CVPixelBuffers; sw_pix_fmt only tells vtenc which profile/codec variant to use
            c->sw_pix_fmt = strstr(name, "prores") ? AV_PIX_FMT_UYVY422 : AV_PIX_FMT_NV12;
        }
        c->gop_size = gop;
        c->max_b_frames = 0;
        set_color(c);
        AVDictionary *opts = NULL;
        int is_prores = strstr(name, "prores") != NULL;
        if (!is_prores) {
            int64_t br = (int64_t)(o->cfg.video_kbps > 0 ? o->cfg.video_kbps : 6000) * 1000;
            c->bit_rate = br;
            c->rc_max_rate = br;
            c->rc_buffer_size = (int)(br * (o->is_network ? 1 : 2));
        }
        if (global_header) c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (strstr(name, "videotoolbox")) {
            av_dict_set(&opts, "realtime", "1", 0);
            av_dict_set(&opts, "allow_sw", "1", 0);
            if (strstr(name, "h264")) av_dict_set(&opts, "profile", "high", 0);
            if (is_prores) av_dict_set(&opts, "profile", "standard", 0);
        } else if (strcmp(name, "libx264") == 0) {
            av_dict_set(&opts, "preset", "veryfast", 0);
            if (o->is_network) av_dict_set(&opts, "tune", "zerolatency", 0);
            av_dict_set(&opts, "profile", "high", 0);
        } else if (strcmp(name, "libx265") == 0) {
            av_dict_set(&opts, "preset", "veryfast", 0);
        } else if (strcmp(name, "prores_ks") == 0) {
            av_dict_set(&opts, "profile", "standard", 0);
        }
        int ret = avcodec_open2(c, codec, &opts);
        av_dict_free(&opts);
        if (ret >= 0) return c;
        avcodec_free_context(&c);
    }
    return NULL;
}

static AVCodecContext *open_video_encoder(mc_output *o, int global_header) {
    static const enum AVPixelFormat f420[] = {AV_PIX_FMT_NV12, AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE};
    static const enum AVPixelFormat f422[] = {AV_PIX_FMT_UYVY422, AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_P210LE,
                                              AV_PIX_FMT_NV16, AV_PIX_FMT_NONE};
#ifdef __APPLE__
    // zero-copy: mixer IOSurface → VideoToolbox (hardware does BGRA→YUV)
    static const enum AVPixelFormat vt_hw[] = {AV_PIX_FMT_VIDEOTOOLBOX, AV_PIX_FMT_NONE};
    if (o->cfg.pixelbuffer_input && o->cfg.hardware) {
        const char *vc0 = o->vcodec ? o->vcodec : "h264";
        const char *name = strcmp(vc0, "prores") == 0 ? "prores_videotoolbox"
                         : (strcmp(vc0, "hevc") == 0 || strcmp(vc0, "h265") == 0) ? "hevc_videotoolbox"
                         : "h264_videotoolbox";
        AVCodecContext *c = try_open_video(o, name, vt_hw, global_header);
        if (c) return c;
    }
#endif
    const char *vc = o->vcodec ? o->vcodec : "h264";
    const char *hw[4] = {0}, *sw[4] = {0};
    const enum AVPixelFormat *fmts = f420;
    if (strcmp(vc, "hevc") == 0 || strcmp(vc, "h265") == 0) {
        hw[0] = "hevc_videotoolbox";
        sw[0] = "libx265";
    } else if (strcmp(vc, "prores") == 0) {
        hw[0] = "prores_videotoolbox";
        sw[0] = "prores_ks";
        sw[1] = "prores";
        fmts = f422;
    } else {
        hw[0] = "h264_videotoolbox";
        sw[0] = "libx264";
        sw[1] = "h264_v4l2m2m";
    }
    const char **order[2] = {o->cfg.hardware ? hw : sw, o->cfg.hardware ? sw : hw};
    for (int k = 0; k < 2; k++) {
        for (int i = 0; i < 4 && order[k][i]; i++) {
            AVCodecContext *c = try_open_video(o, order[k][i], fmts, global_header);
            if (c) return c;
        }
    }
    return NULL;
}

static AVCodecContext *open_audio_encoder(mc_output *o, int pcm, int global_header) {
    const AVCodec *codec = avcodec_find_encoder(pcm ? AV_CODEC_ID_PCM_S16LE : AV_CODEC_ID_AAC);
    if (!codec) return NULL;
    AVCodecContext *c = avcodec_alloc_context3(codec);
    if (!c) return NULL;
    c->sample_rate = MC_AUDIO_RATE;
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    av_channel_layout_copy(&c->ch_layout, &stereo);
    c->sample_fmt = pcm ? AV_SAMPLE_FMT_S16 : AV_SAMPLE_FMT_FLTP;
    c->time_base = (AVRational){1, MC_AUDIO_RATE};
    if (!pcm) c->bit_rate = (int64_t)(o->cfg.audio_kbps > 0 ? o->cfg.audio_kbps : 160) * 1000;
    if (global_header) c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (avcodec_open2(c, codec, NULL) < 0) {
        avcodec_free_context(&c);
        return NULL;
    }
    return c;
}

static void dq_clear(mc_output *o);

static void osession_close(mc_output *o, osession *s, int write_trailer) {
    dq_clear(o);              // held (delayed) packets never aired: stopping means stopping now
    if (s->oc) {
        if (write_trailer) {
            o->io_deadline_us = o->is_network ? mc_now_us() + 3000000 : 0;
            av_write_trailer(s->oc);
        }
        if (s->srt) {
            if (s->oc->pb) {
                avio_flush(s->oc->pb);
                av_freep(&s->oc->pb->buffer);
                avio_context_free(&s->oc->pb);
            }
            pthread_mutex_lock(&o->srt_lock);
            o->srt_live = NULL;
            pthread_mutex_unlock(&o->srt_lock);
            mc_srt_close(s->srt);
            s->srt = NULL;
        } else if (!(s->oc->oformat->flags & AVFMT_NOFILE) && s->oc->pb) {
            avio_closep(&s->oc->pb);
        }
        avformat_free_context(s->oc);
    }
    if (s->venc) avcodec_free_context(&s->venc);
    if (s->aenc) avcodec_free_context(&s->aenc);
    for (int i = 0; i < MC_MAX_XTRACKS; i++)
        if (s->xenc[i]) avcodec_free_context(&s->xenc[i]);
    free(s->xchunk);
#ifdef __APPLE__
    if (s->xfer) {
        VTPixelTransferSessionInvalidate(s->xfer);
        CFRelease(s->xfer);
    }
    if (s->yuv_pool) CVPixelBufferPoolRelease(s->yuv_pool);
#endif
    if (s->sws) sws_freeContext(s->sws);
    free(s->achunk);
    memset(s, 0, sizeof(*s));
}

#if LIBAVFORMAT_VERSION_MAJOR >= 61
static int srt_write_cb(void *opaque, const uint8_t *buf, int size) {
#else
static int srt_write_cb(void *opaque, uint8_t *buf, int size) {
#endif
    return mc_srt_write((mc_srt *)opaque, buf, size);
}

static int osession_open(mc_output *o, osession *s, char *err, int errlen) {
    memset(s, 0, sizeof(*s));
    const char *fmtname = o->format && o->format[0] ? o->format : guess_format(o->url);
    int ret = avformat_alloc_output_context2(&s->oc, NULL, fmtname, o->url);
    if (ret < 0 || !s->oc) {
        snprintf(err, errlen, "컨테이너를 결정할 수 없음 (%s)", o->url);
        return -1;
    }
    s->oc->interrupt_callback.callback = ointerrupt;
    s->oc->interrupt_callback.opaque = o;
    if (o->is_network) s->oc->flush_packets = 1;
    int gh = (s->oc->oformat->flags & AVFMT_GLOBALHEADER) ? 1 : 0;

    s->venc = open_video_encoder(o, gh);
    if (!s->venc) {
        snprintf(err, errlen, "비디오 인코더를 열 수 없음 (%s)", o->vcodec ? o->vcodec : "h264");
        return -1;
    }
    int pcm = o->vcodec && strcmp(o->vcodec, "prores") == 0 &&
              (strcmp(s->oc->oformat->name, "mov") == 0);
    s->aenc = open_audio_encoder(o, pcm, gh);
    if (!s->aenc) {
        snprintf(err, errlen, "오디오 인코더를 열 수 없음");
        return -1;
    }
    s->vst = avformat_new_stream(s->oc, NULL);
    s->ast = avformat_new_stream(s->oc, NULL);
    if (!s->vst || !s->ast) {
        snprintf(err, errlen, "스트림 생성 실패");
        return -1;
    }
    avcodec_parameters_from_context(s->vst->codecpar, s->venc);
    avcodec_parameters_from_context(s->ast->codecpar, s->aenc);
    s->vst->time_base = s->venc->time_base;
    s->vst->avg_frame_rate = s->venc->framerate;
    s->ast->time_base = s->aenc->time_base;
    for (int i = 0; i < o->nx; i++) {
        s->xenc[i] = open_audio_encoder(o, pcm, gh);
        s->xst[i] = s->xenc[i] ? avformat_new_stream(s->oc, NULL) : NULL;
        if (!s->xst[i]) {
            snprintf(err, errlen, "오디오 트랙 %d 생성 실패", i + 2);
            return -1;
        }
        avcodec_parameters_from_context(s->xst[i]->codecpar, s->xenc[i]);
        s->xst[i]->time_base = s->xenc[i]->time_base;
    }

    if (s->venc->pix_fmt != AV_PIX_FMT_VIDEOTOOLBOX) {
        s->sws = mc_sws_get(o->cfg.width, o->cfg.height, AV_PIX_FMT_BGRA, o->cfg.width, o->cfg.height,
                            s->venc->pix_fmt, SWS_BILINEAR);
        if (!s->sws) {
            snprintf(err, errlen, "색 변환기 생성 실패");
            return -1;
        }
        const int *c709 = sws_getCoefficients(SWS_CS_ITU709);
        sws_setColorspaceDetails(s->sws, c709, 1, c709, 0, 0, 1 << 16, 1 << 16);
    }

    s->achunk_frames = s->aenc->frame_size > 0 ? s->aenc->frame_size : 1024;
    s->achunk = (float *)malloc((size_t)s->achunk_frames * 2 * sizeof(float));
    if (o->nx > 0) s->xchunk = (float *)malloc((size_t)s->achunk_frames * 2 * sizeof(float) * o->nx);

    if (strncmp(o->url, "srt://", 6) == 0 && mc_srt_supported()) {
        // direct libsrt (live link statistics); listener waits for a caller without timing out
        int listener = strstr(o->url, "mode=listener") != NULL || strstr(o->url, "listen=1") != NULL;
        if (listener) ostatus(o, MC_STATE_CONNECTING, "SRT 리스너 — 수신 측 접속 대기 중…");
        o->io_deadline_us = listener ? 0 : mc_now_us() + 15000000;
        s->srt = mc_srt_open(o->url, 1, ointerrupt, o, err, errlen);
        o->io_deadline_us = 0;
        if (!s->srt) return -1;
        uint8_t *iobuf = (uint8_t *)av_malloc(1316);
        s->oc->pb = avio_alloc_context(iobuf, 1316, 1, s->srt, NULL, srt_write_cb, NULL);
        if (!s->oc->pb) {
            snprintf(err, errlen, "SRT 출력 버퍼 생성 실패");
            return -1;
        }
        s->oc->pb->max_packet_size = 1316;
        s->oc->flags |= AVFMT_FLAG_CUSTOM_IO;
        pthread_mutex_lock(&o->srt_lock);
        o->srt_live = s->srt;
        pthread_mutex_unlock(&o->srt_lock);
    } else if (!(s->oc->oformat->flags & AVFMT_NOFILE)) {
        int listener = strstr(o->url, "mode=listener") != NULL || strstr(o->url, "listen=1") != NULL;
        o->io_deadline_us = (o->is_network && !listener) ? mc_now_us() + 15000000 : 0;
        ret = avio_open2(&s->oc->pb, o->url, AVIO_FLAG_WRITE, &s->oc->interrupt_callback, NULL);
        o->io_deadline_us = 0;
        if (ret < 0) {
            char e[128];
            av_strerror(ret, e, sizeof(e));
            snprintf(err, errlen, "연결 실패: %s", e);
            return -1;
        }
    }
    AVDictionary *mopts = NULL;
    if (strcmp(s->oc->oformat->name, "mp4") == 0) av_dict_set(&mopts, "movflags", "+faststart", 0);
    o->io_deadline_us = o->is_network ? mc_now_us() + 10000000 : 0;
    ret = avformat_write_header(s->oc, &mopts);
    o->io_deadline_us = 0;
    av_dict_free(&mopts);
    if (ret < 0) {
        char e[128];
        av_strerror(ret, e, sizeof(e));
        snprintf(err, errlen, "헤더 쓰기 실패: %s", e);
        return -1;
    }
    pthread_mutex_lock(&o->lock);
    snprintf(o->stats.encoder, sizeof(o->stats.encoder), "%s", s->venc->codec->name);
    pthread_mutex_unlock(&o->lock);
    return 0;
}

// ---- broadcast delay queue (output thread) ----
static void dq_push(mc_output *o, AVPacket *pkt, int64_t release) {
    if (o->dq_count == o->dq_cap) {
        int nc = o->dq_cap ? o->dq_cap * 2 : 4096;
        AVPacket **nq = calloc(nc, sizeof(*nq));
        int64_t *nr = calloc(nc, sizeof(*nr));
        for (int i = 0; i < o->dq_count; i++) {
            nq[i] = o->dq[(o->dq_head + i) % o->dq_cap];
            nr[i] = o->dq_release[(o->dq_head + i) % o->dq_cap];
        }
        free(o->dq); free(o->dq_release);
        o->dq = nq; o->dq_release = nr; o->dq_head = 0; o->dq_cap = nc;
    }
    int t = (o->dq_head + o->dq_count) % o->dq_cap;
    o->dq[t] = av_packet_clone(pkt);
    o->dq_release[t] = release;
    o->dq_count++;
}

static void dq_clear(mc_output *o) {
    while (o->dq_count > 0) {
        av_packet_free(&o->dq[o->dq_head]);
        o->dq_head = (o->dq_head + 1) % o->dq_cap;
        o->dq_count--;
    }
}

/* Writes held packets whose time has come. `all` = write everything. Handles a pending dump. */
static int dq_flush(mc_output *o, osession *s, int all) {
    if (atomic_exchange(&o->dump_req, 0) && o->dq_count > 0) {
        // keep from the newest video keyframe on (decoders need one), drop the rest, go live
        int keep_from = -1;
        for (int i = o->dq_count - 1; i >= 0; i--) {
            AVPacket *p = o->dq[(o->dq_head + i) % o->dq_cap];
            if (s->vst && p->stream_index == s->vst->index && (p->flags & AV_PKT_FLAG_KEY)) { keep_from = i; break; }
        }
        int drop = keep_from < 0 ? o->dq_count : keep_from;
        for (int i = 0; i < drop; i++) {
            av_packet_free(&o->dq[o->dq_head]);
            o->dq_head = (o->dq_head + 1) % o->dq_cap;
            o->dq_count--;
        }
        o->delay_off = 1;
        all = 1;
    }
    int64_t now = mc_now_us();
    while (o->dq_count > 0 && (all || o->dq_release[o->dq_head] <= now)) {
        AVPacket *p = o->dq[o->dq_head];
        o->dq[o->dq_head] = NULL;
        o->dq_head = (o->dq_head + 1) % o->dq_cap;
        o->dq_count--;
        int size = p->size;
        o->io_deadline_us = o->is_network ? mc_now_us() + 5000000 : 0;
        int ret = av_interleaved_write_frame(s->oc, p);
        o->io_deadline_us = 0;
        av_packet_free(&p);
        if (ret < 0) return ret;
        pthread_mutex_lock(&o->lock);
        o->stats.bytes_written += size;
        o->kbps_bytes += size;
        if (now - o->kbps_t0 >= 1000000) {
            o->stats.kbps = (double)o->kbps_bytes * 8.0 / 1000.0 / ((now - o->kbps_t0) / 1e6);
            o->kbps_bytes = 0;
            o->kbps_t0 = now;
        }
        pthread_mutex_unlock(&o->lock);
    }
    pthread_mutex_lock(&o->lock);
    o->stats.delay_buffered_ms = o->dq_count > 0
        ? (int)((o->cfg.delay_ms > 0 ? o->cfg.delay_ms : 0) - (o->dq_release[o->dq_head] - now) / 1000) : 0;
    if (o->stats.delay_buffered_ms < 0) o->stats.delay_buffered_ms = 0;
    pthread_mutex_unlock(&o->lock);
    return 0;
}

void mc_output_dump_delay(mc_output *o) {
    if (o) atomic_store(&o->dump_req, 1);
}

static int write_packets(mc_output *o, osession *s, AVCodecContext *enc, AVStream *st) {
    AVPacket *pkt = av_packet_alloc();
    int ret = 0;
    for (;;) {
        ret = avcodec_receive_packet(enc, pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            ret = 0;
            break;
        }
        if (ret < 0) break;
        av_packet_rescale_ts(pkt, enc->time_base, st->time_base);
        pkt->stream_index = st->index;
        int size = pkt->size;
        if (o->cfg.delay_ms > 0 && !o->delay_off) {
            // broadcast delay: hold the encoded packet (≈ bitrate × delay of RAM, no re-encode, no quality loss)
            dq_push(o, pkt, mc_now_us() + (int64_t)o->cfg.delay_ms * 1000);
            av_packet_unref(pkt);
            ret = dq_flush(o, s, 0);
            if (ret < 0) break;
            continue;
        }
        o->io_deadline_us = o->is_network ? mc_now_us() + 5000000 : 0;
        ret = av_interleaved_write_frame(s->oc, pkt);
        o->io_deadline_us = 0;
        if (ret < 0) break;
        pthread_mutex_lock(&o->lock);
        o->stats.bytes_written += size;
        o->kbps_bytes += size;
        int64_t now = mc_now_us();
        if (now - o->kbps_t0 >= 1000000) {
            o->stats.kbps = (double)o->kbps_bytes * 8.0 / 1000.0 / ((now - o->kbps_t0) / 1e6);
            o->kbps_bytes = 0;
            o->kbps_t0 = now;
        }
        pthread_mutex_unlock(&o->lock);
    }
    av_packet_free(&pkt);
    return ret;
}

#ifdef __APPLE__
static void free_pb(void *opaque, uint8_t *data) {
    (void)data;
    CFRelease((CFTypeRef)opaque);
}
#endif

static int encode_video(mc_output *o, osession *s, const uint8_t *bgra, int stride, int64_t pts);

#ifdef __APPLE__
static void cfdict_set_int(CFMutableDictionaryRef d, CFStringRef k, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
}

static int yuv_setup(osession *s, int w, int h) {
    if (s->xfer && s->yuv_pool) return 0;
    OSType fmt = s->venc->sw_pix_fmt == AV_PIX_FMT_UYVY422 ? kCVPixelFormatType_422YpCbCr8
                                                           : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef ios = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                           &kCFTypeDictionaryValueCallBacks);
    cfdict_set_int(attrs, kCVPixelBufferPixelFormatTypeKey, (int)fmt);
    cfdict_set_int(attrs, kCVPixelBufferWidthKey, w);
    cfdict_set_int(attrs, kCVPixelBufferHeightKey, h);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, ios);
    CFRelease(ios);
    CVReturn r = CVPixelBufferPoolCreate(NULL, NULL, attrs, &s->yuv_pool);
    CFRelease(attrs);
    if (r != kCVReturnSuccess) return -1;
    if (VTPixelTransferSessionCreate(NULL, &s->xfer) != noErr) return -1;
    VTSessionSetProperty(s->xfer, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    VTSessionSetProperty(s->xfer, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(s->xfer, kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(s->xfer, kVTPixelTransferPropertyKey_RealTime, kCFBooleanTrue);
    return 0;
}

/* BGRA IOSurface → pooled NV12 (or 2vuy) IOSurface on the GPU. Returns a +1 buffer or NULL. */
static CVPixelBufferRef yuv_convert(osession *s, CVPixelBufferRef src) {
    if (yuv_setup(s, s->venc->width, s->venc->height) < 0) return NULL;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, s->yuv_pool, &dst) != kCVReturnSuccess || !dst) return NULL;
    if (VTPixelTransferSessionTransferImage(s->xfer, src, dst) != noErr) {
        CFRelease(dst);
        return NULL;
    }
    return dst;
}
#endif

/* Takes ownership of one retain on pb. */
static int encode_video_pb(mc_output *o, osession *s, void *pb, int64_t pts) {
#ifdef __APPLE__
    CVPixelBufferRef cv = (CVPixelBufferRef)pb;
    if (s->venc->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX) {
        if (CVPixelBufferGetPixelFormatType(cv) == kCVPixelFormatType_32BGRA) {
            CVPixelBufferRef yuv = yuv_convert(s, cv);
            if (yuv) {          // else hand BGRA to VideoToolbox and let it convert
                CFRelease(cv);
                cv = yuv;
            }
        }
        AVFrame *f = av_frame_alloc();
        if (!f) {
            CFRelease(cv);
            return AVERROR(ENOMEM);
        }
        f->format = AV_PIX_FMT_VIDEOTOOLBOX;
        f->width = s->venc->width;
        f->height = s->venc->height;
        f->data[3] = (uint8_t *)cv;
        f->buf[0] = av_buffer_create((uint8_t *)cv, 1, free_pb, cv, AV_BUFFER_FLAG_READONLY);
        if (!f->buf[0]) {
            CFRelease(cv);
            av_frame_free(&f);
            return AVERROR(ENOMEM);
        }
        f->color_range = AVCOL_RANGE_MPEG;
        f->colorspace = AVCOL_SPC_BT709;
        f->color_primaries = AVCOL_PRI_BT709;
        f->color_trc = AVCOL_TRC_BT709;
        f->pts = pts;
        int ret = avcodec_send_frame(s->venc, f);
        av_frame_free(&f);   // releases our reference; vtenc keeps its own until encoded
        if (ret < 0) return ret;
        return write_packets(o, s, s->venc, s->vst);
    }
    // software encoder: read the IOSurface directly (unified memory, no extra copy)
    int ret = AVERROR(EINVAL);
    if (CVPixelBufferLockBaseAddress(cv, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(cv);
        int stride = (int)CVPixelBufferGetBytesPerRow(cv);
        if (base) ret = encode_video(o, s, base, stride, pts);
        CVPixelBufferUnlockBaseAddress(cv, kCVPixelBufferLock_ReadOnly);
    }
    CFRelease(cv);
    return ret;
#else
    (void)o; (void)s; (void)pb; (void)pts;
    return AVERROR(ENOSYS);
#endif
}

static int encode_video(mc_output *o, osession *s, const uint8_t *bgra, int stride, int64_t pts) {
    if (!s->sws) return AVERROR(EINVAL);
    AVFrame *f = av_frame_alloc();
    if (!f) return AVERROR(ENOMEM);
    f->format = s->venc->pix_fmt;
    f->width = s->venc->width;
    f->height = s->venc->height;
    f->color_range = AVCOL_RANGE_MPEG;
    f->colorspace = AVCOL_SPC_BT709;
    f->color_primaries = AVCOL_PRI_BT709;
    f->color_trc = AVCOL_TRC_BT709;
    if (av_frame_get_buffer(f, 0) < 0) {
        av_frame_free(&f);
        return AVERROR(ENOMEM);
    }
    const uint8_t *src[4] = {bgra, NULL, NULL, NULL};
    int src_stride[4] = {stride, 0, 0, 0};
    sws_scale(s->sws, src, src_stride, 0, o->cfg.height, f->data, f->linesize);
    f->pts = pts;
    int ret = avcodec_send_frame(s->venc, f);
    av_frame_free(&f);
    if (ret < 0) return ret;
    return write_packets(o, s, s->venc, s->vst);
}

static int encode_audio_to(mc_output *o, osession *s, AVCodecContext *enc, AVStream *st, int64_t *ppts,
                           const float *stereo, int frames) {
    AVFrame *f = av_frame_alloc();
    if (!f) return AVERROR(ENOMEM);
    f->format = enc->sample_fmt;
    f->nb_samples = frames;
    f->sample_rate = MC_AUDIO_RATE;
    av_channel_layout_copy(&f->ch_layout, &enc->ch_layout);
    if (av_frame_get_buffer(f, 0) < 0) {
        av_frame_free(&f);
        return AVERROR(ENOMEM);
    }
    if (enc->sample_fmt == AV_SAMPLE_FMT_FLTP) {
        float *l = (float *)f->data[0], *r = (float *)f->data[1];
        for (int i = 0; i < frames; i++) {
            l[i] = stereo[i * 2];
            r[i] = stereo[i * 2 + 1];
        }
    } else {
        int16_t *d = (int16_t *)f->data[0];
        for (int i = 0; i < frames * 2; i++) {
            float v = stereo[i];
            if (v > 1.f) v = 1.f;
            if (v < -1.f) v = -1.f;
            d[i] = (int16_t)(v * 32767.f);
        }
    }
    f->pts = *ppts;
    *ppts += frames;
    int ret = avcodec_send_frame(enc, f);
    av_frame_free(&f);
    if (ret < 0) return ret;
    return write_packets(o, s, enc, st);
}

static int encode_audio_chunk(mc_output *o, osession *s, const float *stereo, int frames) {
    return encode_audio_to(o, s, s->aenc, s->ast, &s->audio_pts, stereo, frames);
}

static int flush_encoders(mc_output *o, osession *s) {
    if (s->venc) {
        avcodec_send_frame(s->venc, NULL);
        write_packets(o, s, s->venc, s->vst);
    }
    if (s->aenc) {
        avcodec_send_frame(s->aenc, NULL);
        write_packets(o, s, s->aenc, s->ast);
    }
    for (int i = 0; i < MC_MAX_XTRACKS; i++)
        if (s->xenc[i]) {
            avcodec_send_frame(s->xenc[i], NULL);
            write_packets(o, s, s->xenc[i], s->xst[i]);
        }
    return 0;
}

static void *output_thread(void *arg) {
    mc_output *o = (mc_output *)arg;
    size_t fsize = (size_t)o->cfg.width * o->cfg.height * 4;
    uint8_t *local = o->cfg.pixelbuffer_input ? NULL : (uint8_t *)malloc(fsize);
    int attempt = 0;
    while (!atomic_load(&o->stop)) {
        osession s;
        char err[256] = {0};
        ostatus(o, MC_STATE_CONNECTING, o->is_network ? "연결 중…" : "녹화 준비 중…");
        if (osession_open(o, &s, err, sizeof(err)) < 0) {
            osession_close(o, &s, 0);
            if (atomic_load(&o->stop)) break;
            ostatus(o, MC_STATE_ERROR, "%s", err);
            if (!(o->is_network && o->cfg.reconnect)) break;
            attempt++;
            int64_t until = mc_now_us() + (attempt < 3 ? 2000000 : 5000000);
            while (!atomic_load(&o->stop) && mc_now_us() < until) mc_sleep_us(50000);
            continue;
        }
        attempt = 0;
        pthread_mutex_lock(&o->lock);
        vq_clear(o);
        afifo_clear_all(o);
        o->need_sync = 1;
        o->accepting = 1;
        o->kbps_t0 = mc_now_us();
        o->kbps_bytes = 0;
        pthread_mutex_unlock(&o->lock);
        ostatus(o, MC_STATE_RUNNING, "%s", o->is_network ? "송출 중" : "녹화 중");

        int failed = 0;
        for (;;) {
            pthread_mutex_lock(&o->lock);
            while (!atomic_load(&o->stop) && o->vq_count == 0 && o->afifo.count < s.achunk_frames) {
                struct timespec ts;
                clock_gettime(CLOCK_REALTIME, &ts);
                ts.tv_nsec += 100 * 1000000;
                if (ts.tv_nsec >= 1000000000) {
                    ts.tv_sec++;
                    ts.tv_nsec -= 1000000000;
                }
                pthread_cond_timedwait(&o->cond, &o->lock, &ts);
            }
            int stopping = atomic_load(&o->stop);
            int have_video = o->vq_count > 0;
            int remaining = o->vq_count - (have_video ? 1 : 0);
            int64_t pts = 0;
            void *pb = NULL;
            int have_bgra = 0;
            if (have_video) {
                vslot *v = &o->vq[o->vq_head];
                pts = v->tick - o->base_tick;
                if (v->pb) {
                    pb = v->pb;          // ownership moves to the encoder
                    v->pb = NULL;
                } else if (local && v->data) {
                    memcpy(local, v->data, fsize);
                    have_bgra = 1;
                }
                o->vq_head = (o->vq_head + 1) % VQ_SLOTS;
                o->vq_count--;
            }
            pthread_mutex_unlock(&o->lock);

            int ret = 0;
            if (have_video && (pb || have_bgra)) {
                ret = pb ? encode_video_pb(o, &s, pb, pts) : encode_video(o, &s, local, o->cfg.width * 4, pts);
                if (ret >= 0) {
                    pthread_mutex_lock(&o->lock);
                    o->stats.frames_encoded++;
                    pthread_mutex_unlock(&o->lock);
                }
            }
            while (ret >= 0) {
                pthread_mutex_lock(&o->lock);
                int got = 0;
                if (o->afifo.count >= s.achunk_frames) {
                    got = mc_afifo_read(&o->afifo, s.achunk, s.achunk_frames);
                    for (int i = 0; i < o->nx; i++) {
                        float *dst = s.xchunk + (size_t)i * s.achunk_frames * 2;
                        int gx = mc_afifo_read(&o->xfifo[i], dst, got);
                        if (gx < got) memset(dst + gx * 2, 0, (size_t)(got - gx) * 2 * sizeof(float));
                    }
                }
                pthread_mutex_unlock(&o->lock);
                if (!got) break;
                ret = encode_audio_chunk(o, &s, s.achunk, got);
                for (int i = 0; i < o->nx && ret >= 0; i++)
                    ret = encode_audio_to(o, &s, s.xenc[i], s.xst[i], &s.xpts[i],
                                          s.xchunk + (size_t)i * s.achunk_frames * 2, got);
            }
            if (ret < 0) {
                char e[128];
                av_strerror(ret, e, sizeof(e));
                snprintf(err, sizeof(err), "%s", e);
                failed = 1;
                break;
            }
            if (stopping && (o->is_network || remaining <= 0)) break;
        }
        pthread_mutex_lock(&o->lock);
        o->accepting = 0;
        pthread_mutex_unlock(&o->lock);
        if (!failed) flush_encoders(o, &s);
        osession_close(o, &s, !failed || !o->is_network);
        if (atomic_load(&o->stop)) break;
        if (failed) {
            if (o->is_network && o->cfg.reconnect) {
                ostatus(o, MC_STATE_ERROR, "전송 오류: %s — 재연결 중", err);
                int64_t until = mc_now_us() + 2000000;
                while (!atomic_load(&o->stop) && mc_now_us() < until) mc_sleep_us(50000);
                continue;
            }
            ostatus(o, MC_STATE_ERROR, "쓰기 오류: %s", err);
            free(local);
            return NULL;
        }
    }
    free(local);
    ostatus(o, MC_STATE_STOPPED, "중지됨");
    return NULL;
}

mc_output *mc_output_open(const mc_output_config *cfg, mc_status_cb status_cb, void *user) {
    if (!cfg || !cfg->url || cfg->width <= 0 || cfg->height <= 0 || cfg->fps_num <= 0 || cfg->fps_den <= 0)
        return NULL;
    mc_output *o = (mc_output *)calloc(1, sizeof(mc_output));
    if (!o) return NULL;
    o->cfg = *cfg;
    o->url = strdup(cfg->url);
    o->format = cfg->format ? strdup(cfg->format) : NULL;
    o->vcodec = cfg->video_codec ? strdup(cfg->video_codec) : NULL;
    o->cfg.url = o->url;
    o->cfg.format = o->format;
    o->cfg.video_codec = o->vcodec;
    o->status_cb = status_cb;
    o->user = user;
    o->is_network = strstr(o->url, "://") != NULL && strncmp(o->url, "file:", 5) != 0;
    pthread_mutex_init(&o->lock, NULL);
    pthread_mutex_init(&o->srt_lock, NULL);
    pthread_cond_init(&o->cond, NULL);
    atomic_init(&o->stop, 0);
    atomic_init(&o->abort_io, 0);
    mc_afifo_init(&o->afifo, MC_AUDIO_RATE * 2);
    o->nx = cfg->extra_audio_tracks < 0 ? 0 : (cfg->extra_audio_tracks > MC_MAX_XTRACKS ? MC_MAX_XTRACKS : cfg->extra_audio_tracks);
    for (int i = 0; i < o->nx; i++) mc_afifo_init(&o->xfifo[i], MC_AUDIO_RATE * 2);
    avformat_network_init();
    if (pthread_create(&o->thread, NULL, output_thread, o) != 0) {
        for (int i = 0; i < VQ_SLOTS; i++) free(o->vq[i].data);
        free(o->url);
        free(o->format);
        free(o->vcodec);
        free(o);
        return NULL;
    }
    return o;
}

void mc_output_push_video(mc_output *o, const uint8_t *bgra, int stride, int64_t tick) {
    if (!o || !bgra) return;
    int w = o->cfg.width, h = o->cfg.height;
    pthread_mutex_lock(&o->lock);
    if (!o->accepting) {
        pthread_mutex_unlock(&o->lock);
        return;
    }
    if (o->need_sync) {
        o->need_sync = 0;
        o->base_tick = tick;
        vq_clear(o);
        afifo_clear_all(o);
    }
    if (o->vq_count == VQ_SLOTS) {
        // encoder is behind: drop the oldest queued frame
        vq_drop_head(o);
        o->stats.frames_dropped++;
    }
    vslot *v = &o->vq[(o->vq_head + o->vq_count) % VQ_SLOTS];
    if (!v->data) v->data = (uint8_t *)malloc((size_t)w * h * 4);
    if (!v->data) {
        pthread_mutex_unlock(&o->lock);
        return;
    }
    if (stride == w * 4) memcpy(v->data, bgra, (size_t)w * h * 4);
    else
        for (int y = 0; y < h; y++) memcpy(v->data + (size_t)y * w * 4, bgra + (size_t)y * stride, (size_t)w * 4);
    v->tick = tick;
    o->vq_count++;
    o->stats.queue_depth = o->vq_count;
    pthread_cond_signal(&o->cond);
    pthread_mutex_unlock(&o->lock);
}

void mc_output_push_pixelbuffer(mc_output *o, void *pixel_buffer, int64_t tick) {
#ifdef __APPLE__
    if (!o || !pixel_buffer) return;
    pthread_mutex_lock(&o->lock);
    if (!o->accepting) {
        pthread_mutex_unlock(&o->lock);
        return;
    }
    if (o->need_sync) {
        o->need_sync = 0;
        o->base_tick = tick;
        vq_clear(o);
        afifo_clear_all(o);
    }
    if (o->vq_count == VQ_SLOTS) {
        vq_drop_head(o);
        o->stats.frames_dropped++;
    }
    vslot *v = &o->vq[(o->vq_head + o->vq_count) % VQ_SLOTS];
    v->pb = (void *)CFRetain((CFTypeRef)pixel_buffer);
    v->tick = tick;
    o->vq_count++;
    o->stats.queue_depth = o->vq_count;
    pthread_cond_signal(&o->cond);
    pthread_mutex_unlock(&o->lock);
#else
    (void)o; (void)pixel_buffer; (void)tick;
#endif
}

void mc_output_push_audio(mc_output *o, const float *stereo, int frames) {
    mc_output_push_audio_tracks(o, stereo, NULL, 0, frames);
}

void mc_output_push_audio_tracks(mc_output *o, const float *stereo, const float *const *extra, int nextra, int frames) {
    if (!o || !stereo || frames <= 0) return;
    pthread_mutex_lock(&o->lock);
    if (o->accepting && !o->need_sync) {
        mc_afifo_write(&o->afifo, stereo, frames);
        for (int i = 0; i < o->nx; i++) {
            if (extra && i < nextra && extra[i]) mc_afifo_write(&o->xfifo[i], extra[i], frames);
            else {
                float z[512];
                memset(z, 0, sizeof(z));
                for (int left = frames; left > 0; left -= 256) mc_afifo_write(&o->xfifo[i], z, left > 256 ? 256 : left);
            }
        }
        pthread_cond_signal(&o->cond);
    }
    pthread_mutex_unlock(&o->lock);
}

void mc_output_get_stats(mc_output *o, mc_output_stats *st) {
    if (!o || !st) return;
    pthread_mutex_lock(&o->lock);
    *st = o->stats;
    st->queue_depth = o->vq_count;
    pthread_mutex_unlock(&o->lock);
}

void mc_output_close(mc_output *o) {
    if (!o) return;
    atomic_store(&o->stop, 1);
    if (o->is_network) atomic_store(&o->abort_io, 1);
    pthread_mutex_lock(&o->lock);
    pthread_cond_signal(&o->cond);
    pthread_mutex_unlock(&o->lock);
    pthread_join(o->thread, NULL);
    vq_clear(o);
    for (int i = 0; i < VQ_SLOTS; i++) {
        pb_release(o->vq[i].pb);
        free(o->vq[i].data);
    }
    mc_afifo_free(&o->afifo);
    for (int i = 0; i < MC_MAX_XTRACKS; i++) mc_afifo_free(&o->xfifo[i]);
    pthread_mutex_destroy(&o->lock);
    pthread_mutex_destroy(&o->srt_lock);
    pthread_cond_destroy(&o->cond);
    free(o->url);
    free(o->format);
    free(o->vcodec);
    dq_clear(o);
    free(o->dq);
    free(o->dq_release);
    free(o);
}

int mc_output_srt_stats(mc_output *o, mc_srt_stats *out) {
    memset(out, 0, sizeof(*out));
    if (!o) return 0;
    pthread_mutex_lock(&o->srt_lock);
    int ok = o->srt_live != NULL;
    if (ok) mc_srt_get_stats(o->srt_live, out);
    pthread_mutex_unlock(&o->srt_lock);
    return ok;
}
