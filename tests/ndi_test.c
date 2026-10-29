// NDI loopback smoke test: send a BGRA pattern + tone, discover it, receive it.
#include "mc_core.h"
#include "mc_util.h"
#include <stdio.h>
#include <stdatomic.h>
#include <math.h>

static atomic_int vcount, acount;
static int gw, gh, gpix;
static void on_video(void *u, const uint8_t *p, int w, int h, int stride, int64_t pts) {
    (void)u; (void)pts;
    atomic_fetch_add(&vcount, 1);
    gw = w; gh = h;
    gpix = p[(h / 2) * stride + (w / 2) * 4 + 2];  // red channel at centre
}
static void on_audio(void *u, const float *s, int n) { (void)u; (void)s; atomic_fetch_add(&acount, n); }
static void on_status(void *u, int st, const char *m) { (void)u; printf("  recv state=%d %s\n", st, m); }

int main(void) {
    printf("NDI available=%d version=%s\n", mc_ndi_available(), mc_ndi_version());
    if (!mc_ndi_available()) return 1;
    if (getenv("MC_NDI_EXTRA_IPS")) mc_ndi_set_extra_ips(getenv("MC_NDI_EXTRA_IPS"));
    mc_ndi_send *s = mc_ndi_send_open("MC Test", 30, 1);
    int w = 320, h = 180;
    uint8_t *img = malloc(w * h * 4);
    for (int i = 0; i < w * h; i++) { img[i*4] = 10; img[i*4+1] = 20; img[i*4+2] = 200; img[i*4+3] = 255; }
    float tone[1600 * 2];
    for (int i = 0; i < 1600; i++) tone[i*2] = tone[i*2+1] = 0.1f * sinf(i * 0.05f);
    char buf[4096];
    char found[256] = {0};
    mc_ndi_recv *r = NULL;
    for (int tick = 0; tick < 200; tick++) {
        mc_ndi_send_video(s, img, w, h, w * 4);
        mc_ndi_send_audio(s, tone, 1600);
        if (!r && tick % 10 == 0) {
            int n = mc_ndi_list_sources(buf, sizeof(buf), 0);
            char *line = strtok(buf, "\n");
            while (line) { if (strstr(line, "MC Test")) { snprintf(found, sizeof(found), "%s", line); break; } line = strtok(NULL, "\n"); }
            if (found[0]) {
                printf("discovered %d source(s); connecting to '%s'\n", n, found);
                mc_callbacks cb = {on_video, on_audio, on_status, NULL};
                r = mc_ndi_recv_open(found, 0, cb);
            }
        }
        mc_sleep_us(33333);
    }
    printf("sender connections=%d\n", mc_ndi_send_connections(s));
    mc_ndi_recv_close(r);
    mc_ndi_send_close(s);
    printf("received video=%d (%dx%d, centre R=%d) audio frames=%d\n", atomic_load(&vcount), gw, gh, gpix, atomic_load(&acount));
    return 0;
}
