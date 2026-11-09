// Looping file input must be gapless: a 2 s clip with loop=1 is played for ~7 s (three wraps) and the
// delivered audio is checked against real time. A gap at the wrap (seek + decoder restart with the
// queues and media clock thrown away) shows up as audio arriving later than the samples already
// delivered can cover — exactly what the mixer counts as an underflow.
#include "mc_core.h"
#include "mc_util.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

#define MAXCB 20000
static int64_t cb_t[MAXCB];
static int64_t cb_before[MAXCB];   // frames delivered before this callback
static atomic_int ncb;
static atomic_llong total_frames;
static atomic_int vframes;
static int64_t vlast_us, vmax_gap_us;

static void on_audio(void *u, const float *s, int n) {
    (void)u; (void)s;
    int i = atomic_fetch_add(&ncb, 1);
    long long before = atomic_fetch_add(&total_frames, n);
    if (i < MAXCB) { cb_t[i] = mc_now_us(); cb_before[i] = before; }
}
static void on_pb(void *u, void *pb, int64_t pts) {
    (void)u; (void)pb; (void)pts;
    int64_t now = mc_now_us();
    if (vlast_us && now - vlast_us > vmax_gap_us) vmax_gap_us = now - vlast_us;
    vlast_us = now;
    atomic_fetch_add(&vframes, 1);
}
static void on_video(void *u, const uint8_t *b, int w, int h, int st, int64_t pts) {
    (void)b; (void)w; (void)h; (void)st;
    on_pb(u, NULL, pts);
}

static int cmp(const void *x, const void *y) {
    int64_t a = *(const int64_t *)x, b = *(const int64_t *)y;
    return (a > b) - (a < b);
}

int main(int argc, char **argv) {
    const char *src = argc > 1 ? argv[1] : "/tmp/mc_loop_src.mp4";
    double seconds = argc > 2 ? atof(argv[2]) : 7.0;
    mc_input_config ic = {.url = src, .loop = 1, .realtime = -1, .hwaccel = 1};
    mc_callbacks cb = {0};
    cb.on_video = on_video;
    cb.on_audio = on_audio;
    cb.on_pixelbuffer = on_pb;
    mc_input *in = mc_input_open(&ic, cb);
    if (!in) { fprintf(stderr, "open failed\n"); return 2; }
    int64_t t_open = mc_now_us();
    while (atomic_load(&ncb) == 0 && mc_now_us() - t_open < 3000000) mc_sleep_us(1000);
    int64_t t0 = mc_now_us();
    while (mc_now_us() - t0 < (int64_t)(seconds * 1e6)) mc_sleep_us(10000);
    int n = atomic_load(&ncb);
    mc_input_close(in);
    if (n > MAXCB) n = MAXCB;
    if (n < 10) { fprintf(stderr, "no audio delivered\n"); return 2; }

    /* Lateness of each callback relative to the audio already delivered: callback i is due by
       t_first + frames_before_i / 48 kHz (minus the steady release lead). In steady state every chunk
       is released at the same lead, so lateness is flat; a hole at a loop wrap shifts it up by the
       hole's length for good (the stream is that much behind real time from then on). Compare the
       median lateness before the first wrap with the median over the last half second. Short
       release-thread scheduling jitter is absorbed by the ~100 ms lead and only checked loosely. */
    int64_t tf = cb_t[0];
    static int64_t base[MAXCB], tail[MAXCB];
    int nb = 0, nt = 0;
    int64_t max_l = INT64_MIN, end_t = cb_t[n - 1] - tf;
    for (int i = 1; i < n; i++) {
        int64_t late = cb_t[i] - (tf + cb_before[i] * 1000000 / MC_AUDIO_RATE), at = cb_t[i] - tf;
        if (at < 500000) continue;                       // start-up (clock start, first release lead)
        if (at < 1500000) base[nb++] = late;             // steady state before the first wrap
        else if (late > max_l) max_l = late;
        if (at > end_t - 500000) tail[nt++] = late;
    }
    if (nb == 0 || nt == 0) { fprintf(stderr, "run too short\n"); return 2; }
    qsort(base, nb, sizeof(int64_t), cmp);
    qsort(tail, nt, sizeof(int64_t), cmp);
    int64_t gap_us = tail[nt / 2] - base[nb / 2];
    int64_t jitter_us = max_l - base[nb / 2];
    double span = end_t / 1e6;
    long long frames = atomic_load(&total_frames);
    double ratio = frames / (span * MC_AUDIO_RATE);
    printf("audio: %d callbacks, %lld frames over %.2f s (%.3f x real time)\n", n, frames, span, ratio);
    printf("audio lost to loop wraps: %.1f ms (limit 5); worst momentary release delay %.1f ms (limit 50)\n",
           gap_us / 1000.0, jitter_us / 1000.0);
    printf("video: %d frames, longest interval %.1f ms\n", atomic_load(&vframes), vmax_gap_us / 1000.0);
    int ok = gap_us <= 5000 && jitter_us <= 50000 && ratio > 0.98 && ratio < 1.05 && vmax_gap_us < 100000;
    puts(ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
