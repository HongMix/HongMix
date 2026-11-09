// Recording safety (backup mirror + continue on another disk): records 6 s at 30 fps (noisy moving
// picture so the bitrate is real + 1 kHz tone) and prints what happened. tests/rec_safety_test.sh
// checks the files with ffprobe.
//   rec_safety_test <main file> <mirror dir|-> <spill dir|-> <reserve bytes> [split file|-] [video kbps]
#include "mc_core.h"
#include "mc_util.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 640
#define H 360

static int saw_error = 0;

static void on_status(void *u, int st, const char *m) {
    (void)u;
    if (st == MC_STATE_ERROR) saw_error = 1;
    fprintf(stderr, "  [rec] state=%d %s\n", st, m);
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: rec_safety_test main mirror_dir|- spill_dir|- reserve [split|-] [kbps]\n");
        return 2;
    }
    const char *f1 = argv[1];
    const char *mirror = strcmp(argv[2], "-") ? argv[2] : NULL;
    const char *spill = strcmp(argv[3], "-") ? argv[3] : NULL;
    long long reserve = atoll(argv[4]);
    const char *split = argc > 5 && strcmp(argv[5], "-") ? argv[5] : NULL;
    int kbps = argc > 6 ? atoi(argv[6]) : 8000;
    const char *ext = strrchr(f1, '.');
    const char *fmt = ext && strcmp(ext, ".ts") == 0 ? "mpegts" : (ext && strcmp(ext, ".mp4") == 0 ? "mp4" : "mov");
    mc_output_config oc = {.url = f1, .format = fmt, .width = W, .height = H, .fps_num = 30, .fps_den = 1,
                           .video_kbps = kbps, .audio_kbps = 160, .video_codec = "h264", .keyint_frames = 30,
                           .hardware = 1};
    oc.mirror_dir = mirror;
    oc.spill_dir = spill;
    oc.spill_reserve_bytes = reserve;
    mc_output *rec = mc_output_open(&oc, on_status, NULL);
    if (!rec) { fprintf(stderr, "open failed\n"); return 2; }
    uint8_t *img = malloc(W * H * 4);
    float tone[1600 * 2];
    int64_t sample = 0;
    uint32_t rnd = 12345;
    mc_output_stats st;
    for (int i = 0; i < 300; i++) { mc_output_get_stats(rec, &st); if (st.state == MC_STATE_RUNNING) break; mc_sleep_us(10000); }
    int split_rc = -2;
    char mid_backup[1024] = "";
    int64_t t0 = mc_now_us();
    for (int64_t tick = 0; tick < 180; tick++) {
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                uint8_t *p = img + ((size_t)y * W + x) * 4;
                rnd = rnd * 1664525u + 1013904223u;
                uint8_t n = (uint8_t)(rnd >> 26);   // noise keeps the encoder near its bitrate
                p[0] = (uint8_t)(x + tick * 4 + n); p[1] = (uint8_t)(y + tick * 2 + n); p[2] = (uint8_t)(tick * 7 + n); p[3] = 255;
            }
        mc_output_push_video(rec, img, W * 4, tick);
        for (int i = 0; i < 1600; i++, sample++)
            tone[i * 2] = tone[i * 2 + 1] = 0.3f * (float)sin(2 * M_PI * 1000.0 * sample / 48000.0);
        mc_output_push_audio(rec, tone, 1600);
        if (split && tick == 89) split_rc = mc_output_split(rec, split);
        if (tick == 30) mc_output_backup_file(rec, mid_backup, sizeof(mid_backup));
        int64_t target = t0 + (tick + 1) * 33333;
        mc_sleep_us(target - mc_now_us());
    }
    mc_sleep_us(300000);
    char cur[1024], bak[1024], warn[256];
    mc_output_current_file(rec, cur, sizeof(cur));
    mc_output_backup_file(rec, bak, sizeof(bak));
    mc_output_last_warning(rec, warn, sizeof(warn));
    mc_output_get_stats(rec, &st);
    mc_output_close(rec);
    printf("frames_pushed=180\nencoder=%s\nframes_encoded=%lld\nframes_dropped=%lld\nsplit_rc=%d\n"
           "state=%d\nsaw_error=%d\nmirror_state=%d\nmain_failed=%d\nspills=%d\nwarnings=%d\n"
           "last_warning=%s\ncurrent_file=%s\nbackup_file=%s\nbackup_file_mid=%s\n",
           st.encoder, (long long)st.frames_encoded, (long long)st.frames_dropped, split_rc, st.state, saw_error,
           st.mirror_state, st.main_failed, st.spills, st.warning_seq, warn, cur, bak, mid_backup);
    free(img);
    return 0;
}
