// Broadcast delay across a network reconnect (HongMix 1.4.7).
// Pushes 30 fps test frames to an SRT caller output with a 4 s delay for `secs` seconds.
// The script tests/delay_reconnect_test.sh kills and restarts the SRT receiver in the middle and
// checks that the packets held at the drop still air after the reconnect (timeline continues).
#include "mc_core.h"
#include "mc_util.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void on_status(void *u, int state, const char *msg) {
    fprintf(stderr, "[%lld ms] %s state=%d %s\n", (long long)(mc_now_us() / 1000 % 100000), (const char *)u, state,
            msg ? msg : "");
}

int main(int argc, char **argv) {
    const char *url = argc > 1 ? argv[1] : "srt://127.0.0.1:9720?mode=caller&latency=120000&pkt_size=1316";
    int secs = argc > 2 ? atoi(argv[2]) : 24;
    int delay = argc > 3 ? atoi(argv[3]) : 4000;   // ms (0 = live)
    mc_output_config oc = {.url = url, .format = "mpegts", .width = 640, .height = 360, .fps_num = 30, .fps_den = 1,
                           .video_kbps = 1500, .audio_kbps = 128, .video_codec = "h264", .hardware = 1,
                           .reconnect = 1, .delay_ms = delay};
    mc_output *o = mc_output_open(&oc, on_status, "out");
    if (!o) return 1;
    uint8_t *frame = malloc(640 * 360 * 4);
    float audio[1600 * 2];
    int64_t t0 = mc_now_us();
    for (int64_t tick = 0; tick < (int64_t)secs * 30; tick++) {
        memset(frame, (int)(tick * 7 % 255), 640 * 360 * 4);
        mc_output_push_video(o, frame, 640 * 4, tick);
        for (int i = 0; i < 1600; i++) audio[i * 2] = audio[i * 2 + 1] = 0.2f * (float)sin((tick * 1600 + i) * 0.0571);
        mc_output_push_audio(o, audio, 1600);
        int64_t due = t0 + (tick + 1) * 1000000 / 30;
        int64_t now = mc_now_us();
        if (due > now) usleep((useconds_t)(due - now));
    }
    mc_output_close(o);
    free(frame);
    return 0;
}
