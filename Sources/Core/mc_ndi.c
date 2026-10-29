// NDI send/receive. libndi is loaded at runtime (dlopen) so the app runs without NDI installed.
// Build requires the NDI SDK headers (NDI SDK for Apple: "/Library/NDI SDK for Apple/include").
#include "mc_core.h"
#include "mc_util.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>

#if __has_include(<Processing.NDI.Lib.h>)
#define MC_HAVE_NDI 1
#include <Processing.NDI.Lib.h>
#else
#define MC_HAVE_NDI 0
#endif

#if MC_HAVE_NDI

static const NDIlib_v6 *g_ndi = NULL;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static char g_version[128] = "NDI 런타임 없음";
static NDIlib_find_instance_t g_finder = NULL;
static pthread_mutex_t g_find_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_extra_ips[1024] = {0};

static void ndi_load_once(void) {
    const char *candidates[12];
    char bundled[1200] = {0};
    int n = 0;
    char envpath[1024] = {0};
    const char *rt = getenv(NDILIB_REDIST_FOLDER);
    if (rt && rt[0]) {
        snprintf(envpath, sizeof(envpath), "%s/%s", rt, NDILIB_LIBRARY_NAME);
        candidates[n++] = envpath;
    }
#ifdef __APPLE__
    {   // copy shipped inside the app (Contents/Frameworks) by make-dmg.sh
        Dl_info info;
        if (dladdr((const void *)&ndi_load_once, &info) && info.dli_fname) {
            char exe[1024];
            snprintf(exe, sizeof(exe), "%s", info.dli_fname);
            char *slash = strrchr(exe, '/');
            if (slash) { *slash = 0; snprintf(bundled, sizeof(bundled), "%s/../Frameworks/libndi.dylib", exe); candidates[n++] = bundled; }
        }
    }
    candidates[n++] = "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib";
    candidates[n++] = "/usr/local/lib/libndi.dylib";
    candidates[n++] = "/opt/homebrew/lib/libndi.dylib";
    candidates[n++] = "/Library/NDI Advanced SDK for Apple/lib/macOS/libndi_advanced.dylib";
#endif
    candidates[n++] = NDILIB_LIBRARY_NAME;  // default search path
    for (int i = 0; i < n && !g_ndi; i++) {
        void *h = dlopen(candidates[i], RTLD_LOCAL | RTLD_LAZY);
        if (!h) continue;
        typedef const NDIlib_v6 *(*load_fn)(void);
        load_fn f = (load_fn)dlsym(h, "NDIlib_v6_load");
        if (!f) f = (load_fn)dlsym(h, "NDIlib_v5_load");
        if (!f) {
            dlclose(h);
            continue;
        }
        const NDIlib_v6 *lib = f();
        if (!lib || !lib->initialize || !lib->initialize()) {
            dlclose(h);
            continue;
        }
        g_ndi = lib;
        snprintf(g_version, sizeof(g_version), "%s", lib->version ? lib->version() : "NDI");
    }
}

int mc_ndi_available(void) {
    pthread_once(&g_once, ndi_load_once);
    return g_ndi != NULL;
}

const char *mc_ndi_version(void) {
    mc_ndi_available();
    return g_version;
}

int mc_ndi_list_sources(char *buf, int bufsize, int wait_ms) {
    if (buf && bufsize > 0) buf[0] = 0;
    if (!mc_ndi_available()) return 0;
    pthread_mutex_lock(&g_find_lock);
    if (!g_finder) {
        NDIlib_find_create_t fc;
        memset(&fc, 0, sizeof(fc));
        fc.show_local_sources = true;
        if (g_extra_ips[0]) fc.p_extra_ips = g_extra_ips;
        g_finder = g_ndi->find_create_v2(&fc);
    }
    int count = 0;
    if (g_finder) {
        if (wait_ms > 0) g_ndi->find_wait_for_sources(g_finder, (uint32_t)wait_ms);
        uint32_t n = 0;
        const NDIlib_source_t *src = g_ndi->find_get_current_sources(g_finder, &n);
        int pos = 0;
        for (uint32_t i = 0; i < n && src; i++) {
            const char *name = src[i].p_ndi_name ? src[i].p_ndi_name : "";
            int len = (int)strlen(name);
            if (buf && pos + len + 2 < bufsize) {
                memcpy(buf + pos, name, len);
                pos += len;
                buf[pos++] = '\n';
                buf[pos] = 0;
            }
            count++;
        }
    }
    pthread_mutex_unlock(&g_find_lock);
    return count;
}

void mc_ndi_set_extra_ips(const char *ips) {
    pthread_mutex_lock(&g_find_lock);
    const char *v = ips ? ips : "";
    if (strcmp(v, g_extra_ips) != 0) {
        snprintf(g_extra_ips, sizeof(g_extra_ips), "%s", v);
        if (g_finder && g_ndi) {
            g_ndi->find_destroy(g_finder);
            g_finder = NULL;
        }
    }
    pthread_mutex_unlock(&g_find_lock);
}

/* ---------------------------- receiver ---------------------------- */

struct mc_ndi_recv {
    char *name;
    int low_bw;
    mc_callbacks cb;
    pthread_t thread;
    atomic_int stop;
    atomic_int tally_pgm, tally_pvw, tally_dirty;
    float *abuf;
    int abuf_frames;
};

static void ndi_rstatus(mc_ndi_recv *r, int st, const char *msg) {
    if (r->cb.on_status) r->cb.on_status(r->cb.user, st, msg);
}

/* Convert NDI planar float audio to 48k interleaved stereo (linear resample if needed). */
static void deliver_ndi_audio(mc_ndi_recv *r, const NDIlib_audio_frame_v3_t *a) {
    if (!r->cb.on_audio || a->no_samples <= 0 || a->no_channels <= 0) return;
    if (a->FourCC != NDIlib_FourCC_audio_type_FLTP) return;
    int in_n = a->no_samples;
    int out_n = in_n;
    if (a->sample_rate != MC_AUDIO_RATE && a->sample_rate > 0)
        out_n = (int)((int64_t)in_n * MC_AUDIO_RATE / a->sample_rate);
    if (out_n <= 0) return;
    if (out_n > r->abuf_frames) {
        free(r->abuf);
        r->abuf = (float *)malloc((size_t)out_n * 2 * sizeof(float));
        r->abuf_frames = r->abuf ? out_n : 0;
        if (!r->abuf) return;
    }
    const float *L = (const float *)a->p_data;
    const float *R = a->no_channels > 1 ? (const float *)(a->p_data + a->channel_stride_in_bytes) : L;
    if (out_n == in_n) {
        for (int i = 0; i < in_n; i++) {
            r->abuf[i * 2] = L[i];
            r->abuf[i * 2 + 1] = R[i];
        }
    } else {
        double step = (double)in_n / out_n;
        for (int i = 0; i < out_n; i++) {
            double p = i * step;
            int i0 = (int)p;
            int i1 = i0 + 1 < in_n ? i0 + 1 : i0;
            float t = (float)(p - i0);
            r->abuf[i * 2] = L[i0] + (L[i1] - L[i0]) * t;
            r->abuf[i * 2 + 1] = R[i0] + (R[i1] - R[i0]) * t;
        }
    }
    r->cb.on_audio(r->cb.user, r->abuf, out_n);
}

static void *ndi_recv_thread(void *arg) {
    mc_ndi_recv *r = (mc_ndi_recv *)arg;
    NDIlib_source_t src;
    memset(&src, 0, sizeof(src));
    src.p_ndi_name = r->name;
    // Use the finder's resolved address when known (works without mDNS / across subnets).
    char *url = NULL;
    pthread_mutex_lock(&g_find_lock);
    if (g_finder) {
        uint32_t n = 0;
        const NDIlib_source_t *list = g_ndi->find_get_current_sources(g_finder, &n);
        for (uint32_t i = 0; i < n && list; i++) {
            if (list[i].p_ndi_name && strcmp(list[i].p_ndi_name, r->name) == 0 && list[i].p_url_address) {
                url = strdup(list[i].p_url_address);
                break;
            }
        }
    }
    pthread_mutex_unlock(&g_find_lock);
    src.p_url_address = url;
    NDIlib_recv_create_v3_t rc;
    memset(&rc, 0, sizeof(rc));
    rc.source_to_connect_to = src;
    rc.color_format = NDIlib_recv_color_format_BGRX_BGRA;
    rc.bandwidth = r->low_bw ? NDIlib_recv_bandwidth_lowest : NDIlib_recv_bandwidth_highest;
    rc.allow_video_fields = false;
    rc.p_ndi_recv_name = "BraceletMix";
    NDIlib_recv_instance_t recv = g_ndi->recv_create_v3(&rc);
    free(url);
    if (!recv) {
        ndi_rstatus(r, MC_STATE_ERROR, "NDI 수신기 생성 실패");
        return NULL;
    }
    ndi_rstatus(r, MC_STATE_CONNECTING, "NDI 연결 중");
    int connected = 0;
    int64_t last_frame = mc_now_us();
    while (!atomic_load(&r->stop)) {
        if (atomic_exchange(&r->tally_dirty, 0)) {
            NDIlib_tally_t t;
            t.on_program = atomic_load(&r->tally_pgm) != 0;
            t.on_preview = atomic_load(&r->tally_pvw) != 0;
            g_ndi->recv_set_tally(recv, &t);
        }
        NDIlib_video_frame_v2_t v;
        NDIlib_audio_frame_v3_t a;
        memset(&v, 0, sizeof(v));
        memset(&a, 0, sizeof(a));
        NDIlib_frame_type_e t = g_ndi->recv_capture_v3(recv, &v, &a, NULL, 200);
        switch (t) {
        case NDIlib_frame_type_video:
            if (!connected) {
                connected = 1;
                ndi_rstatus(r, MC_STATE_RUNNING, "NDI 수신 중");
            }
            last_frame = mc_now_us();
            if (r->cb.on_video && v.p_data &&
                (v.FourCC == NDIlib_FourCC_video_type_BGRA || v.FourCC == NDIlib_FourCC_video_type_BGRX)) {
                int stride = v.line_stride_in_bytes > 0 ? v.line_stride_in_bytes : v.xres * 4;
                r->cb.on_video(r->cb.user, v.p_data, v.xres, v.yres, stride, v.timestamp / 10);
            }
            g_ndi->recv_free_video_v2(recv, &v);
            break;
        case NDIlib_frame_type_audio:
            deliver_ndi_audio(r, &a);
            g_ndi->recv_free_audio_v3(recv, &a);
            break;
        case NDIlib_frame_type_error:
            ndi_rstatus(r, MC_STATE_ERROR, "NDI 연결 오류");
            break;
        default:
            break;
        }
        if (connected && mc_now_us() - last_frame > 3000000) {
            connected = 0;
            ndi_rstatus(r, MC_STATE_CONNECTING, "NDI 신호 없음 — 대기 중");
        }
    }
    g_ndi->recv_destroy(recv);
    ndi_rstatus(r, MC_STATE_STOPPED, "중지됨");
    return NULL;
}

mc_ndi_recv *mc_ndi_recv_open(const char *source_name, int low_bandwidth, mc_callbacks cb) {
    if (!source_name || !mc_ndi_available()) return NULL;
    mc_ndi_recv *r = (mc_ndi_recv *)calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->name = strdup(source_name);
    r->low_bw = low_bandwidth;
    r->cb = cb;
    atomic_init(&r->stop, 0);
    atomic_init(&r->tally_pgm, 0);
    atomic_init(&r->tally_pvw, 0);
    atomic_init(&r->tally_dirty, 0);
    if (pthread_create(&r->thread, NULL, ndi_recv_thread, r) != 0) {
        free(r->name);
        free(r);
        return NULL;
    }
    return r;
}

void mc_ndi_recv_set_tally(mc_ndi_recv *r, int program, int preview) {
    if (!r) return;
    if (atomic_load(&r->tally_pgm) == program && atomic_load(&r->tally_pvw) == preview) return;
    atomic_store(&r->tally_pgm, program);
    atomic_store(&r->tally_pvw, preview);
    atomic_store(&r->tally_dirty, 1);
}

void mc_ndi_recv_close(mc_ndi_recv *r) {
    if (!r) return;
    atomic_store(&r->stop, 1);
    pthread_join(r->thread, NULL);
    free(r->abuf);
    free(r->name);
    free(r);
}

/* ----------------------------- sender ----------------------------- */

struct mc_ndi_send {
    NDIlib_send_instance_t send;
    int fps_num, fps_den;
    pthread_t thread;
    mc_mailbox box;
    pthread_mutex_t alock;
    mc_audio_fifo afifo;
};

static void *ndi_send_thread(void *arg) {
    mc_ndi_send *s = (mc_ndi_send *)arg;
    // Two buffers + async send: NDI compresses frame N while we copy frame N+1 (the buffer handed to
    // send_send_video_async_v2 must stay untouched until the next call).
    uint8_t *bufs[2] = {NULL, NULL};
    int cur = 0;
    uint8_t *local = NULL;
    int lw = 0, lh = 0;
    float *abuf = NULL;
    int abuf_frames = 0;
    for (;;) {
        pthread_mutex_lock(&s->box.lock);
        while (!s->box.has_frame && !s->box.stop) pthread_cond_wait(&s->box.cond, &s->box.lock);
        if (s->box.stop) {
            pthread_mutex_unlock(&s->box.lock);
            break;
        }
        if (!bufs[0] || lw != s->box.width || lh != s->box.height) {
            if (bufs[0] || bufs[1]) g_ndi->send_send_video_async_v2(s->send, NULL);   // flush before freeing
            free(bufs[0]);
            free(bufs[1]);
            lw = s->box.width;
            lh = s->box.height;
            bufs[0] = (uint8_t *)malloc((size_t)lw * lh * 4);
            bufs[1] = (uint8_t *)malloc((size_t)lw * lh * 4);
        }
        local = bufs[cur];
        if (local) memcpy(local, s->box.data, (size_t)lw * lh * 4);
        s->box.has_frame = 0;
        pthread_mutex_unlock(&s->box.lock);
        if (!local) continue;

        // audio accumulated since last video frame
        pthread_mutex_lock(&s->alock);
        int n = s->afifo.count;
        if (n > abuf_frames) {
            free(abuf);
            abuf = (float *)malloc((size_t)n * 2 * sizeof(float));
            abuf_frames = abuf ? n : 0;
        }
        if (abuf && n > 0) n = mc_afifo_read(&s->afifo, abuf, n);
        else n = 0;
        pthread_mutex_unlock(&s->alock);

        NDIlib_video_frame_v2_t v;
        memset(&v, 0, sizeof(v));
        v.xres = lw;
        v.yres = lh;
        v.FourCC = NDIlib_FourCC_video_type_BGRA;
        v.frame_rate_N = s->fps_num;
        v.frame_rate_D = s->fps_den;
        v.picture_aspect_ratio = (float)lw / (float)lh;
        v.frame_format_type = NDIlib_frame_format_type_progressive;
        v.timecode = NDIlib_send_timecode_synthesize;
        v.p_data = local;
        v.line_stride_in_bytes = lw * 4;
        g_ndi->send_send_video_async_v2(s->send, &v);
        cur ^= 1;

        if (n > 0) {
            NDIlib_audio_frame_interleaved_32f_t a;
            memset(&a, 0, sizeof(a));
            a.sample_rate = MC_AUDIO_RATE;
            a.no_channels = 2;
            a.no_samples = n;
            a.timecode = NDIlib_send_timecode_synthesize;
            a.p_data = abuf;
            g_ndi->util_send_send_audio_interleaved_32f(s->send, &a);
        }
    }
    if (bufs[0] || bufs[1]) g_ndi->send_send_video_async_v2(s->send, NULL);   // wait until NDI is done with them
    free(bufs[0]);
    free(bufs[1]);
    free(abuf);
    return NULL;
}

mc_ndi_send *mc_ndi_send_open(const char *name, int fps_num, int fps_den) {
    if (!mc_ndi_available()) return NULL;
    mc_ndi_send *s = (mc_ndi_send *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    NDIlib_send_create_t sc;
    memset(&sc, 0, sizeof(sc));
    sc.p_ndi_name = name ? name : "BraceletMix Program";
    sc.clock_video = false;
    sc.clock_audio = false;
    s->send = g_ndi->send_create(&sc);
    if (!s->send) {
        free(s);
        return NULL;
    }
    s->fps_num = fps_num;
    s->fps_den = fps_den;
    mc_mailbox_init(&s->box);
    pthread_mutex_init(&s->alock, NULL);
    mc_afifo_init(&s->afifo, MC_AUDIO_RATE);
    if (pthread_create(&s->thread, NULL, ndi_send_thread, s) != 0) {
        g_ndi->send_destroy(s->send);
        mc_mailbox_destroy(&s->box);
        free(s);
        return NULL;
    }
    return s;
}

void mc_ndi_send_video(mc_ndi_send *s, const uint8_t *bgra, int width, int height, int stride) {
    if (s && bgra) mc_mailbox_put(&s->box, bgra, width, height, stride);
}

void mc_ndi_send_audio(mc_ndi_send *s, const float *stereo, int frames) {
    if (!s || !stereo) return;
    pthread_mutex_lock(&s->alock);
    mc_afifo_write(&s->afifo, stereo, frames);
    pthread_mutex_unlock(&s->alock);
}

int mc_ndi_send_connections(mc_ndi_send *s) {
    if (!s) return 0;
    return g_ndi->send_get_no_connections(s->send, 0);
}

void mc_ndi_send_close(mc_ndi_send *s) {
    if (!s) return;
    pthread_mutex_lock(&s->box.lock);
    s->box.stop = 1;
    pthread_cond_signal(&s->box.cond);
    pthread_mutex_unlock(&s->box.lock);
    pthread_join(s->thread, NULL);
    g_ndi->send_destroy(s->send);
    mc_mailbox_destroy(&s->box);
    mc_afifo_free(&s->afifo);
    pthread_mutex_destroy(&s->alock);
    free(s);
}

#else /* !MC_HAVE_NDI — stubs so the app builds without the SDK */

int mc_ndi_available(void) { return 0; }
void mc_ndi_set_extra_ips(const char *ips) { (void)ips; }
const char *mc_ndi_version(void) { return "NDI SDK 없이 빌드됨"; }
int mc_ndi_list_sources(char *buf, int bufsize, int wait_ms) {
    (void)wait_ms;
    if (buf && bufsize > 0) buf[0] = 0;
    return 0;
}
mc_ndi_recv *mc_ndi_recv_open(const char *n, int l, mc_callbacks cb) {
    (void)n; (void)l; (void)cb;
    return NULL;
}
void mc_ndi_recv_set_tally(mc_ndi_recv *r, int p, int v) { (void)r; (void)p; (void)v; }
void mc_ndi_recv_close(mc_ndi_recv *r) { (void)r; }
mc_ndi_send *mc_ndi_send_open(const char *n, int a, int b) {
    (void)n; (void)a; (void)b;
    return NULL;
}
void mc_ndi_send_video(mc_ndi_send *s, const uint8_t *p, int w, int h, int st) { (void)s; (void)p; (void)w; (void)h; (void)st; }
void mc_ndi_send_audio(mc_ndi_send *s, const float *p, int f) { (void)s; (void)p; (void)f; }
int mc_ndi_send_connections(mc_ndi_send *s) { (void)s; return 0; }
void mc_ndi_send_close(mc_ndi_send *s) { (void)s; }

#endif
