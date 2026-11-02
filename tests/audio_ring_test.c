#include "mc_core.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

enum { CAPACITY = 1024, BATCH = 64, BATCHES = 10000 };
static mc_audio_ring *ring;
static atomic_int producer_done;
static atomic_int failed;

static void *produce(void *unused) {
    (void)unused;
    float samples[BATCH * 2];
    int sequence = 0;
    for (int batch = 0; batch < BATCHES; batch++) {
        for (int i = 0; i < BATCH; i++) {
            samples[i * 2] = (float)(sequence + i);
            samples[i * 2 + 1] = -(float)(sequence + i);
        }
        int offset = 0;
        while (offset < BATCH) {
            int wrote = mc_audio_ring_write(ring, samples + offset * 2, BATCH - offset);
            offset += wrote;
            if (!wrote) usleep(100);
        }
        sequence += BATCH;
    }
    atomic_store(&producer_done, 1);
    return NULL;
}

static void *consume(void *unused) {
    (void)unused;
    float samples[BATCH * 2];
    int expected = 0;
    for (;;) {
        int got = mc_audio_ring_read(ring, samples, BATCH);
        for (int i = 0; i < got; i++, expected++) {
            if (samples[i * 2] != (float)expected || samples[i * 2 + 1] != -(float)expected)
                atomic_store(&failed, 1);
        }
        if (atomic_load(&producer_done) && mc_audio_ring_available(ring) == 0) break;
        if (!got) usleep(100);
    }
    if (expected != BATCH * BATCHES) atomic_store(&failed, 1);
    return NULL;
}

int main(void) {
    mc_audio_ring *small = mc_audio_ring_create(8);
    float src[20], dst[20];
    for (int i = 0; i < 10; i++) { src[i * 2] = (float)i; src[i * 2 + 1] = -(float)i; }
    if (!small || mc_audio_ring_write(small, src, 10) != 8 || mc_audio_ring_available(small) != 8 ||
        mc_audio_ring_read(small, dst, 8) != 8 || mc_audio_ring_available(small) != 0) return 1;
    for (int i = 0; i < 8; i++) if (dst[i * 2] != (float)i || dst[i * 2 + 1] != -(float)i) return 2;
    mc_audio_ring_destroy(small);

    ring = mc_audio_ring_create(CAPACITY);
    if (!ring) return 3;
    pthread_t writer, reader;
    if (pthread_create(&writer, NULL, produce, NULL) || pthread_create(&reader, NULL, consume, NULL)) return 4;
    pthread_join(writer, NULL);
    pthread_join(reader, NULL);
    mc_audio_ring_destroy(ring);
    if (atomic_load(&failed)) return 5;
    puts("SPSC ring: wraparound, bounded overflow, and concurrent sequence integrity OK");
    return 0;
}
