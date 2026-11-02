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
