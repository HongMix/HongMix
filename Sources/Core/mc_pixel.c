// Pixel and sample format helpers (BT.709, limited range) used by DeckLink I/O.
#include "mc_core.h"

static inline uint8_t clamp8(int v) { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); }

void mc_uyvy_to_bgra(const uint8_t *src, int src_stride, uint8_t *dst, int dst_stride, int width, int height) {
    for (int y = 0; y < height; y++) {
        const uint8_t *s = src + (size_t)y * src_stride;
        uint8_t *d = dst + (size_t)y * dst_stride;
        for (int x = 0; x + 1 < width; x += 2) {
            int u = s[0] - 128, y0 = (s[1] - 16) * 298, v = s[2] - 128, y1 = (s[3] - 16) * 298;
            int rv = 459 * v, guv = -55 * u - 136 * v, bu = 541 * u;
            d[0] = clamp8((y0 + bu + 128) >> 8);
            d[1] = clamp8((y0 + guv + 128) >> 8);
            d[2] = clamp8((y0 + rv + 128) >> 8);
            d[3] = 255;
            d[4] = clamp8((y1 + bu + 128) >> 8);
            d[5] = clamp8((y1 + guv + 128) >> 8);
            d[6] = clamp8((y1 + rv + 128) >> 8);
            d[7] = 255;
            s += 4;
            d += 8;
        }
    }
}

void mc_bgra_to_uyvy(const uint8_t *src, int src_stride, uint8_t *dst, int dst_stride, int width, int height) {
    for (int y = 0; y < height; y++) {
        const uint8_t *s = src + (size_t)y * src_stride;
        uint8_t *d = dst + (size_t)y * dst_stride;
        for (int x = 0; x + 1 < width; x += 2) {
            int b0 = s[0], g0 = s[1], r0 = s[2];
            int b1 = s[4], g1 = s[5], r1 = s[6];
            int y0 = ((47 * r0 + 157 * g0 + 16 * b0 + 128) >> 8) + 16;
            int y1 = ((47 * r1 + 157 * g1 + 16 * b1 + 128) >> 8) + 16;
            int r = (r0 + r1) >> 1, g = (g0 + g1) >> 1, b = (b0 + b1) >> 1;
            int cb = ((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128;
            int cr = ((112 * r - 102 * g - 10 * b + 128) >> 8) + 128;
            d[0] = clamp8(cb);
            d[1] = clamp8(y0);
            d[2] = clamp8(cr);
            d[3] = clamp8(y1);
            s += 8;
            d += 4;
        }
    }
}

void mc_s32_to_float(const int32_t *src, float *dst, int samples) {
    const float k = 1.0f / 2147483648.0f;
    for (int i = 0; i < samples; i++) dst[i] = (float)src[i] * k;
}

void mc_float_to_s32(const float *src, int32_t *dst, int samples) {
    for (int i = 0; i < samples; i++) {
        float v = src[i];
        if (v > 1.0f) v = 1.0f;
        if (v < -1.0f) v = -1.0f;
        dst[i] = (int32_t)(v * 2147483647.0f);
    }
}

// ---- threaded swscale ------------------------------------------------------
#include "mc_util.h"
#include <libswscale/swscale.h>
#include <libavutil/opt.h>

struct SwsContext *mc_sws_get(int sw, int sh, int sfmt, int dw, int dh, int dfmt, int flags) {
    struct SwsContext *c = sws_alloc_context();
    if (!c) return NULL;
    av_opt_set_int(c, "srcw", sw, 0);
    av_opt_set_int(c, "srch", sh, 0);
    av_opt_set_int(c, "src_format", sfmt, 0);
    av_opt_set_int(c, "dstw", dw, 0);
    av_opt_set_int(c, "dsth", dh, 0);
    av_opt_set_int(c, "dst_format", dfmt, 0);
    av_opt_set_int(c, "sws_flags", flags, 0);
    av_opt_set_int(c, "threads", 0, 0);   /* 0 = one slice per CPU core (ignored by old FFmpeg) */
    if (sws_init_context(c, NULL, NULL) < 0) {
        sws_freeContext(c);
        return sws_getContext(sw, sh, (enum AVPixelFormat)sfmt, dw, dh, (enum AVPixelFormat)dfmt, flags, NULL, NULL, NULL);
    }
    return c;
}
