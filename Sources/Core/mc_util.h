// Internal helpers shared by the C core (not part of the Swift-facing API).
#ifndef MC_UTIL_H
#define MC_UTIL_H

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline int64_t mc_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static inline void mc_sleep_us(int64_t us) {
    if (us <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)(us / 1000000);
    ts.tv_nsec = (long)((us % 1000000) * 1000);
    nanosleep(&ts, NULL);
}

/* Interleaved stereo float FIFO (single lock, grows up to max_frames). */
typedef struct {
    float *data;
    int capacity;   // frames
    int read_pos;   // frames
    int count;      // frames
    int max_frames;
} mc_audio_fifo;

static inline void mc_afifo_init(mc_audio_fifo *f, int max_frames) {
    memset(f, 0, sizeof(*f));
    f->max_frames = max_frames;
}

static inline void mc_afifo_free(mc_audio_fifo *f) {
    free(f->data);
    memset(f, 0, sizeof(*f));
}

static inline void mc_afifo_clear(mc_audio_fifo *f) {
    f->read_pos = 0;
    f->count = 0;
}

/* Returns frames dropped (oldest) to make room. */
static inline int mc_afifo_write(mc_audio_fifo *f, const float *src, int frames) {
    int dropped = 0;
    if (frames <= 0) return 0;
    if (frames > f->max_frames) {
        dropped += frames - f->max_frames;
        src += (size_t)(frames - f->max_frames) * 2;
        frames = f->max_frames;
    }
    if (f->count + frames > f->capacity) {
        int newcap = f->capacity ? f->capacity : 4096;
        while (newcap < f->count + frames && newcap < f->max_frames) newcap *= 2;
        if (newcap > f->max_frames) newcap = f->max_frames;
        if (newcap > f->capacity) {
            float *nd = (float *)malloc((size_t)newcap * 2 * sizeof(float));
            if (!nd) return frames;
            for (int i = 0; i < f->count; i++) {
                int p = (f->read_pos + i) % (f->capacity ? f->capacity : 1);
                nd[i * 2] = f->data[p * 2];
                nd[i * 2 + 1] = f->data[p * 2 + 1];
            }
            free(f->data);
            f->data = nd;
            f->capacity = newcap;
            f->read_pos = 0;
        }
    }
    if (f->count + frames > f->capacity) {
        int over = f->count + frames - f->capacity;
        f->read_pos = (f->read_pos + over) % f->capacity;
        f->count -= over;
        dropped += over;
    }
    int wpos = (f->read_pos + f->count) % f->capacity;
    for (int i = 0; i < frames; i++) {
        f->data[wpos * 2] = src[i * 2];
        f->data[wpos * 2 + 1] = src[i * 2 + 1];
        wpos++;
        if (wpos == f->capacity) wpos = 0;
    }
    f->count += frames;
    return dropped;
}

static inline int mc_afifo_read(mc_audio_fifo *f, float *dst, int frames) {
    if (frames > f->count) frames = f->count;
    for (int i = 0; i < frames; i++) {
        dst[i * 2] = f->data[f->read_pos * 2];
        dst[i * 2 + 1] = f->data[f->read_pos * 2 + 1];
        f->read_pos++;
        if (f->read_pos == f->capacity) f->read_pos = 0;
    }
    f->count -= frames;
    return frames;
}

/* Latest-frame mailbox for worker threads (single slot, newest wins). */
typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    uint8_t *data;
    int stride, width, height;
    int has_frame;
    int stop;
    int64_t dropped;
} mc_mailbox;

static inline void mc_mailbox_init(mc_mailbox *m) {
    memset(m, 0, sizeof(*m));
    pthread_mutex_init(&m->lock, NULL);
    pthread_cond_init(&m->cond, NULL);
}

static inline void mc_mailbox_destroy(mc_mailbox *m) {
    pthread_mutex_destroy(&m->lock);
    pthread_cond_destroy(&m->cond);
    free(m->data);
    m->data = NULL;
}

/* Copy a frame in; caller must not hold lock. */
static inline void mc_mailbox_put(mc_mailbox *m, const uint8_t *src, int width, int height, int stride) {
    pthread_mutex_lock(&m->lock);
    int need = width * 4;
    if (!m->data || m->width != width || m->height != height) {
        free(m->data);
        m->data = (uint8_t *)malloc((size_t)need * height);
        m->width = width;
        m->height = height;
        m->stride = need;
    }
    if (m->data) {
        if (stride == need) memcpy(m->data, src, (size_t)need * height);
        else for (int y = 0; y < height; y++) memcpy(m->data + (size_t)y * need, src + (size_t)y * stride, need);
        if (m->has_frame) m->dropped++;
        m->has_frame = 1;
    }
    pthread_cond_signal(&m->cond);
    pthread_mutex_unlock(&m->lock);
}

/* swscale context using all CPU cores (FFmpeg "threads" option); NULL on failure. */
struct SwsContext;
struct SwsContext *mc_sws_get(int sw, int sh, int sfmt, int dw, int dh, int dfmt, int flags);

#ifdef __cplusplus
}
#endif
#endif
