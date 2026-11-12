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
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
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
    // Audio frames the FIFO dropped (oldest) while the encoder was stalled. Audio timestamps are a running
    // sample count, so they must skip the same amount — otherwise all later audio plays early by that
    // much, adding up with every stall (permanent lip-sync error until a reconnect).
    int64_t audio_dropped;
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
    struct dq_ent *dq;        // FIFO of held packets (in RAM or spooled to disk)
    int dq_head, dq_count, dq_cap;
    atomic_int dump_req;
    int delay_off;            // set after a dump: no delay until restart
    // Held packets survive a network reconnect (before, a 2 s drop threw the whole delay away and
    // viewers got the full delay again as dead air). The output timeline continues across sessions.
    int64_t outage_us;        // wall time the connection was lost while packets were held (0 = none)
    int64_t content_end_us;   // end of the timeline produced so far (µs, incl. ts_offset_us)
    int64_t ts_offset_us;     // added to every new session's timestamps

    // disk spool for long delays (cfg.delay_dir): packets go into ~1-minute segment files
    char *spool_dir;          // our own subfolder, removed on close
    int spool_failed;         // could not create/write → new packets stay in RAM
    int w_fd, w_seg, r_fd, r_seg, low_seg;
    int64_t w_off, w_seg_t0;
    int64_t disk_bytes;       // bytes currently held on disk
    uint8_t *rbuf; int rbuf_cap;

    // "New file every N min" (mc_output_split): requested path, taken by the output thread (lock)
    char *split_req;
    char *cur_path;           // file being written now (lock), see mc_output_current_file

    // recording safety (files): backup mirror + continue on another disk
    char *mirror_dir, *spill_dir;   // owned copies of cfg.mirror_dir / cfg.spill_dir (NULL = off)
    char *backup_path;        // mirror file being written now (lock)
    char warning[256];        // last safety warning (lock)
    int cbr_fallback;         // CBR was requested but the encoder refused it (capped VBR instead)
    int spill_split;          // the pending split is a "disk full" spill (output thread)
    int spill_warned;         // "low space, nowhere to continue" already reported (output thread)
};

typedef struct dq_ent {
    AVPacket *mem;            // packet in RAM, or NULL when on disk
    AVRational tb;            // time base of the session that produced it
    int64_t release;          // wall time (us) it may go out
    int64_t off, pts, dts, duration;
    int size, seg, stream_index, flags;
} dq_ent;

typedef struct osession_s {
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
    int64_t last_dts[2 + MC_MAX_XTRACKS];   // per stream, muxer time base (INT64_MIN = none yet)

    /* Seamless file split: the encoders keep running; at a forced keyframe the muxer switches files.
       Video packets before the cut still go to the old file (`prev`, which keeps the old muxer and its
       own audio encoders until the old audio reaches the cut sample), later ones to the new file with
       timestamps rebased by `v_off`. Audio is cut sample-exactly on the same instant: the old audio
       encoder gets the samples up to cut_a (last frame may be short) and is flushed, a fresh encoder
       starts the new file at pts 0, so each file has its own clean AAC priming. */
    int64_t v_off;            // video pts (encoder time base) where this file starts
    int64_t atl;              // audio timeline: samples taken from the FIFO (incl. dropped) since sync
    struct osession_s *prev;  // old file being finished after a split, or NULL
    int64_t cut_v, cut_a;     // split point: video pts / audio timeline sample
    int prev_vdone, prev_adone;
    int64_t prev_t0;          // when the split started (gives up waiting for audio that stopped)
    char *split_pending;      // requested path, waiting for a frame that is not behind the audio
    int force_key;            // next video frame is encoded as a keyframe
    int split_waits;          // frames the pending split waited for the audio to catch up

    /* Recording safety (files only). Packets are written to the main file and, when a backup folder is
       set, the same packets to a mirror muxer (moc). About once a second, right before a video keyframe,
       a checkpoint drains both muxers (fragment + avio flush) and records the good file size. Packets
       since the last checkpoint are kept (refs, only with a spill folder): if the main file fails, it is
       truncated to its last good size and either the mirror takes over as the main file, or a new file in
       the spill folder starts with the kept packets — nothing written since the checkpoint is lost. */
    char *path;               // main file path
    int64_t base_us;          // subtracted from timestamps written to the main file (spill file taking over
                              // mid-stream starts at 0); INT64_MIN = take it from the next packet
    int64_t good;             // main file size at the last good checkpoint
    AVFormatContext *moc;     // backup (mirror) muxer with the same streams, or NULL
    char *mpath;
    int64_t m_good;
    int64_t ck_us;            // timeline time of the last checkpoint (INT64_MIN = none yet)
    struct kpkt *keep;        // packets written since the last checkpoint (spill replay)
    int nkeep, ckeep;
    int is_prev;              // old file being finished after a split
} osession;

typedef struct kpkt { AVPacket *p; AVRational tb; } kpkt;

/* Writes one packet; drops one whose dts doesn't move forward. That only happens at the seam between
   packets held across a reconnect and the new session's first audio (encoder priming overlaps), and a
   muxer error there would drop the connection again. */
static int file_write(mc_output *o, osession *s, AVPacket *p);

static int mux_write(mc_output *o, osession *s, AVPacket *p) {
    int i = p->stream_index;
    if (i >= 0 && i < (int)(sizeof(s->last_dts) / sizeof(s->last_dts[0])) && p->dts != AV_NOPTS_VALUE) {
        if (s->last_dts[i] != INT64_MIN && p->dts <= s->last_dts[i]) return 0;
        s->last_dts[i] = p->dts;
    }
    if (!o->is_network) return file_write(o, s, p);
    return av_interleaved_write_frame(s->oc, p);
}

static void afifo_clear_all(mc_output *o) {
    mc_afifo_clear(&o->afifo);
    o->audio_dropped = 0;
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

/* "prores" = 422 standard; "prores_proxy" / "prores_lt" / "prores_hq" pick the ProRes profile. */
static int is_prores_name(const char *vc) { return vc && strncmp(vc, "prores", 6) == 0; }
static const char *prores_profile(const char *vc) {
    if (vc && strcmp(vc, "prores_proxy") == 0) return "proxy";
    if (vc && strcmp(vc, "prores_lt") == 0) return "lt";
    if (vc && strcmp(vc, "prores_hq") == 0) return "hq";
    return "standard";
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
        // video_kbps < 0 = constant quality (VideoToolbox 1–100, Apple Silicon): intra-only replay
        // otherwise undershoots its bitrate target and looks soft (measured: 35 → 25 Mb/s).
        int cq = !is_prores && o->cfg.video_kbps < 0 && strstr(name, "videotoolbox") ? -o->cfg.video_kbps : 0;
        if (cq > 0) {
            c->flags |= AV_CODEC_FLAG_QSCALE;
            c->global_quality = FF_QP2LAMBDA * (cq > 100 ? 100 : cq);
        } else if (!is_prores) {
            int64_t kb = o->cfg.video_kbps > 0 ? o->cfg.video_kbps : (o->cfg.video_kbps < 0 ? 40000 : 6000);
            int64_t br = kb * 1000;
            c->bit_rate = br;
            c->rc_max_rate = br;
            c->rc_buffer_size = (int)(br * (o->is_network ? 1 : 2));
            if (o->cfg.cbr && !o->cbr_fallback) c->rc_min_rate = br;
        }
        int want_cbr = o->cfg.cbr && !o->cbr_fallback && cq == 0 && !is_prores;
        if (global_header) c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (strstr(name, "videotoolbox")) {
            av_dict_set(&opts, "realtime", "1", 0);
            av_dict_set(&opts, "allow_sw", "1", 0);
            if (strstr(name, "h264")) av_dict_set(&opts, "profile", "high", 0);
            if (is_prores) av_dict_set(&opts, "profile", prores_profile(o->vcodec), 0);
            if (want_cbr) av_dict_set(&opts, "constant_bit_rate", "1", 0);
        } else if (strcmp(name, "libx264") == 0) {
            av_dict_set(&opts, "preset", "veryfast", 0);
            if (o->is_network) av_dict_set(&opts, "tune", "zerolatency", 0);
            av_dict_set(&opts, "profile", "high", 0);
            if (want_cbr) av_dict_set(&opts, "nal-hrd", "cbr", 0);
        } else if (strcmp(name, "libx265") == 0) {
            av_dict_set(&opts, "preset", "veryfast", 0);
        } else if (strcmp(name, "prores_ks") == 0) {
            av_dict_set(&opts, "profile", prores_profile(o->vcodec), 0);
        }
        int ret = avcodec_open2(c, codec, &opts);
        av_dict_free(&opts);
        if (ret >= 0) return c;
        if (want_cbr) {
            // This Mac/encoder can't do hardware CBR: same encoder as capped VBR (reported once opened).
            avcodec_free_context(&c);
            o->cbr_fallback = 1;
            return try_open_video(o, name, fmts, global_header);
        }
        if (cq > 0) {
            // Constant quality unsupported (older macOS / Intel): same encoder, fixed bitrate.
            avcodec_free_context(&c);
            c = avcodec_alloc_context3(codec);
            if (!c) return NULL;
            c->width = o->cfg.width; c->height = o->cfg.height;
            c->time_base = (AVRational){fps_den, fps_num};
            c->framerate = (AVRational){fps_num, fps_den};
            c->sample_aspect_ratio = (AVRational){1, 1};
            c->pix_fmt = fmts[i];
            if (fmts[i] == AV_PIX_FMT_VIDEOTOOLBOX) c->sw_pix_fmt = AV_PIX_FMT_NV12;
            c->gop_size = gop; c->max_b_frames = 0;
            set_color(c);
            c->bit_rate = c->rc_max_rate = (int64_t)cq * 900 * 1000;   // q65 ≈ 58 Mb/s ceiling
            c->rc_buffer_size = (int)(c->bit_rate * 2);
            if (global_header) c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            AVDictionary *o2 = NULL;
            av_dict_set(&o2, "realtime", "1", 0);
            av_dict_set(&o2, "allow_sw", "1", 0);
            if (strstr(name, "h264")) av_dict_set(&o2, "profile", "high", 0);
            ret = avcodec_open2(c, codec, &o2);
            av_dict_free(&o2);
            if (ret >= 0) return c;
        }
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
        const char *name = is_prores_name(vc0) ? "prores_videotoolbox"
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
    } else if (is_prores_name(vc)) {
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
static void split_finish(mc_output *o, osession *s, int force);
static void keep_clear(osession *s);
static void sink_close(AVFormatContext **poc, int trailer, const char *path, int64_t truncate_to);

static void osession_close(mc_output *o, osession *s, int write_trailer, int keep_queue) {
    if (s->prev) split_finish(o, s, 1);   // stop right after a split: complete the old file too
    free(s->split_pending);
    s->split_pending = NULL;
    // Stopping means stopping now: held (delayed) packets never air. A network reconnect keeps them.
    if (!keep_queue) dq_clear(o);
    else if (o->dq_count > 0 && o->outage_us == 0) o->outage_us = mc_now_us();
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
    if (s->moc) sink_close(&s->moc, write_trailer, NULL, 0);   // backup file
    free(s->path);
    free(s->mpath);
    keep_clear(s);
    free(s->keep);
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

/* Crash-safe .mov/.mp4: write the file as movie fragments (index every ~1 s at a keyframe) instead of
   one index at the end. A crash, force quit or power loss keeps everything up to the last second;
   before, the whole recording was unplayable. Also replaces mp4 +faststart, which rewrote the whole
   file at stop (minutes for long recordings, file destroyed if interrupted). */
static void file_mux_opts(mc_output *o, AVFormatContext *oc, AVDictionary **mopts) {
    const char *muxname = oc->oformat->name;
    if (!o->is_network && (strcmp(muxname, "mp4") == 0 || strcmp(muxname, "mov") == 0)) {
        // Fragments are cut explicitly by the ~1 s checkpoints at video keyframes (file_write), which
        // also tell exactly what is safely on disk (needed to continue on another disk without a gap).
        av_dict_set(mopts, "movflags", "+frag_custom+empty_moov+default_base_moof", 0);
    }
    if (o->is_network && o->cfg.cbr && strcmp(muxname, "mpegts") == 0) {
        // CBR transport stream: null-pad to a fixed rate (video + audio + ~12 % TS/PES overhead).
        int64_t vk = o->cfg.video_kbps > 0 ? o->cfg.video_kbps : 6000;
        int64_t ak = o->cfg.audio_kbps > 0 ? o->cfg.audio_kbps : 160;
        char rate[32];
        snprintf(rate, sizeof(rate), "%lld", (long long)((vk + ak) * 1000 * 112 / 100));
        av_dict_set(mopts, "muxrate", rate, 0);
    }
}

// ---- recording safety: backup mirror, continue on another disk, checkpoints (files only) ----

/* Safety warning: kept for mc_output_last_warning (warning_seq tells the app there is a new one) and
   sent through the status callback without changing the state. */
static void owarn(mc_output *o, const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    pthread_mutex_lock(&o->lock);
    snprintf(o->warning, sizeof(o->warning), "%s", buf);
    o->stats.warning_seq++;
    int state = o->stats.state;
    pthread_mutex_unlock(&o->lock);
    fprintf(stderr, "mc_output: %s\n", buf);
    if (o->status_cb) o->status_cb(o->user, state, buf);
}

static void dir_of(const char *path, char *dir, size_t n) {
    snprintf(dir, n, "%s", path);
    char *sl = strrchr(dir, '/');
    if (!sl) snprintf(dir, n, ".");
    else if (sl == dir) sl[1] = 0;
    else *sl = 0;
}

/* Device of a folder (or of the folder holding a file); -1 if unknown. */
static long long dev_of(const char *path, int is_file) {
    char d[1100];
    if (is_file) dir_of(path, d, sizeof(d)); else snprintf(d, sizeof(d), "%s", path);
    struct stat st;
    return stat(d, &st) == 0 ? (long long)st.st_dev : -1;
}

static int same_volume(const char *file, const char *dir) {
    long long a = dev_of(file, 1), b = dev_of(dir, 0);
    return a >= 0 && a == b;
}

/* Bytes free for us on the volume holding `file` (-1 = unknown). */
static int64_t vol_free(const char *file) {
    char d[1100];
    dir_of(file, d, sizeof(d));
    struct statvfs v;
    if (statvfs(d, &v) != 0) return -1;
    return (int64_t)v.f_bavail * (int64_t)v.f_frsize;
}

/* `dir`/<name of path><suffix>[_n].<ext> that does not exist yet (malloc'd). */
static char *path_in_dir(const char *dir, const char *path, const char *suffix) {
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    const char *dot = strrchr(base, '.');
    int stem = dot ? (int)(dot - base) : (int)strlen(base);
    const char *ext = dot ? dot : "";
    mkdir(dir, 0755);
    char buf[1400];
    for (int n = 1; n < 1000; n++) {
        if (n == 1) snprintf(buf, sizeof(buf), "%s/%.*s%s%s", dir, stem, base, suffix, ext);
        else snprintf(buf, sizeof(buf), "%s/%.*s%s_%d%s", dir, stem, base, suffix, n, ext);
        struct stat st;
        if (stat(buf, &st) != 0) return strdup(buf);
    }
    return NULL;
}

static void keep_clear(osession *s) {
    for (int i = 0; i < s->nkeep; i++) av_packet_free(&s->keep[i].p);
    s->nkeep = 0;
}

static void keep_push(osession *s, const AVPacket *p, AVRational tb) {
    if (s->nkeep == s->ckeep) {
        int nc = s->ckeep ? s->ckeep * 2 : 256;
        kpkt *nk = realloc(s->keep, (size_t)nc * sizeof(*nk));
        if (!nk) return;
        s->keep = nk;
        s->ckeep = nc;
    }
    AVPacket *c = av_packet_clone(p);
    if (!c) return;
    s->keep[s->nkeep].p = c;
    s->keep[s->nkeep].tb = tb;
    s->nkeep++;
}

/* Closes a file muxer; optionally cuts the file back to its last good checkpoint size. */
static void sink_close(AVFormatContext **poc, int trailer, const char *path, int64_t truncate_to) {
    AVFormatContext *oc = *poc;
    if (!oc) return;
    if (trailer) av_write_trailer(oc);
    if (oc->pb) avio_closep(&oc->pb);
    avformat_free_context(oc);
    *poc = NULL;
    if (path && truncate_to > 0 && truncate(path, truncate_to) != 0) { /* best effort */ }
}

/* Writes one timeline packet (time base tb) to a file muxer; `base_us` is subtracted. Takes p. */
static int sink_put(AVFormatContext *oc, AVPacket *p, AVRational tb, int64_t base_us) {
    if (p->stream_index < 0 || p->stream_index >= (int)oc->nb_streams) { av_packet_unref(p); return 0; }
    AVRational stb = oc->streams[p->stream_index]->time_base;
    if (av_cmp_q(tb, stb) != 0) av_packet_rescale_ts(p, tb, stb);
    if (base_us) {
        int64_t off = av_rescale_q(base_us, AV_TIME_BASE_Q, stb);
        if (p->pts != AV_NOPTS_VALUE) p->pts -= off;
        if (p->dts != AV_NOPTS_VALUE) p->dts -= off;
        if (p->dts != AV_NOPTS_VALUE && p->dts < 0) { av_packet_unref(p); return 0; }   // before the takeover
    }
    return av_interleaved_write_frame(oc, p);
}

/* Drains a file muxer to disk (interleaving queue, fragment, avio buffer). Sets *good on success. */
static int sink_flush(AVFormatContext *oc, int64_t *good) {
    int r = av_interleaved_write_frame(oc, NULL);
    if (r >= 0) r = av_write_frame(oc, NULL);   // muxers that can flush (mov fragment, mpegts PES) do so
    if (oc->pb) {
        avio_flush(oc->pb);
        if (r >= 0 && oc->pb->error < 0) r = oc->pb->error;
        if (r >= 0) *good = avio_tell(oc->pb);
    }
    return r < 0 ? r : 0;
}

/* New file muxer at `path` with the same container and streams as `src` (same encoded packets fit). */
static int open_like(mc_output *o, AVFormatContext *src, const char *path, AVFormatContext **out, char *e, int elen) {
    AVFormatContext *oc = NULL;
    *out = NULL;
    int r = avformat_alloc_output_context2(&oc, src->oformat, NULL, path);
    if (r < 0 || !oc) { snprintf(e, (size_t)elen, "alloc"); return -1; }
    for (unsigned i = 0; i < src->nb_streams; i++) {
        AVStream *st = avformat_new_stream(oc, NULL);
        if (!st || avcodec_parameters_copy(st->codecpar, src->streams[i]->codecpar) < 0) {
            avformat_free_context(oc);
            snprintf(e, (size_t)elen, "stream");
            return -1;
        }
        st->time_base = src->streams[i]->time_base;
        st->avg_frame_rate = src->streams[i]->avg_frame_rate;
    }
    r = avio_open2(&oc->pb, path, AVIO_FLAG_WRITE, NULL, NULL);
    if (r >= 0) {
        AVDictionary *mopts = NULL;
        file_mux_opts(o, oc, &mopts);
        r = avformat_write_header(oc, &mopts);
        av_dict_free(&mopts);
        if (r >= 0) avio_flush(oc->pb);
        if (r >= 0 && oc->pb->error < 0) r = oc->pb->error;
    }
    if (r < 0) {
        av_strerror(r, e, (size_t)elen);
        if (oc->pb) { avio_closep(&oc->pb); unlink(path); }
        avformat_free_context(oc);
        return -1;
    }
    *out = oc;
    return 0;
}

static void set_backup_path(mc_output *o, const char *path, int state) {
    pthread_mutex_lock(&o->lock);
    free(o->backup_path);
    o->backup_path = path ? strdup(path) : NULL;
    o->stats.mirror_state = state;
    pthread_mutex_unlock(&o->lock);
}

/* Opens the backup file for s->path / s->oc (session start and every split). */
static void mirror_open(mc_output *o, osession *s) {
    if (!o->mirror_dir || o->is_network || o->cfg.packet_cb || !s->oc || !s->path) return;
    mkdir(o->mirror_dir, 0755);
    if (same_volume(s->path, o->mirror_dir)) {
        set_backup_path(o, NULL, 2);
        owarn(o, "백업 폴더가 녹화 중인 디스크에 있어 백업 녹화를 하지 않음");
        return;
    }
    char *mp = path_in_dir(o->mirror_dir, s->path, "");
    char e[128] = "";
    if (!mp || open_like(o, s->oc, mp, &s->moc, e, sizeof(e)) < 0) {
        fprintf(stderr, "mc_output: backup file %s: %s\n", mp ? mp : "?", e);
        free(mp);
        set_backup_path(o, NULL, 2);
        owarn(o, "백업 녹화 파일을 만들 수 없음 — 주 녹화만 계속");
        return;
    }
    s->mpath = mp;
    s->m_good = avio_tell(s->moc->pb);
    set_backup_path(o, mp, 1);
}

static void mirror_drop(mc_output *o, osession *s, int err) {
    char e[128];
    av_strerror(err, e, sizeof(e));
    fprintf(stderr, "mc_output: backup file %s failed: %s\n", s->mpath ? s->mpath : "?", e);
    sink_close(&s->moc, 0, s->mpath, s->m_good);
    if (!s->is_prev) set_backup_path(o, s->mpath, 2);
    free(s->mpath);
    s->mpath = NULL;
    owarn(o, "백업 녹화 쓰기 실패 — 주 녹화는 계속됨");
}

/* Points the session's stream pointers at the streams of a new main muxer (same layout). */
static void repoint_streams(osession *s, AVFormatContext *oc) {
    if (s->vst) s->vst = oc->streams[s->vst->index];
    if (s->ast) s->ast = oc->streams[s->ast->index];
    for (int i = 0; i < MC_MAX_XTRACKS; i++)
        if (s->xst[i]) s->xst[i] = oc->streams[s->xst[i]->index];
}

static char *spill_target(mc_output *o, const char *cur) {
    if (!o->spill_dir || !cur) return NULL;
    mkdir(o->spill_dir, 0755);
    if (same_volume(cur, o->spill_dir)) return NULL;   // already on the spill disk
    return path_in_dir(o->spill_dir, cur, "_cont");
}

/* The main file failed (err). Keeps recording: the backup file becomes the main file, or a new file on the
   spill disk starts with the packets kept since the last checkpoint. Returns 0, or err if nothing can take over. */
static int main_failover(mc_output *o, osession *s, int err) {
    char e[128];
    av_strerror(err, e, sizeof(e));
    fprintf(stderr, "mc_output: main file %s failed: %s\n", s->path ? s->path : "?", e);
    AVFormatContext *dead = s->oc;
    if (s->moc) {
        // The backup has every packet: it simply becomes the main file.
        repoint_streams(s, s->moc);   // before the dead muxer (and its streams) is freed
        sink_close(&dead, 0, s->path, s->good);
        s->oc = s->moc;
        s->moc = NULL;
        free(s->path);
        s->path = s->mpath;
        s->mpath = NULL;
        s->good = s->m_good;
        s->base_us = 0;
        keep_clear(s);
        pthread_mutex_lock(&o->lock);
        o->stats.main_failed = 1;
        o->stats.mirror_state = 0;
        free(o->backup_path);
        o->backup_path = NULL;
        if (!s->is_prev) { free(o->cur_path); o->cur_path = strdup(s->path); }
        pthread_mutex_unlock(&o->lock);
        owarn(o, "녹화 디스크 쓰기 실패 — 백업 디스크에 계속 녹화 중");
        return 0;
    }
    char *sp = !s->is_prev ? spill_target(o, s->path) : NULL;
    AVFormatContext *nc = NULL;
    char e2[128] = "";
    if (sp && open_like(o, dead, sp, &nc, e2, sizeof(e2)) == 0) {
        repoint_streams(s, nc);
        sink_close(&dead, 0, s->path, s->good);
        s->oc = nc;
        free(s->path);
        s->path = sp;
        s->good = avio_tell(nc->pb);
        // The new file starts at 0 with the oldest packet not safely in the old file.
        int64_t base = INT64_MAX;
        for (int i = 0; i < s->nkeep; i++) {
            AVPacket *k = s->keep[i].p;
            int64_t t = k->dts != AV_NOPTS_VALUE ? k->dts : k->pts;
            if (t != AV_NOPTS_VALUE) { t = av_rescale_q(t, s->keep[i].tb, AV_TIME_BASE_Q); if (t < base) base = t; }
        }
        s->base_us = base == INT64_MAX ? INT64_MIN : base;
        int r = 0;
        for (int i = 0; i < s->nkeep && r >= 0; i++) {
            AVPacket *c = av_packet_clone(s->keep[i].p);
            r = c ? sink_put(nc, c, s->keep[i].tb, s->base_us == INT64_MIN ? 0 : s->base_us) : AVERROR(ENOMEM);
            av_packet_free(&c);
        }
        if (r >= 0) r = sink_flush(nc, &s->good);
        if (r < 0) return r;
        keep_clear(s);
        pthread_mutex_lock(&o->lock);
        o->stats.spills++;
        free(o->cur_path);
        o->cur_path = strdup(s->path);
        pthread_mutex_unlock(&o->lock);
        owarn(o, "녹화 디스크 쓰기 실패 — 다른 디스크에 이어서 녹화 중");
        return 0;
    }
    if (sp) fprintf(stderr, "mc_output: spill file %s: %s\n", sp, e2);
    free(sp);
    if (s->is_prev) {
        // old file being finished after a split: lose only its tail, the recording itself goes on
        sink_close(&s->oc, 0, s->path, s->good);
        owarn(o, "이전 녹화 파일 마무리 중 쓰기 실패");
        return 0;
    }
    return err;
}

/* Free space check (~1×/s, at checkpoints): below the reserve, continue on the spill disk by a seamless split. */
static void space_check(mc_output *o, osession *s) {
    if (s->is_prev || !s->path || s->prev || s->split_pending || o->cfg.spill_reserve_bytes <= 0) return;
    if (o->cfg.delay_ms > 0 && !o->delay_off) return;   // held packets can't straddle files (see mc_output_split)
    int64_t fr = vol_free(s->path);
    if (fr < 0 || fr >= o->cfg.spill_reserve_bytes) return;
    char *sp = spill_target(o, s->path);
    if (!sp) {
        if (!o->spill_warned) owarn(o, "녹화 디스크 공간 부족 — 이어서 녹화할 다른 디스크가 없음");
        o->spill_warned = 1;
        return;
    }
    if (vol_free(sp) < o->cfg.spill_reserve_bytes) {   // the other disk is not better off
        free(sp);
        if (!o->spill_warned) owarn(o, "녹화 디스크 공간 부족 — 다른 디스크도 공간 부족");
        o->spill_warned = 1;
        return;
    }
    s->split_pending = sp;
    s->split_waits = 0;
    o->spill_split = 1;
}

/* Checkpoint: everything written so far is on disk in both files (or a failure was handled). */
static int checkpoint(mc_output *o, osession *s) {
    if (s->moc) {
        int r = sink_flush(s->moc, &s->m_good);
        if (r < 0) mirror_drop(o, s, r);
    }
    if (s->oc) {
        int r = sink_flush(s->oc, &s->good);
        if (r < 0) return main_failover(o, s, r);
    }
    keep_clear(s);
    space_check(o, s);
    return 0;
}

static int file_write(mc_output *o, osession *s, AVPacket *p) {
    if (!s->oc || p->stream_index < 0 || p->stream_index >= (int)s->oc->nb_streams) {   // old file that failed
        av_packet_unref(p);
        return 0;
    }
    AVRational tb = s->oc->streams[p->stream_index]->time_base;
    if (s->vst && p->stream_index == s->vst->index && (p->flags & AV_PKT_FLAG_KEY) && p->dts != AV_NOPTS_VALUE) {
        int64_t t = av_rescale_q(p->dts, tb, AV_TIME_BASE_Q);
        if (s->ck_us == INT64_MIN || t - s->ck_us >= 1000000) {   // new fragment at this keyframe
            s->ck_us = t;
            int r = checkpoint(o, s);
            if (r < 0) { av_packet_unref(p); return r; }
            if (!s->oc) { av_packet_unref(p); return 0; }
            // (p keeps its time base tb; sink_put rescales if a file that took over differs)
        }
    }
    if (o->spill_dir && !s->is_prev) keep_push(s, p, tb);
    if (s->moc) {
        AVPacket *m = av_packet_clone(p);
        int r = m ? sink_put(s->moc, m, tb, 0) : AVERROR(ENOMEM);
        av_packet_free(&m);
        if (r < 0) mirror_drop(o, s, r);
    }
    if (s->base_us == INT64_MIN) {   // spill file that took over with nothing kept: starts here
        int64_t t = p->dts != AV_NOPTS_VALUE ? p->dts : p->pts;
        s->base_us = t != AV_NOPTS_VALUE ? av_rescale_q(t, tb, AV_TIME_BASE_Q) : 0;
    }
    int r = sink_put(s->oc, p, tb, s->base_us);
    if (r < 0) r = main_failover(o, s, r);
    return r;
}

static int osession_open(mc_output *o, osession *s, char *err, int errlen) {
    memset(s, 0, sizeof(*s));
    s->ck_us = INT64_MIN;
    for (size_t i = 0; i < sizeof(s->last_dts) / sizeof(s->last_dts[0]); i++) s->last_dts[i] = INT64_MIN;
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
    if (o->cfg.cbr && o->cbr_fallback == 1) {   // once per output, not on every reconnect
        o->cbr_fallback = 2;
        owarn(o, "CBR 미지원 인코더 — VBR(최대값 고정)로 송출 중");
    }
    int pcm = is_prores_name(o->vcodec) &&
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
        if (!o->is_network) s->path = strdup(o->url);
        if (ret < 0 && !o->is_network && o->mirror_dir && !o->cfg.packet_cb) {
            // main disk unusable: record to the backup folder instead (no mirror then)
            mkdir(o->mirror_dir, 0755);
            char *bp = same_volume(o->url, o->mirror_dir) ? NULL : path_in_dir(o->mirror_dir, o->url, "");
            if (bp && avio_open2(&s->oc->pb, bp, AVIO_FLAG_WRITE, &s->oc->interrupt_callback, NULL) >= 0) {
                free(s->path);
                s->path = bp;
                ret = 0;
                pthread_mutex_lock(&o->lock);
                o->stats.main_failed = 1;
                free(o->cur_path);
                o->cur_path = strdup(bp);
                pthread_mutex_unlock(&o->lock);
                owarn(o, "녹화 파일을 만들 수 없어 백업 폴더에 녹화 중");
            } else {
                free(bp);
            }
        }
        if (ret < 0) {
            char e[128];
            av_strerror(ret, e, sizeof(e));
            snprintf(err, errlen, o->is_network ? "연결 실패: %s" : "녹화 파일을 만들 수 없음: %s", e);
            return -1;
        }
    }
    AVDictionary *mopts = NULL;
    file_mux_opts(o, s->oc, &mopts);
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
    if (s->path && s->oc->pb) {
        s->good = avio_tell(s->oc->pb);
        pthread_mutex_lock(&o->lock);
        int main_ok = !o->stats.main_failed;
        pthread_mutex_unlock(&o->lock);
        if (main_ok) mirror_open(o, s);
    }
    pthread_mutex_lock(&o->lock);
    snprintf(o->stats.encoder, sizeof(o->stats.encoder), "%s", s->venc->codec->name);
    pthread_mutex_unlock(&o->lock);
    return 0;
}

// ---- broadcast delay queue (output thread) ----
#ifndef SPOOL_SEG_US
#define SPOOL_SEG_US   (60LL * 1000000)       // new segment file every minute …
#endif
#define SPOOL_SEG_MAX  (512LL * 1024 * 1024)  // … or every 512 MB

static void spool_path(mc_output *o, int seg, char *buf, size_t n) {
    snprintf(buf, n, "%s/seg%06d.bin", o->spool_dir, seg);
}

static int spool_open(mc_output *o) {
    if (o->spool_dir || o->spool_failed || !o->cfg.delay_dir || !o->cfg.delay_dir[0]) return o->spool_dir != NULL;
    char d[1024];
    snprintf(d, sizeof(d), "%s/HongMix-delay-%d-%lld", o->cfg.delay_dir, (int)getpid(), (long long)mc_now_us());
    mkdir(o->cfg.delay_dir, 0755);
    if (mkdir(d, 0700) != 0 && errno != EEXIST) {
        o->spool_failed = 1;
        if (o->status_cb) o->status_cb(o->user, MC_STATE_RUNNING, "딜레이: 디스크 버퍼 폴더를 만들 수 없어 메모리로 진행");
        return 0;
    }
    o->spool_dir = strdup(d);
    o->w_fd = o->r_fd = -1;
    o->w_seg = o->r_seg = o->low_seg = 0;
    o->w_off = 0;
    o->w_seg_t0 = 0;
    return 1;
}

/* Deletes segment files nobody needs any more (everything before the oldest held disk packet). */
static void spool_gc(mc_output *o) {
    if (!o->spool_dir) return;
    int keep = o->w_fd >= 0 ? o->w_seg : o->w_seg + 1;
    for (int i = 0; i < o->dq_count; i++) {
        dq_ent *e = &o->dq[(o->dq_head + i) % o->dq_cap];
        if (!e->mem) { keep = e->seg; break; }
    }
    char path[1100];
    while (o->low_seg < keep) {
        if (o->r_fd >= 0 && o->r_seg == o->low_seg) { close(o->r_fd); o->r_fd = -1; }
        spool_path(o, o->low_seg, path, sizeof(path));
        unlink(path);
        o->low_seg++;
    }
}

static void spool_close(mc_output *o) {
    if (!o->spool_dir) return;
    if (o->w_fd >= 0) close(o->w_fd);
    if (o->r_fd >= 0) close(o->r_fd);
    o->w_fd = o->r_fd = -1;
    char path[1100];
    for (int i = o->low_seg; i <= o->w_seg; i++) { spool_path(o, i, path, sizeof(path)); unlink(path); }
    rmdir(o->spool_dir);
    free(o->spool_dir);
    o->spool_dir = NULL;
    o->disk_bytes = 0;
    free(o->rbuf);
    o->rbuf = NULL;
    o->rbuf_cap = 0;
}

/* Appends the packet data to the current segment. 0 = ok (e filled), -1 = keep it in RAM. */
static int spool_write(mc_output *o, const AVPacket *pkt, dq_ent *e) {
    if (!spool_open(o)) return -1;
    int64_t now = mc_now_us();
    if (o->w_fd >= 0 && (now - o->w_seg_t0 >= SPOOL_SEG_US || o->w_off >= SPOOL_SEG_MAX)) {
        close(o->w_fd);
        o->w_fd = -1;
        o->w_seg++;
    }
    if (o->w_fd < 0) {
        char path[1100];
        spool_path(o, o->w_seg, path, sizeof(path));
        o->w_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        o->w_off = 0;
        o->w_seg_t0 = now;
        if (o->w_fd < 0) goto fail;
    }
    {
        const uint8_t *p = pkt->data;
        int left = pkt->size;
        while (left > 0) {
            ssize_t n = write(o->w_fd, p, (size_t)left);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) goto fail;
            p += n; left -= (int)n;
        }
    }
    e->mem = NULL;
    e->off = o->w_off;
    e->seg = o->w_seg;
    o->w_off += pkt->size;
    o->disk_bytes += pkt->size;
    return 0;
fail:
    // disk full / unplugged: from here on the delay is held in RAM (what is already on disk still airs)
    if (o->w_fd >= 0 && ftruncate(o->w_fd, o->w_off) != 0) { /* best effort */ }
    o->spool_failed = 1;
    if (o->status_cb) o->status_cb(o->user, MC_STATE_RUNNING, "딜레이: 디스크 공간 부족 또는 쓰기 실패 — 이후 구간은 메모리로 계속");
    return -1;
}

/* Reads a spooled packet back. NULL = lost (read error). */
static AVPacket *spool_read(mc_output *o, const dq_ent *e) {
    if (o->r_fd < 0 || o->r_seg != e->seg) {
        if (o->r_fd >= 0) close(o->r_fd);
        char path[1100];
        spool_path(o, e->seg, path, sizeof(path));
        o->r_fd = open(path, O_RDONLY);
        o->r_seg = e->seg;
        if (o->r_fd < 0) return NULL;
    }
    AVPacket *p = av_packet_alloc();
    if (!p || av_new_packet(p, e->size) < 0) { av_packet_free(&p); return NULL; }
    int got = 0;
    while (got < e->size) {
        ssize_t n = pread(o->r_fd, p->data + got, (size_t)(e->size - got), e->off + got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { av_packet_free(&p); return NULL; }
        got += (int)n;
    }
    p->pts = e->pts; p->dts = e->dts; p->duration = e->duration;
    p->stream_index = e->stream_index; p->flags = e->flags;
    return p;
}

static void dq_push(mc_output *o, AVPacket *pkt, AVRational tb, int64_t release) {
    if (o->dq_count == o->dq_cap) {
        int nc = o->dq_cap ? o->dq_cap * 2 : 4096;
        dq_ent *nq = calloc(nc, sizeof(*nq));
        for (int i = 0; i < o->dq_count; i++) nq[i] = o->dq[(o->dq_head + i) % o->dq_cap];
        free(o->dq);
        o->dq = nq; o->dq_head = 0; o->dq_cap = nc;
    }
    int t = (o->dq_head + o->dq_count) % o->dq_cap;
    dq_ent *e = &o->dq[t];
    memset(e, 0, sizeof(*e));
    e->tb = tb;
    e->release = release;
    e->pts = pkt->pts; e->dts = pkt->dts; e->duration = pkt->duration;
    e->size = pkt->size; e->stream_index = pkt->stream_index; e->flags = pkt->flags;
    // side data (rare: encoder parameter changes) only survives in RAM
    int disk = o->cfg.delay_dir && o->cfg.delay_dir[0] && !o->spool_failed && pkt->side_data_elems == 0;
    if (!disk || spool_write(o, pkt, e) != 0) e->mem = av_packet_clone(pkt);
    o->dq_count++;
}

/* Removes the head entry; returns its packet (caller frees) or NULL when only dropping. */
static AVPacket *dq_pop(mc_output *o, int want) {
    dq_ent *e = &o->dq[o->dq_head];
    AVPacket *p = NULL;
    if (e->mem) {
        if (want) p = e->mem; else av_packet_free(&e->mem);
        e->mem = NULL;
    } else {
        if (want) p = spool_read(o, e);
        o->disk_bytes -= e->size;
    }
    o->dq_head = (o->dq_head + 1) % o->dq_cap;
    o->dq_count--;
    return p;
}

static void dq_clear(mc_output *o) {
    while (o->dq_count > 0) dq_pop(o, 0);
    spool_close(o);
}

/* Writes held packets whose time has come. `all` = write everything. Handles a pending dump. */
static int dq_flush(mc_output *o, osession *s, int all) {
    if (atomic_exchange(&o->dump_req, 0) && o->dq_count > 0) {
        // keep from the newest video keyframe on (decoders need one), drop the rest, go live
        int keep_from = -1;
        for (int i = o->dq_count - 1; i >= 0; i--) {
            dq_ent *e = &o->dq[(o->dq_head + i) % o->dq_cap];
            if (s->vst && e->stream_index == s->vst->index && (e->flags & AV_PKT_FLAG_KEY)) { keep_from = i; break; }
        }
        int drop = keep_from < 0 ? o->dq_count : keep_from;
        for (int i = 0; i < drop; i++) dq_pop(o, 0);
        o->delay_off = 1;
        all = 1;
        spool_gc(o);
    }
    int64_t now = mc_now_us();
    int popped = 0;
    while (o->dq_count > 0 && (all || o->dq[o->dq_head].release <= now)) {
        AVRational etb = o->dq[o->dq_head].tb;
        AVPacket *p = dq_pop(o, 1);
        if (p && (p->stream_index < 0 || p->stream_index >= (int)s->oc->nb_streams)) av_packet_free(&p);
        if (p) {   // held from an earlier session: its time base may differ from this muxer's
            AVRational stb = s->oc->streams[p->stream_index]->time_base;
            if (etb.den > 0 && av_cmp_q(etb, stb) != 0) av_packet_rescale_ts(p, etb, stb);
        }
        popped = 1;
        if (!p) {   // unreadable from disk: skip it (decoder recovers at the next keyframe)
            pthread_mutex_lock(&o->lock);
            o->stats.frames_dropped++;
            pthread_mutex_unlock(&o->lock);
            continue;
        }
        int size = p->size;
        o->io_deadline_us = o->is_network ? mc_now_us() + 5000000 : 0;
        int ret = mux_write(o, s, p);
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
    if (popped) spool_gc(o);
    pthread_mutex_lock(&o->lock);
    o->stats.delay_buffered_ms = o->dq_count > 0
        ? (int)((o->cfg.delay_ms > 0 ? o->cfg.delay_ms : 0) - (o->dq[o->dq_head].release - now) / 1000) : 0;
    if (o->stats.delay_buffered_ms < 0) o->stats.delay_buffered_ms = 0;
    o->stats.delay_on_disk = o->spool_dir != NULL && !o->spool_failed;
    o->stats.delay_disk_bytes = o->disk_bytes;
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
        if (o->cfg.packet_cb) {
            // instant replay: hand the encoded frame to the replay store instead of muxing it
            if (st == s->vst)
                o->cfg.packet_cb(o->cfg.packet_user, pkt->data, pkt->size, pkt->pts + o->base_tick,
                                 (pkt->flags & AV_PKT_FLAG_KEY) != 0);
            pthread_mutex_lock(&o->lock);
            o->stats.bytes_written += pkt->size;
            pthread_mutex_unlock(&o->lock);
            av_packet_unref(pkt);
            continue;
        }
        osession *dst = s;   // muxer this packet goes to
        AVStream *dst_st = st;
        if (enc == s->venc && s->venc) {
            // After a split, video packets of frames before the cut still belong to the old file.
            // No B-frames: packets come out in input order, so the first one at/after the cut ends it.
            if (s->prev && !s->prev_vdone && pkt->pts != AV_NOPTS_VALUE && pkt->pts < s->cut_v) {
                dst = s->prev;
                dst_st = s->prev->vst;
            } else if (s->prev) {
                s->prev_vdone = 1;
            }
            if (dst->v_off) {   // rebase: each file's video starts at 0
                if (pkt->pts != AV_NOPTS_VALUE) pkt->pts -= dst->v_off;
                if (pkt->dts != AV_NOPTS_VALUE) pkt->dts -= dst->v_off;
            }
        }
        st = dst_st;
        av_packet_rescale_ts(pkt, enc->time_base, st->time_base);
        pkt->stream_index = st->index;
        if (o->ts_offset_us) {      // continue the timeline of the held packets from before a reconnect
            int64_t off = av_rescale_q(o->ts_offset_us, AV_TIME_BASE_Q, st->time_base);
            if (pkt->pts != AV_NOPTS_VALUE) pkt->pts += off;
            if (pkt->dts != AV_NOPTS_VALUE) pkt->dts += off;
        }
        {
            int64_t t = pkt->dts != AV_NOPTS_VALUE ? pkt->dts : pkt->pts;
            if (pkt->pts != AV_NOPTS_VALUE && pkt->pts > t) t = pkt->pts;
            if (t != AV_NOPTS_VALUE) {
                int64_t end = av_rescale_q(t + (pkt->duration > 0 ? pkt->duration : 0), st->time_base, AV_TIME_BASE_Q);
                if (end > o->content_end_us) o->content_end_us = end;
            }
        }
        int size = pkt->size;
        if (o->cfg.delay_ms > 0 && !o->delay_off) {
            // broadcast delay: hold the encoded packet (RAM, or disk segments for long delays; no re-encode, no quality loss)
            dq_push(o, pkt, st->time_base, mc_now_us() + (int64_t)o->cfg.delay_ms * 1000);
            av_packet_unref(pkt);
            ret = dq_flush(o, s, 0);
            if (ret < 0) break;
            continue;
        }
        o->io_deadline_us = o->is_network ? mc_now_us() + 5000000 : 0;
        ret = mux_write(o, dst, pkt);
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
        if (s->force_key) {   // split point: VideoToolbox maps this to kVTEncodeFrameOptionKey_ForceKeyFrame
            f->pict_type = AV_PICTURE_TYPE_I;
            s->force_key = 0;
        }
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
    if (s->force_key) {   // split point (libx264: IDR with the default closed GOP)
        f->pict_type = AV_PICTURE_TYPE_I;
        s->force_key = 0;
    }
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


// ---- seamless file split (files only; see osession) ----

/* Opens the next file with the running video encoder's parameters and fresh audio encoders, then moves
   the current file into s->prev. cut_v = pts of the frame about to be encoded (as a keyframe). */
static int split_begin(mc_output *o, osession *s, const char *path, int64_t cut_v) {
    osession *n = (osession *)calloc(1, sizeof(*n));
    if (!n) return -1;
    for (size_t i = 0; i < sizeof(n->last_dts) / sizeof(n->last_dts[0]); i++) n->last_dts[i] = INT64_MIN;
    const char *fmtname = o->format && o->format[0] ? o->format : guess_format(path);
    char e[128] = "";
    int ok = avformat_alloc_output_context2(&n->oc, NULL, fmtname, path) >= 0 && n->oc;
    int gh = ok && (n->oc->oformat->flags & AVFMT_GLOBALHEADER) ? 1 : 0;
    int pcm = s->aenc && s->aenc->codec_id == AV_CODEC_ID_PCM_S16LE;
    if (ok) {
        n->vst = avformat_new_stream(n->oc, NULL);
        n->aenc = open_audio_encoder(o, pcm, gh);
        n->ast = n->aenc ? avformat_new_stream(n->oc, NULL) : NULL;
        ok = n->vst && n->ast;
    }
    if (ok) {
        avcodec_parameters_from_context(n->vst->codecpar, s->venc);   // same encoder, same extradata
        n->vst->time_base = s->venc->time_base;
        n->vst->avg_frame_rate = s->venc->framerate;
        avcodec_parameters_from_context(n->ast->codecpar, n->aenc);
        n->ast->time_base = n->aenc->time_base;
        for (int i = 0; i < o->nx && ok; i++) {
            n->xenc[i] = open_audio_encoder(o, pcm, gh);
            n->xst[i] = n->xenc[i] ? avformat_new_stream(n->oc, NULL) : NULL;
            if (!n->xst[i]) { ok = 0; break; }
            avcodec_parameters_from_context(n->xst[i]->codecpar, n->xenc[i]);
            n->xst[i]->time_base = n->xenc[i]->time_base;
        }
    }
    if (ok && !(n->oc->oformat->flags & AVFMT_NOFILE)) {
        int r = avio_open2(&n->oc->pb, path, AVIO_FLAG_WRITE, NULL, NULL);
        if (r < 0) { av_strerror(r, e, sizeof(e)); ok = 0; }
    }
    if (ok) {
        AVDictionary *mopts = NULL;
        file_mux_opts(o, n->oc, &mopts);
        int r = avformat_write_header(n->oc, &mopts);
        av_dict_free(&mopts);
        if (r < 0) { av_strerror(r, e, sizeof(e)); ok = 0; }
    }
    if (!ok) {
        fprintf(stderr, "mc_output: split to %s failed: %s\n", path, e);
        if (n->oc) {
            if (n->oc->pb) {   // opened but the header failed: don't leave an empty file behind
                avio_closep(&n->oc->pb);
                unlink(path);
            }
            avformat_free_context(n->oc);
        }
        if (n->aenc) avcodec_free_context(&n->aenc);
        for (int i = 0; i < MC_MAX_XTRACKS; i++) if (n->xenc[i]) avcodec_free_context(&n->xenc[i]);
        free(n);
        o->spill_split = 0;
        return -1;
    }
    // Recording safety: the new file gets its own backup file (both files split together).
    n->path = strdup(path);
    n->good = n->oc->pb ? avio_tell(n->oc->pb) : 0;
    n->ck_us = INT64_MIN;
    if (o->mirror_dir && !o->is_network) {
        if (o->spill_split && same_volume(path, o->mirror_dir)) {
            // continuing on the backup disk: that file is now the recording itself, no second copy there
            set_backup_path(o, NULL, 0);
            owarn(o, "백업 디스크에 이어서 녹화 — 백업 녹화는 중지");
        } else {
            mirror_open(o, n);
        }
    }
    // Swap: n becomes the old file (muxer + its audio encoders), s continues with the new file.
#define SWAPF(f) do { __typeof__(s->f) t_ = s->f; s->f = n->f; n->f = t_; } while (0)
    SWAPF(oc); SWAPF(vst); SWAPF(ast); SWAPF(aenc); SWAPF(audio_pts); SWAPF(v_off);
    for (int i = 0; i < MC_MAX_XTRACKS; i++) { SWAPF(xenc[i]); SWAPF(xst[i]); SWAPF(xpts[i]); }
    for (size_t i = 0; i < sizeof(s->last_dts) / sizeof(s->last_dts[0]); i++) SWAPF(last_dts[i]);
    SWAPF(path); SWAPF(good); SWAPF(base_us); SWAPF(moc); SWAPF(mpath); SWAPF(m_good); SWAPF(ck_us);
#undef SWAPF
    keep_clear(s);    // kept packets belonged to the old file
    n->is_prev = 1;
    if (o->spill_split) {
        o->spill_split = 0;
        pthread_mutex_lock(&o->lock);
        o->stats.spills++;
        pthread_mutex_unlock(&o->lock);
        owarn(o, "녹화 디스크 공간 부족 — 다른 디스크에 이어서 녹화 중");
    }
    n->achunk_frames = s->achunk_frames;
    s->audio_pts = 0;
    for (int i = 0; i < MC_MAX_XTRACKS; i++) s->xpts[i] = 0;
    s->v_off = cut_v;
    s->prev = n;
    s->cut_v = cut_v;
    s->cut_a = av_rescale(cut_v, (int64_t)MC_AUDIO_RATE * o->cfg.fps_den, o->cfg.fps_num);
    s->prev_vdone = s->prev_adone = 0;
    s->prev_t0 = mc_now_us();
    s->force_key = 1;
    pthread_mutex_lock(&o->lock);
    free(o->cur_path);
    o->cur_path = strdup(path);
    pthread_mutex_unlock(&o->lock);
    return 0;
}

/* The old file's audio reached the cut: flush its encoders (the last frame may have been short). */
static void split_finish_audio(mc_output *o, osession *s) {
    osession *p = s->prev;
    if (!p || s->prev_adone) return;
    if (p->aenc) { avcodec_send_frame(p->aenc, NULL); write_packets(o, p, p->aenc, p->ast); }
    for (int i = 0; i < MC_MAX_XTRACKS; i++)
        if (p->xenc[i]) { avcodec_send_frame(p->xenc[i], NULL); write_packets(o, p, p->xenc[i], p->xst[i]); }
    s->prev_adone = 1;
    // New file's audio starts at the cut (later only if the FIFO dropped samples across it).
    int64_t start = s->atl > s->cut_a ? s->atl - s->cut_a : 0;
    s->audio_pts = start;
    for (int i = 0; i < o->nx; i++) s->xpts[i] = start;
}

/* Closes the old file once both its video and audio are complete (or `force`, at stop). */
static void split_finish(mc_output *o, osession *s, int force) {
    osession *p = s->prev;
    if (!p) return;
    // Normally when both halves are complete; if audio stopped arriving, don't hold the old file open.
    int timed_out = s->prev_vdone && mc_now_us() - s->prev_t0 > 3000000;
    if (!force && !(s->prev_vdone && s->prev_adone) && !timed_out) return;
    split_finish_audio(o, s);
    if (p->oc) sink_close(&p->oc, 1, NULL, 0);
    if (p->moc) sink_close(&p->moc, 1, NULL, 0);   // its backup file
    free(p->path);
    free(p->mpath);
    keep_clear(p);
    free(p->keep);
    if (p->aenc) avcodec_free_context(&p->aenc);
    for (int i = 0; i < MC_MAX_XTRACKS; i++) if (p->xenc[i]) avcodec_free_context(&p->xenc[i]);
    free(p);
    s->prev = NULL;
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
            osession_close(o, &s, 0, o->is_network && o->cfg.reconnect);
            if (atomic_load(&o->stop)) break;
            ostatus(o, MC_STATE_ERROR, "%s", err);
            if (!(o->is_network && o->cfg.reconnect)) {
                // Keep the ERROR visible: falling through to the final "중지됨" (STOPPED) made a recording
                // that never opened (disk full, no write access, encoder failure) look like it was running.
                free(local);
                return NULL;
            }
            attempt++;
            int64_t until = mc_now_us() + (attempt < 3 ? 2000000 : 5000000);
            while (!atomic_load(&o->stop) && mc_now_us() < until) mc_sleep_us(50000);
            continue;
        }
        attempt = 0;
        if (o->dq_count > 0 && o->outage_us > 0) {
            // Reconnected with held packets: air them from where airing stopped. Move every release time
            // by the outage length (the delay stays the same), start at a video keyframe (the receiver
            // needs one on a new connection), and continue the timeline after the held packets.
            int64_t shift = mc_now_us() - o->outage_us;
            int vi = s.vst ? s.vst->index : -1;
            while (o->dq_count > 0) {
                dq_ent *h = &o->dq[o->dq_head];
                if (vi < 0 || (h->stream_index == vi && (h->flags & AV_PKT_FLAG_KEY))) break;
                dq_pop(o, 0);
            }
            for (int i = 0; i < o->dq_count; i++) o->dq[(o->dq_head + i) % o->dq_cap].release += shift;
            o->ts_offset_us = o->content_end_us;
        }
        o->outage_us = 0;
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
            if (o->split_req) {
                o->spill_split = 0;   // an explicit split replaces a pending spill (re-checked at the next checkpoint)
                free(s.split_pending);
                s.split_pending = o->split_req;
                o->split_req = NULL;
                s.split_waits = 0;
            }
            pthread_mutex_unlock(&o->lock);

            int ret = 0;
            if (have_video && (pb || have_bgra) && s.split_pending && !s.prev) {
                // Cut on this frame unless the audio already went past its instant (then the old file
                // would get audio beyond its last picture); a frame or two later it is in line again.
                int64_t at = av_rescale(pts, (int64_t)MC_AUDIO_RATE * o->cfg.fps_den, o->cfg.fps_num);
                if (at >= s.atl || ++s.split_waits > 15) {
                    char *path = s.split_pending;
                    s.split_pending = NULL;
                    if (split_begin(o, &s, path, pts) < 0)
                        ostatus(o, MC_STATE_RUNNING, "다음 녹화 파일을 열 수 없어 현재 파일에 계속 녹화 중");
                    free(path);
                }
            }
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
                int64_t skipped = o->audio_dropped;   // dropped samples were older than what we read now
                o->audio_dropped = 0;
                // After a split the old file takes audio up to the cut sample, the new one from there on.
                osession *as = (s.prev && !s.prev_adone) ? s.prev : &s;
                if (skipped > 0) {
                    as->audio_pts += skipped;
                    for (int i = 0; i < o->nx; i++) as->xpts[i] += skipped;   // extra tracks drop in lockstep
                    s.atl += skipped;
                }
                int want = s.achunk_frames;
                if (as != &s) {
                    int64_t left = s.cut_a - s.atl;
                    if (left < want) want = (int)(left > 0 ? left : 0);
                }
                if (want > 0 && o->afifo.count >= want) {
                    got = mc_afifo_read(&o->afifo, s.achunk, want);
                    for (int i = 0; i < o->nx; i++) {
                        float *dst = s.xchunk + (size_t)i * s.achunk_frames * 2;
                        int gx = mc_afifo_read(&o->xfifo[i], dst, got);
                        if (gx < got) memset(dst + gx * 2, 0, (size_t)(got - gx) * 2 * sizeof(float));
                    }
                }
                pthread_mutex_unlock(&o->lock);
                if (as != &s && s.atl >= s.cut_a) {   // old file's audio is complete
                    split_finish_audio(o, &s);
                    continue;
                }
                if (!got) break;
                ret = encode_audio_to(o, as, as->aenc, as->ast, &as->audio_pts, s.achunk, got);
                for (int i = 0; i < o->nx && ret >= 0; i++)
                    ret = encode_audio_to(o, as, as->xenc[i], as->xst[i], &as->xpts[i],
                                          s.xchunk + (size_t)i * s.achunk_frames * 2, got);
                s.atl += got;
            }
            if (s.prev) split_finish(o, &s, 0);
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
        osession_close(o, &s, !failed || !o->is_network,
                       failed && o->is_network && o->cfg.reconnect && !atomic_load(&o->stop));
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
    o->cfg.delay_dir = cfg->delay_dir && cfg->delay_dir[0] ? strdup(cfg->delay_dir) : NULL;
    o->cur_path = strdup(cfg->url);
    o->mirror_dir = cfg->mirror_dir && cfg->mirror_dir[0] ? strdup(cfg->mirror_dir) : NULL;
    o->spill_dir = cfg->spill_dir && cfg->spill_dir[0] ? strdup(cfg->spill_dir) : NULL;
    o->cfg.mirror_dir = o->mirror_dir;
    o->cfg.spill_dir = o->spill_dir;
    o->w_fd = o->r_fd = -1;
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
        free(o->cur_path);
        free((char *)o->cfg.delay_dir);
        free(o->mirror_dir);
        free(o->spill_dir);
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
        o->audio_dropped += mc_afifo_write(&o->afifo, stereo, frames);
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
    free(o->split_req);
    free(o->cur_path);
    free((char *)o->cfg.delay_dir);
    free(o->mirror_dir);
    free(o->spill_dir);
    free(o->backup_path);
    free(o);
}

int mc_output_split(mc_output *o, const char *new_path) {
    // Files only: a stream has no file to split, and held (delayed) packets would straddle the files.
    if (!o || !new_path || !new_path[0] || o->is_network || o->cfg.packet_cb || o->cfg.delay_ms > 0) return -1;
    pthread_mutex_lock(&o->lock);
    int ok = o->accepting && o->stats.state == MC_STATE_RUNNING;
    if (ok) {
        free(o->split_req);
        o->split_req = strdup(new_path);
        ok = o->split_req != NULL;
        pthread_cond_signal(&o->cond);
    }
    pthread_mutex_unlock(&o->lock);
    return ok ? 0 : -1;
}

int mc_output_current_file(mc_output *o, char *buf, int len) {
    if (!o || !buf || len <= 0) return 0;
    pthread_mutex_lock(&o->lock);
    snprintf(buf, (size_t)len, "%s", o->cur_path ? o->cur_path : "");
    pthread_mutex_unlock(&o->lock);
    return (int)strlen(buf);
}

int mc_output_backup_file(mc_output *o, char *buf, int len) {
    if (!o || !buf || len <= 0) return 0;
    pthread_mutex_lock(&o->lock);
    snprintf(buf, (size_t)len, "%s", o->backup_path ? o->backup_path : "");
    pthread_mutex_unlock(&o->lock);
    return (int)strlen(buf);
}

int mc_output_last_warning(mc_output *o, char *buf, int len) {
    if (!o || !buf || len <= 0) return 0;
    pthread_mutex_lock(&o->lock);
    snprintf(buf, (size_t)len, "%s", o->warning);
    pthread_mutex_unlock(&o->lock);
    return (int)strlen(buf);
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
