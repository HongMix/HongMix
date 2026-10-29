// Linux/macOS smoke test for the C media core (no GUI).
//   1) decode a media file via mc_input (paced) and record it via mc_output
//   2) SRT loopback: mc_output -> srt listener, mc_input caller receives it
#include "mc_core.h"
#include "mc_util.h"
#include <stdio.h>
#include <stdatomic.h>
#include <unistd.h>
#include <math.h>

typedef struct {
    atomic_int vframes, aframes;
    int w, h;
    mc_output *rec;
    int64_t tick;
    uint8_t *canvas;
    pthread_mutex_t lock;
} ctx_t;

static void on_video(void *u, const uint8_t *bgra, int w, int h, int stride, int64_t pts) {
    (void)pts;
    ctx_t *c = (ctx_t *)u;
    atomic_fetch_add(&c->vframes, 1);
    c->w = w;
    c->h = h;
    pthread_mutex_lock(&c->lock);
    if (c->canvas && w == 640 && h == 360)
        for (int y = 0; y < h; y++) memcpy(c->canvas + (size_t)y * w * 4, bgra + (size_t)y * stride, w * 4);
    pthread_mutex_unlock(&c->lock);
}
static void on_audio(void *u, const float *s, int n) {
    (void)s;
    ctx_t *c = (ctx_t *)u;
    atomic_fetch_add(&c->aframes, n);
}
static void on_status(void *u, int st, const char *m) {
    printf("  [%s] state=%d %s\n", (const char *)u, st, m);
    fflush(stdout);
}

int main(int argc, char **argv) {
    const char *src = argc > 1 ? argv[1] : "/tmp/mc_src.mp4";
    printf("%s\n", mc_core_version());

    // pixel conversion round trip
    {
        uint8_t bgra[8 * 4], uyvy[8 * 2], back[8 * 4];
        for (int i = 0; i < 8; i++) { bgra[i*4]=(uint8_t)(i*30); bgra[i*4+1]=128; bgra[i*4+2]=(uint8_t)(200-i*20); bgra[i*4+3]=255; }
        mc_bgra_to_uyvy(bgra, 32, uyvy, 16, 8, 1);
        mc_uyvy_to_bgra(uyvy, 16, back, 32, 8, 1);
        int maxd = 0;
        for (int i = 0; i < 32; i++) { int d = abs((int)bgra[i] - (int)back[i]); if (i % 4 != 3 && d > maxd) maxd = d; }
        printf("UYVY round-trip max error (chroma subsampled): %d\n", maxd);
    }

    // 1) file -> record
    ctx_t c;
    memset(&c, 0, sizeof(c));
    pthread_mutex_init(&c.lock, NULL);
    c.canvas = calloc(640 * 360 * 4, 1);
    mc_input_config ic = {.url = src, .loop = 0, .realtime = -1, .low_latency = 0, .hwaccel = 1};
    mc_callbacks cb = {on_video, on_audio, on_status, "file-in"};
    cb.user = &c;
    cb.on_status = NULL;
    mc_input *in = mc_input_open(&ic, cb);

    mc_output_config oc = {.url = "/tmp/mc_rec.mp4", .width = 640, .height = 360, .fps_num = 30, .fps_den = 1,
                           .video_kbps = 2000, .audio_kbps = 128, .video_codec = "h264", .hardware = 1};
    mc_output *rec = mc_output_open(&oc, on_status, "rec");
    float silence[1600 * 2];
    for (int i = 0; i < 1600; i++) { silence[i*2] = 0.2f * (float)sin(i * 0.0571); silence[i*2+1] = silence[i*2]; }
    int64_t t0 = mc_now_us();
    for (int64_t tick = 0; tick < 90; tick++) {  // 3 seconds at 30 fps
        pthread_mutex_lock(&c.lock);
        mc_output_push_video(rec, c.canvas, 640 * 4, tick);
        pthread_mutex_unlock(&c.lock);
        mc_output_push_audio(rec, silence, 1600);
        int64_t target = t0 + (tick + 1) * 33333;
        mc_sleep_us(target - mc_now_us());
    }
    mc_output_stats st;
    mc_output_get_stats(rec, &st);
    printf("record: encoder=%s frames=%lld dropped=%lld bytes=%lld\n", st.encoder, (long long)st.frames_encoded,
           (long long)st.frames_dropped, (long long)st.bytes_written);
    mc_output_close(rec);
    mc_input_close(in);
    printf("file input: video frames=%d (%dx%d) audio frames=%d\n", atomic_load(&c.vframes), c.w, c.h,
           atomic_load(&c.aframes));

    // 2) SRT loopback
    ctx_t r;
    memset(&r, 0, sizeof(r));
    pthread_mutex_init(&r.lock, NULL);
    mc_output_config so = oc;
    so.url = "srt://127.0.0.1:9710?mode=listener&latency=120000&pkt_size=1316";
    so.reconnect = 1;
    mc_output *srt = mc_output_open(&so, on_status, "srt-out");
    usleep(300000);
    mc_input_config si = {.url = "srt://127.0.0.1:9710?mode=caller&latency=120000", .realtime = 0, .low_latency = 1};
    mc_callbacks rcb = {on_video, on_audio, on_status, &r};
    rcb.on_status = NULL;
    mc_input *sin_ = mc_input_open(&si, rcb);
    t0 = mc_now_us();
    for (int64_t tick = 0; tick < 150; tick++) {
        mc_output_push_video(srt, c.canvas, 640 * 4, tick);
        mc_output_push_audio(srt, silence, 1600);
        int64_t target = t0 + (tick + 1) * 33333;
        mc_sleep_us(target - mc_now_us());
    }
    mc_output_get_stats(srt, &st);
    printf("srt out: frames=%lld kbps=%.0f\n", (long long)st.frames_encoded, st.kbps);
    mc_input_close(sin_);
    mc_output_close(srt);
    printf("srt in: video frames=%d (%dx%d) audio frames=%d\n", atomic_load(&r.vframes), r.w, r.h,
           atomic_load(&r.aframes));
    return 0;
}
