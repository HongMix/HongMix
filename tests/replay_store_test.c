// Replay store: the real-time write path must not wait for the disk, and everything accepted must read
// back intact (from the queue while pending, from disk afterwards).
//
//   cc -std=gnu11 -O2 -ISources/Core $(pkg-config --cflags libavcodec) tests/replay_store_test.c \
//      Sources/Core/mc_replay.c $(pkg-config --libs libavcodec libswscale libavutil) \
//      -framework CoreVideo -framework CoreFoundation -o /tmp/replay_store_test && /tmp/replay_store_test
#include "mc_core.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

extern void (*mc_replay_debug_write_hook)(int stream, int size);

enum { STREAMS = 3, AUDIO = 2, FRAMES = 1200 };

static atomic_int failures;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); atomic_fetch_add(&failures, 1); } } while (0)

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int packet_size(int stream, int64_t frame) {
    if (stream == AUDIO) return 800 * 2 * 4;
    return 200000 + (int)((frame * 7919 + stream * 104729) % 120000);   // ~200–320 KB "video"
}

static void fill(uint8_t *p, int size, int stream, int64_t frame) {
    uint32_t x = (uint32_t)(frame * 2654435761u) ^ (uint32_t)(stream * 40503u + 1);
    for (int i = 0; i < size; i++) { x = x * 1664525u + 1013904223u; p[i] = (uint8_t)(x >> 24); }
    memcpy(p, &frame, sizeof(frame));
}

static int verify(const uint8_t *p, int size, int stream, int64_t frame) {
    static __thread uint8_t *ref;
    static __thread int cap;
    if (size != packet_size(stream, frame)) return 0;
    if (cap < size) { free(ref); ref = malloc((size_t)size); cap = size; }
    fill(ref, size, stream, frame);
    return memcmp(ref, p, (size_t)size) == 0;
}

/* ---- slow disk ---- */
static atomic_int slow_mode;        // 0 = off, 1 = ~800 MB/s with a 150 ms stall every 600 packets, 2 = one 1.5 s stall
static atomic_int hook_calls;
static void slow_disk(int stream, int size) {
    (void)stream;
    int n = atomic_fetch_add(&hook_calls, 1);
    int m = atomic_load(&slow_mode);
    if (m == 1) {
        usleep((useconds_t)(size / 800));                 // 800 bytes/µs
        if (n % 600 == 599) usleep(150000);               // spinning up / metadata flush
    } else if (m == 2 && n == 20) {
        usleep(1500000);
    }
}

/* ---- render-thread producer ---- */
typedef struct {
    mc_replay_store *st;
    int frames;
    int frame_us;                   // pacing per frame
    uint8_t accepted[STREAMS][FRAMES];
    double max_ms, total_ms;
    int calls, drops;
    atomic_int done;
    atomic_llong head;
} producer;

static void *produce(void *arg) {
    producer *p = arg;
    uint8_t *buf = malloc(400000);
    for (int64_t f = 0; f < p->frames; f++) {
        double t0 = now_ms();
        for (int s = 0; s < STREAMS; s++) {
            int size = packet_size(s, f);
            fill(buf, size, s, f);
            double a = now_ms();
            int r = mc_replay_store_write(p->st, s, f, buf, size);
            double dt = now_ms() - a;
            if (dt > p->max_ms) p->max_ms = dt;
            p->total_ms += dt;
            p->calls++;
            p->accepted[s][f] = r == 0;
            if (r != 0) p->drops++;
        }
        atomic_store(&p->head, f);
        double spent = (now_ms() - t0) * 1000;
        if (spent < p->frame_us) usleep((useconds_t)(p->frame_us - spent));
    }
    free(buf);
    atomic_store(&p->done, 1);
    return NULL;
}

/* ---- concurrent reader (player): recent frames, often still queued ---- */
static void *reader(void *arg) {
    producer *p = arg;
    int reads = 0;
    unsigned seed = 7;
    while (!atomic_load(&p->done)) {
        int64_t h = atomic_load(&p->head);
        if (h < 1) { usleep(200); continue; }
        int s = (int)(rand_r(&seed) % STREAMS);
        int64_t f = h - (rand_r(&seed) % 8);
        if (f < 0) f = 0;
        uint8_t *d = NULL;
        int64_t got = -1;
        int n = mc_replay_store_read(p->st, s, f, &d, &got);
        if (n > 0) {
            CHECK(got <= f, "read returned a newer frame %lld > %lld", (long long)got, (long long)f);
            CHECK(verify(d, n, s, got), "corrupt packet stream %d frame %lld (live read)", s, (long long)got);
            reads++;
        }
        free(d);
        usleep(500);
    }
    printf("  concurrent reads verified: %d\n", reads);
    return NULL;
}

static void readback(mc_replay_store *st, producer *p, int64_t from, const char *what) {
    int ok = 0;
    for (int s = 0; s < STREAMS; s++) {
        for (int64_t f = from; f < p->frames; f++) {
            if (!p->accepted[s][f]) continue;
            uint8_t *d = NULL;
            int64_t got = -1;
            int n = mc_replay_store_read(st, s, f, &d, &got);
            CHECK(n > 0 && got == f, "%s: stream %d frame %lld missing (n=%d got=%lld)", what, s, (long long)f, n, (long long)got);
            if (n > 0 && got == f) {
                CHECK(verify(d, n, s, f), "%s: stream %d frame %lld corrupt", what, s, (long long)f);
                ok++;
            }
            free(d);
        }
    }
    printf("  %s: %d packets read back intact\n", what, ok);
}

static producer *run(mc_replay_store *st, int frames, int frame_us) {
    producer *p = calloc(1, sizeof(*p));
    p->st = st; p->frames = frames; p->frame_us = frame_us;
    pthread_t a, b;
    double t0 = now_ms();
    pthread_create(&a, NULL, produce, p);
    pthread_create(&b, NULL, reader, p);
    pthread_join(a, NULL);
    pthread_join(b, NULL);
    double mb = 0;
    for (int s = 0; s < STREAMS; s++) for (int f = 0; f < frames; f++) mb += packet_size(s, f) / 1e6;
    printf("  wrote %.0f MB in %.2f s: enqueue max %.3f ms, avg %.4f ms, drops %d\n",
           mb, (now_ms() - t0) / 1000, p->max_ms, p->total_ms / p->calls, p->drops);
    return p;
}

int main(void) {
    char dir[256];
    snprintf(dir, sizeof(dir), "/tmp/replay_store_test_%d", (int)getpid());
    mc_replay_debug_write_hook = slow_disk;

    // 1) slow disk with stalls, queue large enough: no drops, enqueue stays sub-millisecond
    printf("1) slow writer, 96 MB queue\n");
    atomic_store(&slow_mode, 1);
    mc_replay_store *st = mc_replay_store_open2(dir, STREAMS, 120, 96LL << 20, 0);
    CHECK(st != NULL, "open");
    producer *p = run(st, FRAMES, 2500);
    mc_replay_store_stats ss;
    mc_replay_store_get_stats(st, &ss);
    printf("  queue now %lld KB (peak %lld MB of %lld MB), write errors %lld\n", (long long)ss.queued_bytes / 1024,
           (long long)ss.max_queued_bytes >> 20, (long long)ss.queue_capacity >> 20, (long long)ss.write_errors);
    CHECK(p->max_ms < 1.0, "enqueue took %.3f ms", p->max_ms);
    CHECK(p->drops == 0, "%d drops with a big enough queue", p->drops);
    CHECK(ss.max_queued_bytes > (8 << 20), "the slow writer never built a backlog (test not exercising the queue)");
    readback(st, p, 0, "before flush (queue + disk)");
    atomic_store(&slow_mode, 0);
    mc_replay_store_flush(st);
    mc_replay_store_get_stats(st, &ss);
    CHECK(ss.queued_packets == 0, "flush left %d packets", ss.queued_packets);
    readback(st, p, 0, "after flush (disk)");
    CHECK(mc_replay_store_first(st, AUDIO) == 0 && mc_replay_store_last(st, AUDIO) == FRAMES - 1, "first/last");
    int64_t disk = mc_replay_store_bytes(st);

    // 2) segment recycling on the writer thread: limit to ~1/3, oldest segments go, the rest stays intact
    printf("2) limit → oldest segments recycled by the writer\n");
    mc_replay_store_set_limit(st, disk / 3);
    for (int i = 0; i < 200 && mc_replay_store_bytes(st) > disk / 3; i++) usleep(5000);
    int64_t first = mc_replay_store_first(st, AUDIO);
    printf("  %lld MB → %lld MB, first frame %lld\n", (long long)disk >> 20, (long long)mc_replay_store_bytes(st) >> 20, (long long)first);
    CHECK(mc_replay_store_bytes(st) <= disk / 3 && first > 0, "limit not enforced");
    readback(st, p, first, "after recycling");
    mc_replay_store_close(st, 1);
    free(p);

    // 3) disk stalls for 1.5 s with a small queue: the producer drops (counted) instead of waiting
    printf("3) 1.5 s stall, 16 MB queue\n");
    atomic_store(&hook_calls, 0);
    atomic_store(&slow_mode, 2);
    st = mc_replay_store_open2(dir, STREAMS, 120, 16LL << 20, 0);
    p = run(st, 300, 2000);
    mc_replay_store_get_stats(st, &ss);
    CHECK(p->max_ms < 1.0, "enqueue took %.3f ms", p->max_ms);
    CHECK(p->drops > 0 && ss.dropped_packets == p->drops, "expected counted drops (%d / %lld)", p->drops, (long long)ss.dropped_packets);
    printf("  stats: dropped %lld packets / %lld MB\n", (long long)ss.dropped_packets, (long long)ss.dropped_bytes >> 20);
    mc_replay_store_close(st, 0);              // keep files: drains the queue, then joins
    free(p);

    // 4) close / clear with a backlog: no hang, no use-after-free (run under -fsanitize=address/thread)
    printf("4) clear and close with a backlog\n");
    atomic_store(&slow_mode, 1);
    st = mc_replay_store_open2(dir, STREAMS, 120, 32LL << 20, 0);
    p = run(st, 120, 0);
    mc_replay_store_clear(st);
    CHECK(mc_replay_store_bytes(st) == 0 && mc_replay_store_first(st, 0) == -1, "clear");
    free(p);
    p = run(st, 60, 0);
    readback(st, p, 0, "after clear + rewrite");
    double t0 = now_ms();
    mc_replay_store_close(st, 1);
    printf("  close(delete) with backlog took %.1f ms\n", now_ms() - t0);
    free(p);

    // 5) blocking mode (offline renders): nothing dropped even with a tiny queue
    printf("5) blocking store, 2 MB queue\n");
    st = mc_replay_store_open2(dir, STREAMS, 120, 2LL << 20, 1);
    p = run(st, 120, 0);
    CHECK(p->drops == 0, "blocking store dropped %d", p->drops);
    mc_replay_store_flush(st);
    readback(st, p, 0, "blocking");
    mc_replay_store_close(st, 1);
    free(p);

    int f = atomic_load(&failures);
    printf(f ? "FAILED (%d)\n" : "OK\n", f);
    return f ? 1 : 0;
}
