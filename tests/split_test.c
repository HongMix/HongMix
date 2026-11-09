// "New file every N min" split: records 6 s at 30 fps (moving picture + 1 kHz tone), asks for a split
// after 3 s, and prints what was pushed. tests/split_test.sh checks the two files with ffprobe.
//   split_test <file1> <file2> [h264|hevc|prores] [sw]
#include "mc_core.h"
#include "mc_util.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 640
#define H 360

static void on_status(void *u, int st, const char *m) {
    (void)u;
    fprintf(stderr, "  [rec] state=%d %s\n", st, m);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: split_test file1 file2 [prores]\n"); return 2; }
    const char *f1 = argv[1], *f2 = argv[2];
    const char *ext = strrchr(f1, '.');
    const char *fmt = ext && strcmp(ext, ".ts") == 0 ? "mpegts" : (ext && strcmp(ext, ".mp4") == 0 ? "mp4" : "mov");
    mc_output_config oc = {.url = f1, .format = fmt, .width = W, .height = H, .fps_num = 30, .fps_den = 1,
                           .video_kbps = 4000, .audio_kbps = 160,
                           .video_codec = argc > 3 ? argv[3] : "h264", .keyint_frames = 60};
    oc.hardware = !(argc > 4 && strcmp(argv[4], "sw") == 0);   // sw = libx264 (forced IDR path)
    mc_output *rec = mc_output_open(&oc, on_status, NULL);
    if (!rec) { fprintf(stderr, "open failed\n"); return 2; }
    uint8_t *img = malloc(W * H * 4);
    float tone[1600 * 2];
    int64_t t0 = mc_now_us(), sample = 0;
    mc_output_stats st;
    // wait until it records (frames pushed before RUNNING are not accepted)
    for (int i = 0; i < 300; i++) { mc_output_get_stats(rec, &st); if (st.state == MC_STATE_RUNNING) break; mc_sleep_us(10000); }
    int split_rc = -2;
    t0 = mc_now_us();
    for (int64_t tick = 0; tick < 180; tick++) {
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                uint8_t *p = img + ((size_t)y * W + x) * 4;
                p[0] = (uint8_t)(x + tick * 4); p[1] = (uint8_t)(y + tick * 2); p[2] = (uint8_t)(tick * 7); p[3] = 255;
            }
        mc_output_push_video(rec, img, W * 4, tick);
        for (int i = 0; i < 1600; i++, sample++) {
            tone[i * 2] = tone[i * 2 + 1] = 0.3f * (float)sin(2 * M_PI * 1000.0 * sample / 48000.0);
        }
        mc_output_push_audio(rec, tone, 1600);
        if (tick == 89) split_rc = mc_output_split(rec, f2);
        int64_t target = t0 + (tick + 1) * 33333;
        mc_sleep_us(target - mc_now_us());
    }
    mc_sleep_us(200000);
    char cur[1024];
    mc_output_current_file(rec, cur, sizeof(cur));
    mc_output_get_stats(rec, &st);
    mc_output_close(rec);
    printf("split_rc=%d\nencoder=%s\nframes_pushed=180\nframes_encoded=%lld\nframes_dropped=%lld\nsamples_pushed=%lld\ncurrent_file_ok=%d\n",
           split_rc, st.encoder, (long long)st.frames_encoded, (long long)st.frames_dropped, (long long)sample,
           strcmp(cur, f2) == 0);
    free(img);
    return 0;
}
