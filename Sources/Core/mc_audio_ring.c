#include "mc_core.h"

#include <stdatomic.h>
#include <stdlib.h>

struct mc_audio_ring {
    int capacity;
    float *samples;
    _Atomic uint64_t read_frame;
    _Atomic uint64_t write_frame;
    _Atomic uint64_t short_reads;
    _Atomic uint64_t short_frames;
    _Atomic uint64_t priming_silence_frames;
};

mc_audio_ring *mc_audio_ring_create(int capacity_frames) {
    if (capacity_frames < 2) return NULL;
    mc_audio_ring *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->samples = calloc((size_t)capacity_frames * 2, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->capacity = capacity_frames;
    atomic_init(&ring->read_frame, 0);
    atomic_init(&ring->write_frame, 0);
    atomic_init(&ring->short_reads, 0);
    atomic_init(&ring->short_frames, 0);
    atomic_init(&ring->priming_silence_frames, 0);
    if (!atomic_is_lock_free(&ring->read_frame) || !atomic_is_lock_free(&ring->write_frame)) {
        free(ring->samples);
        free(ring);
        return NULL;
    }
    return ring;
}

void mc_audio_ring_destroy(mc_audio_ring *ring) {
    if (!ring) return;
    free(ring->samples);
    free(ring);
}

int mc_audio_ring_available(const mc_audio_ring *ring) {
    if (!ring) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_acquire);
    uint64_t queued = write - read;
    return queued > (uint64_t)ring->capacity ? ring->capacity : (int)queued;
}

int mc_audio_ring_write(mc_audio_ring *ring, const float *src, int frames) {
    if (!ring || !src || frames <= 0) return 0;
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_acquire);
    uint64_t queued = write - read;
    if (queued > (uint64_t)ring->capacity) return 0;
    int free_frames = ring->capacity - (int)queued;
    int count = frames < free_frames ? frames : free_frames;
    for (int i = 0; i < count; i++) {
        int slot = (int)((write + (uint64_t)i) % (uint64_t)ring->capacity);
        ring->samples[slot * 2] = src[i * 2];
        ring->samples[slot * 2 + 1] = src[i * 2 + 1];
    }
    atomic_store_explicit(&ring->write_frame, write + (uint64_t)count, memory_order_release);
    return count;
}

int mc_audio_ring_read(mc_audio_ring *ring, float *dst, int frames) {
    if (!ring || !dst || frames <= 0) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_acquire);
    uint64_t queued = write - read;
    int count = queued < (uint64_t)frames ? (int)queued : frames;
    if (count < frames) {
        atomic_fetch_add_explicit(&ring->short_reads, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->short_frames, (uint64_t)(frames - count), memory_order_relaxed);
    }
    for (int i = 0; i < count; i++) {
        int slot = (int)((read + (uint64_t)i) % (uint64_t)ring->capacity);
        dst[i * 2] = ring->samples[slot * 2];
        dst[i * 2 + 1] = ring->samples[slot * 2 + 1];
    }
    atomic_store_explicit(&ring->read_frame, read + (uint64_t)count, memory_order_release);
    return count;
}

uint64_t mc_audio_ring_short_reads(const mc_audio_ring *ring) {
    return ring ? atomic_load_explicit(&ring->short_reads, memory_order_relaxed) : 0;
}

uint64_t mc_audio_ring_short_frames(const mc_audio_ring *ring) {
    return ring ? atomic_load_explicit(&ring->short_frames, memory_order_relaxed) : 0;
}

uint64_t mc_audio_ring_priming_silence_frames(const mc_audio_ring *ring) {
    return ring ? atomic_load_explicit(&ring->priming_silence_frames, memory_order_relaxed) : 0;
}

void mc_audio_ring_note_priming_silence(mc_audio_ring *ring, uint64_t frames) {
    if (ring && frames) atomic_fetch_add_explicit(&ring->priming_silence_frames, frames, memory_order_relaxed);
}

void mc_audio_ring_reset_diagnostics(mc_audio_ring *ring) {
    if (!ring) return;
    atomic_store_explicit(&ring->short_reads, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->short_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->priming_silence_frames, 0, memory_order_relaxed);
}

int mc_audio_ring_skip(mc_audio_ring *ring, int frames) {
    if (!ring || frames <= 0) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_frame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_acquire);
    uint64_t queued = write - read;
    int count = queued < (uint64_t)frames ? (int)queued : frames;
    atomic_store_explicit(&ring->read_frame, read + (uint64_t)count, memory_order_release);
    return count;
}

void mc_audio_ring_clear(mc_audio_ring *ring) {
    if (!ring) return;
    uint64_t write = atomic_load_explicit(&ring->write_frame, memory_order_acquire);
    atomic_store_explicit(&ring->read_frame, write, memory_order_release);
}

/* ------------------------------------------------------------------ */
/* Adaptive-rate reader for live sources (clock-drift compensation)    */
/* ------------------------------------------------------------------ */

/* A live source (capture card, NDI, SRT, DeckLink, audio device) runs on its own clock, so
   relative to the 48 kHz mixer it delivers e.g. 48 048 or 47 952 frames per second. Reading
   exactly `frames` per tick makes the queue grow or drain without bound. Instead we read at
   ratio = 1 + dev (input frames per output frame) with 4-point Catmull-Rom interpolation and
   steer dev with a slow PI controller on the smoothed fill level. All constants assume 48 kHz. */

#define DRIFT_RATE       48000.0
#define DRIFT_FILL_TAU   1.0      /* s: EMA on fill level; hides bursty producers (NDI/DeckLink per frame) */
#define DRIFT_KP         0.2      /* ratio deviation per second of fill error */
#define DRIFT_KI         0.01     /* per s^2: ωn = 0.1 rad/s, ζ = 1 → ~10 s settling, inaudible */
#define DRIFT_MAX_DEV    0.005    /* ±0.5 %: ≈ ±8.6 cents worst case, covers any sane clock */
#define DRIFT_SLEW       0.001    /* max ratio change per second → no audible pitch steps */
#define DRIFT_FADE       64       /* frames of fade-in/out around underruns and resets */

struct mc_audio_drift {
    double frac;          /* fractional read position after ring frame 0, [0, 1) */
    double ratio;         /* current input frames per output frame */
    double integ;         /* integral term (learned clock offset), survives re-primes */
    double avg_fill;      /* EMA of queued frames after each read */
    int avg_valid;
    int prev_valid;
    int fade_in;          /* frames of fade-in still to apply */
    float prev[2];        /* frame just before the ring read index (x[-1]) */
};

mc_audio_drift *mc_audio_drift_create(void) {
    mc_audio_drift *d = calloc(1, sizeof(*d));
    if (d) mc_audio_drift_reset(d, 0);
    return d;
}

void mc_audio_drift_destroy(mc_audio_drift *d) { free(d); }

void mc_audio_drift_reset(mc_audio_drift *d, int keep_rate) {
    if (!d) return;
    d->frac = 0;
    d->avg_fill = 0;
    d->avg_valid = 0;
    d->prev_valid = 0;
    d->fade_in = DRIFT_FADE;
    if (!keep_rate) d->integ = 0;
    /* Restart from the learned clock offset so a re-prime doesn't re-converge from scratch. */
    d->ratio = 1.0 + d->integ;
}

double mc_audio_drift_ratio(const mc_audio_drift *d) { return d ? d->ratio : 1.0; }

static inline double drift_clamp(double v, double lim) { return v > lim ? lim : (v < -lim ? -lim : v); }

int mc_audio_drift_read(mc_audio_drift *d, const float *ring, int capacity, int read_index, int available,
                        int target, float *out, int frames, int *consumed) {
    if (consumed) *consumed = 0;
    if (!d || !ring || !out || capacity <= 0 || frames <= 0) return 0;
    if (available > capacity) available = capacity;
    if (read_index < 0 || read_index >= capacity) read_index = 0;

    const double ratio = d->ratio;
    double frac = d->frac;
    int base = 0;                         /* ring frames consumed so far */
    int i0 = read_index;                  /* ring slot of x[0] */
    float pl = d->prev[0], pr = d->prev[1];
    int produced = 0;
    for (; produced < frames; produced++) {
        if (base + 3 > available) break;  /* need x[0], x[1], x[2] */
        int i1 = i0 + 1; if (i1 >= capacity) i1 -= capacity;
        int i2 = i1 + 1; if (i2 >= capacity) i2 -= capacity;
        const float *a = ring + i0 * 2, *b = ring + i1 * 2, *c = ring + i2 * 2;
        if (!d->prev_valid) { pl = a[0]; pr = a[1]; d->prev_valid = 1; }
        float t = (float)frac;
        /* Catmull-Rom; exact pass-through when frac == 0. */
        float c1 = 0.5f * (b[0] - pl);
        float c2 = pl - 2.5f * a[0] + 2.0f * b[0] - 0.5f * c[0];
        float c3 = 0.5f * (c[0] - pl) + 1.5f * (a[0] - b[0]);
        out[produced * 2] = ((c3 * t + c2) * t + c1) * t + a[0];
        c1 = 0.5f * (b[1] - pr);
        c2 = pr - 2.5f * a[1] + 2.0f * b[1] - 0.5f * c[1];
        c3 = 0.5f * (c[1] - pr) + 1.5f * (a[1] - b[1]);
        out[produced * 2 + 1] = ((c3 * t + c2) * t + c1) * t + a[1];
        frac += ratio;
        while (frac >= 1.0) {
            pl = ring[i0 * 2]; pr = ring[i0 * 2 + 1];
            frac -= 1.0;
            base++;
            if (++i0 >= capacity) i0 = 0;
        }
    }
    d->frac = frac;
    d->prev[0] = pl; d->prev[1] = pr;
    if (consumed) *consumed = base;

    /* Short fades instead of hard steps where the stream starts or breaks. */
    if (d->fade_in > 0 && produced > 0) {
        int done = DRIFT_FADE - d->fade_in;
        int n = d->fade_in < produced ? d->fade_in : produced;
        for (int i = 0; i < n; i++) {
            float g = (float)(done + i + 1) / (float)DRIFT_FADE;
            out[i * 2] *= g; out[i * 2 + 1] *= g;
        }
        d->fade_in -= n;
    }
    if (produced < frames) {
        int n = produced < DRIFT_FADE ? produced : DRIFT_FADE;
        for (int i = 0; i < n; i++) {
            float g = (float)(n - i - 1) / (float)n;
            float *p = out + (produced - n + i) * 2;
            p[0] *= g; p[1] *= g;
        }
        for (int i = produced; i < frames; i++) { out[i * 2] = 0; out[i * 2 + 1] = 0; }
        /* Caller re-primes; the next stream fades in from a fresh phase. */
        d->fade_in = DRIFT_FADE;
        d->prev_valid = 0;
        d->frac = 0;
        d->avg_valid = 0;
        return produced;
    }

    /* PI control on the fill level after this read. */
    double dt = (double)frames / DRIFT_RATE;
    double fill = (double)(available - base);
    if (!d->avg_valid) { d->avg_fill = fill; d->avg_valid = 1; }
    else {
        double k = dt / DRIFT_FILL_TAU;
        d->avg_fill += (fill - d->avg_fill) * (k < 1 ? k : 1);
    }
    double err = (d->avg_fill - (double)target) / DRIFT_RATE;          /* seconds of excess audio */
    d->integ = drift_clamp(d->integ + DRIFT_KI * err * dt, DRIFT_MAX_DEV); /* anti-windup */
    double want = 1.0 + drift_clamp(DRIFT_KP * err + d->integ, DRIFT_MAX_DEV);
    d->ratio += drift_clamp(want - d->ratio, DRIFT_SLEW * dt);
    return produced;
}
