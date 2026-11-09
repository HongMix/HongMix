/* Clock-drift compensation test for mc_audio_drift_read (live input audio in AudioMixer).
   Simulates a live source whose clock runs at 48 000 * (1 + ppm/1e6) Hz delivering bursty
   chunks into a 2 s circular buffer, and the mixer consuming 800-frame ticks (60 fps) at
   exactly 48 kHz with scheduling jitter, for 10 minutes of audio per case. Asserts:
   - no underruns and no last-resort skips after the initial prime,
   - the 1 s average fill stays within ±20 ms of the 120 ms target after settling,
   - the output stays continuous (a 440 Hz sine has no sample-to-sample jumps).

   cc -std=gnu11 -O2 -ISources/Core tests/audio_drift_test.c Sources/Core/mc_audio_ring.c -lm -o /tmp/audio_drift_test && /tmp/audio_drift_test */
#include "mc_core.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

enum { RATE = 48000, CAP = 96000, TARGET = 5760, TICK = 800, SKIP_EXCESS = 24000 };

typedef struct { double ppm; int chunk; double jitter_ms; double stall_at; } drift_case; /* stall_at: 300 ms source outage */

static float ring[CAP * 2];

static int run(drift_case c) {
    mc_audio_drift *d = mc_audio_drift_create();
    if (!d) return 1;
    int read_idx = 0, count = 0;
    double src_rate = RATE * (1.0 + c.ppm * 1e-6);
    double phase = 0, w = 2 * M_PI * 440.0 / src_rate;
    double t_prod = 0, t_cons = 0, duration = 600.0;
    unsigned rng = 12345;
    int primed = 0, underruns = 0, skips = 0, overflows = 0;
    double max_err_ms = 0, max_err_settled_ms = 0, max_jump = 0, min_fill_ms = 1e9, avg = 0;
    float out[TICK * 2], last_l = 0;
    int have_last = 0, have_avg = 0, stalled = 0;
    while (t_cons < duration) {
        /* consumer tick fires at the 48 kHz schedule plus scheduling jitter; the producer
           delivers every chunk whose source-clock time has passed by then */
        rng = rng * 1103515245u + 12345u;
        double jit = (((rng >> 8) & 0xffff) / 65535.0 - 0.5) * 2 * c.jitter_ms / 1000.0;
        double now = t_cons + jit;
        while (t_prod <= now) {
            if (c.stall_at > 0 && !stalled && t_prod >= c.stall_at) { t_prod += 0.3; stalled = 1; continue; }
            for (int i = 0; i < c.chunk; i++) {
                if (count == CAP) { read_idx = (read_idx + 1) % CAP; count--; overflows++; }
                int wpos = (read_idx + count) % CAP;
                float s = (float)(0.5 * sin(phase));
                phase += w; if (phase > 2 * M_PI) phase -= 2 * M_PI;
                ring[wpos * 2] = s; ring[wpos * 2 + 1] = -s;
                count++;
            }
            t_prod += c.chunk / src_rate;
        }
        t_cons += (double)TICK / RATE;
        if (!primed) {
            if (count >= TICK + TARGET) { primed = 1; mc_audio_drift_reset(d, 1); }
            else continue;
        }
        if (count > TICK + TARGET + SKIP_EXCESS) {
            int k = count - TICK - TARGET;
            read_idx = (read_idx + k) % CAP; count -= k; skips++;
            mc_audio_drift_reset(d, 1);
        }
        int consumed = 0;
        int got = mc_audio_drift_read(d, ring, CAP, read_idx, count, TARGET, out, TICK, &consumed);
        read_idx = (read_idx + consumed) % CAP; count -= consumed;
        if (got < TICK) { underruns++; primed = 0; }
        double fill_ms = count * 1000.0 / RATE;
        avg = !have_avg ? fill_ms : avg + (fill_ms - avg) * ((double)TICK / RATE);
        have_avg = 1;
        double err = fabs(avg - TARGET * 1000.0 / RATE);
        if (err > max_err_ms) max_err_ms = err;
        if (t_cons > 30 && err > max_err_settled_ms) max_err_settled_ms = err;
        if (t_cons > 1 && fill_ms < min_fill_ms) min_fill_ms = fill_ms;
        /* continuity: a 440 Hz sine at 0.5 changes by ≤ 0.029 per sample; allow resampling slop */
        for (int i = 0; i < got; i++) {
            if (have_last && t_cons > 0.1) {
                double j = fabs(out[i * 2] - last_l);
                if (j > max_jump) max_jump = j;
            }
            last_l = out[i * 2]; have_last = 1;
        }
    }
    int fail = underruns != (c.stall_at > 0) || skips > 0 || overflows > 0 || max_err_settled_ms > 20.0 || max_jump > 0.04;
    printf("%s ppm=%+6.0f chunk=%4d jitter=%2.0fms | ratio=%+.0f ppm | avg-fill err max %.2f ms (settled %.2f ms) | "
           "min fill %.1f ms | underruns %d skips %d overflow %d | max step %.4f\n",
           fail ? "FAIL" : "ok  ", c.ppm, c.chunk, c.jitter_ms, (mc_audio_drift_ratio(d) - 1) * 1e6,
           max_err_ms, max_err_settled_ms, min_fill_ms, underruns, skips, overflows, max_jump);
    mc_audio_drift_destroy(d);
    return fail;
}

int main(void) {
    const drift_case cases[] = {
        { +1000, 512, 2, 0 },  { -1000, 512, 2, 0 },   /* ±0.1 % (48048 / 47952 Hz), capture-sized chunks */
        { +1000, 1600, 8, 0 }, { -1000, 1600, 8, 0 },  /* NDI/DeckLink: one chunk per 30 fps frame */
        { +100, 480, 4, 0 },   { -100, 480, 4, 0 },
        { +3000, 1024, 4, 0 }, { -3000, 1024, 4, 0 },  /* ±0.3 % */
        { 0, 4096, 10, 0 },
        { +1000, 512, 2, 60.0 },                /* one 300 ms outage: exactly one underrun, then re-prime */
    };
    int failures = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) failures += run(cases[i]);
    printf(failures ? "%d case(s) FAILED\n" : "all cases passed\n", failures);
    return failures ? 1 : 0;
}
