// Instant replay: frame-indexed packet store on disk + intra-frame decoder.
//
// Each stream (one per recorded camera, one for audio) is written as segment files that cover the same
// frame range for every stream (seg_frames frames each), so the oldest segment can be dropped for all
// streams at once (ring buffer when the disk limit is reached). The index (frame → file offset) is kept
// in memory; video packets are intra-only H.264, so any frame decodes on its own (scrub, slow motion, reverse).
#include "mc_core.h"
#include "mc_util.h"

#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libavutil/hwcontext.h>
#ifdef __APPLE__
#include <CoreVideo/CoreVideo.h>
#endif
#include <libavutil/opt.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>

#ifdef __APPLE__
#include <pthread/qos.h>
#endif

/* Threading:
 *  - Producers (render thread: audio streams; encoder threads: video packets) call mc_replay_store_write,
 *    which only memcpys the packet into a bounded byte ring (q_lock) and never touches the disk or waits
 *    for it. When the ring is full the packet is dropped and counted (or, for a store opened with
 *    block_when_full, the caller waits — used for non-real-time stores such as AI clip renders).
 *  - One writer thread per store drains the ring FIFO: open/write/ftruncate/unlink happen only there.
 *    It holds w_lock around each packet; the index (lock) gets the packet's entry only after its bytes
 *    are on disk, so readers never see an entry for data that is not there yet.
 *  - Readers look in the not-yet-written queue first (newest packets), then in the index.
 *  Lock order: w_lock → q_lock, w_lock → lock. q_lock and lock are never held together. */

typedef struct {
    int64_t frame;
    int64_t off;
    int size;
    int seg;
} rp_entry;

typedef struct {
    rp_entry *e;
    int64_t head, count, cap;   // ring of entries (oldest at head)
    int w_fd, w_seg;            // writer side: only touched under w_lock
    int64_t w_off;
    int r_fd, r_seg;            // reader side: lock
} rp_stream;

typedef struct {
    int64_t frame;
    uint64_t start, end;        // absolute ring offsets: data at start % ring_cap; popping frees up to end
    int size;
    int stream;
} rp_pending;

struct mc_replay_store {
    char *dir;
    int n;
    int seg_frames;
    int64_t frame0;             // first frame ever written (-1 = none): segment = (frame - frame0) / seg_frames
    int64_t bytes, limit;
    int low_seg;                // oldest segment still on disk
    rp_stream *s;
    pthread_mutex_t lock;       // index, bytes, limit, read fds. Mutated only by w_lock holders (+ limit).

    // write queue (q_lock)
    pthread_mutex_t q_lock;
    pthread_cond_t q_work;      // writer: packets queued, limit changed, or stop
    pthread_cond_t q_done;      // a packet left the queue (blocking producers, flush)
    uint8_t *ring;
    uint64_t ring_cap, ring_w, ring_r;
    rp_pending *pq;
    int pq_cap, pq_head, pq_count;
    uint64_t pq_seq;            // sequence number of pq[pq_head]; monotonic, also across clear
    int *pend_n;                // per stream: packets still queued
    int64_t *last_enq;          // per stream: newest frame accepted (-1 = none)
    int block_when_full;
    int stop, enforce;
    int64_t dropped, dropped_bytes, write_errors;
    uint64_t max_queued;

    pthread_mutex_t w_lock;     // writer holds it around each packet's I/O; clear/close take it to exclude it
    pthread_t thread;
    int thread_ok;
};

/* Test hook: called on the writer thread before each packet's write (simulates a slow disk). */
void (*mc_replay_debug_write_hook)(int stream, int size) = NULL;

#define RP_DEFAULT_QUEUE (64LL << 20)
#define RP_QUEUE_PACKETS 16384

static void seg_path(mc_replay_store *st, int stream, int seg, char *buf, size_t n) {
    snprintf(buf, n, "%s/s%02d_%06d.bin", st->dir, stream, seg);
}

static void *writer_main(void *arg);

static void store_free(mc_replay_store *st) {
    for (int i = 0; st->s && i < st->n; i++) free(st->s[i].e);
    free(st->s);
    free(st->ring);
    free(st->pq);
    free(st->pend_n);
    free(st->last_enq);
    free(st->dir);
    pthread_mutex_destroy(&st->lock);
    pthread_mutex_destroy(&st->q_lock);
    pthread_mutex_destroy(&st->w_lock);
    pthread_cond_destroy(&st->q_work);
    pthread_cond_destroy(&st->q_done);
    free(st);
}

mc_replay_store *mc_replay_store_open2(const char *dir, int streams, int seg_frames, int64_t queue_bytes,
                                       int block_when_full) {
    if (!dir || streams <= 0) return NULL;
    mkdir(dir, 0755);
    if (queue_bytes <= 0) queue_bytes = RP_DEFAULT_QUEUE;
    if (queue_bytes < (1 << 20)) queue_bytes = 1 << 20;
    mc_replay_store *st = (mc_replay_store *)calloc(1, sizeof(*st));
    pthread_mutex_init(&st->lock, NULL);
    pthread_mutex_init(&st->q_lock, NULL);
    pthread_mutex_init(&st->w_lock, NULL);
    pthread_cond_init(&st->q_work, NULL);
    pthread_cond_init(&st->q_done, NULL);
    st->dir = strdup(dir);
    st->n = streams;
    st->seg_frames = seg_frames > 0 ? seg_frames : 3600;
    st->frame0 = -1;
    st->block_when_full = block_when_full;
    st->s = (rp_stream *)calloc((size_t)streams, sizeof(rp_stream));
    // preallocated once: producers never allocate
    st->ring_cap = (uint64_t)queue_bytes;
    st->ring = (uint8_t *)malloc((size_t)st->ring_cap);
    st->pq_cap = RP_QUEUE_PACKETS;
    st->pq = (rp_pending *)calloc((size_t)st->pq_cap, sizeof(rp_pending));
    st->pend_n = (int *)calloc((size_t)streams, sizeof(int));
    st->last_enq = (int64_t *)malloc((size_t)streams * sizeof(int64_t));
    if (!st->dir || !st->s || !st->ring || !st->pq || !st->pend_n || !st->last_enq) { store_free(st); return NULL; }
    memset(st->ring, 0, (size_t)st->ring_cap);   // fault the pages in now, not on the render thread's first lap
    for (int i = 0; i < streams; i++) {
        st->s[i].w_fd = st->s[i].r_fd = -1;
        st->s[i].w_seg = st->s[i].r_seg = -1;
        st->last_enq[i] = -1;
    }
    // leftovers from an earlier session in this folder are not indexed → remove them
    DIR *d = opendir(dir);
    if (d) {
        struct dirent *de;
        char p[1100];
        while ((de = readdir(d))) {
            if (de->d_name[0] == 's' && strstr(de->d_name, ".bin")) {
                snprintf(p, sizeof(p), "%s/%s", dir, de->d_name);
                unlink(p);
            }
        }
        closedir(d);
    }
    if (pthread_create(&st->thread, NULL, writer_main, st) != 0) { store_free(st); return NULL; }
    st->thread_ok = 1;
    return st;
}

mc_replay_store *mc_replay_store_open(const char *dir, int streams, int seg_frames) {
    return mc_replay_store_open2(dir, streams, seg_frames, 0, 0);
}

/* Caller holds w_lock and lock. */
static void drop_segment_locked(mc_replay_store *st, int seg) {
    char p[1100];
    for (int i = 0; i < st->n; i++) {
        rp_stream *s = &st->s[i];
        while (s->count > 0 && s->e[s->head % s->cap].seg <= seg) {
            st->bytes -= s->e[s->head % s->cap].size;
            s->head++;
            s->count--;
        }
        if (s->r_seg == seg && s->r_fd >= 0) { close(s->r_fd); s->r_fd = -1; s->r_seg = -1; }
        if (s->w_seg == seg && s->w_fd >= 0) { close(s->w_fd); s->w_fd = -1; }
        seg_path(st, i, seg, p, sizeof(p));
        unlink(p);
    }
    if (st->low_seg <= seg) st->low_seg = seg + 1;
}

/* Oldest segment that is not being written by any stream. -1 = none can be dropped. */
static int droppable_segment_locked(mc_replay_store *st) {
    int newest = -1;
    for (int i = 0; i < st->n; i++) if (st->s[i].w_seg > newest) newest = st->s[i].w_seg;
    return st->low_seg < newest ? st->low_seg : -1;
}

static void enforce_limit_locked(mc_replay_store *st) {
    while (st->limit > 0 && st->bytes > st->limit) {
        int seg = droppable_segment_locked(st);
        if (seg < 0) break;
        drop_segment_locked(st, seg);
    }
}

/* Writer thread (w_lock held): writes one queued packet, then publishes its index entry. 0 = ok. */
static int writer_put(mc_replay_store *st, const rp_pending *d) {
    const uint8_t *data = st->ring + d->start % st->ring_cap;
    rp_stream *s = &st->s[d->stream];
    pthread_mutex_lock(&st->lock);
    if (st->frame0 < 0) st->frame0 = d->frame;
    int dup = s->count > 0 && d->frame <= s->e[(s->head + s->count - 1) % s->cap].frame;
    int seg = (int)((d->frame - st->frame0) / st->seg_frames);
    pthread_mutex_unlock(&st->lock);
    if (dup) return 0;                                  // out of order: ignore
    if (mc_replay_debug_write_hook) mc_replay_debug_write_hook(d->stream, d->size);
    int ok = 0;
    for (int attempt = 0; attempt < 2 && !ok; attempt++) {
        if (seg < st->low_seg) seg = st->low_seg;       // low_seg only moves under w_lock (held)
        if (s->w_fd < 0 || s->w_seg != seg) {
            if (s->w_fd >= 0) close(s->w_fd);
            char p[1100];
            seg_path(st, d->stream, seg, p, sizeof(p));
            s->w_fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0600);
            s->w_seg = seg;
            struct stat sb;
            s->w_off = (s->w_fd >= 0 && fstat(s->w_fd, &sb) == 0) ? sb.st_size : 0;
        }
        if (s->w_fd >= 0) {
            const uint8_t *p = data;
            int left = d->size;
            while (left > 0) {
                ssize_t w = write(s->w_fd, p, (size_t)left);
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) break;
                p += w; left -= (int)w;
            }
            if (left == 0) { ok = 1; break; }
            // disk full: give back the partial write
            if (ftruncate(s->w_fd, s->w_off) != 0) { /* best effort */ }
        }
        if (attempt == 1) break;
        // drop the oldest segment (all streams) and try once more; this may close our own fd (reopened above)
        pthread_mutex_lock(&st->lock);
        int old = droppable_segment_locked(st);
        if (old >= 0) drop_segment_locked(st, old);
        pthread_mutex_unlock(&st->lock);
        if (old < 0) break;
    }
    if (!ok) return -1;
    int64_t off = s->w_off;
    s->w_off += d->size;
    // publish only now that the bytes are in the file
    pthread_mutex_lock(&st->lock);
    int indexed = 1;
    if (s->count == s->cap) {
        int64_t nc = s->cap ? s->cap * 2 : 8192;
        rp_entry *ne = (rp_entry *)malloc((size_t)nc * sizeof(rp_entry));
        if (ne) {
            for (int64_t i = 0; i < s->count; i++) ne[i] = s->e[(s->head + i) % s->cap];
            free(s->e);
            s->e = ne; s->cap = nc; s->head = 0;
        } else {
            indexed = 0;
        }
    }
    if (indexed) {
        rp_entry *e = &s->e[(s->head + s->count) % s->cap];
        e->frame = d->frame; e->off = off; e->size = d->size; e->seg = seg;
        s->count++;
        st->bytes += d->size;
        enforce_limit_locked(st);
    }
    pthread_mutex_unlock(&st->lock);
    return indexed ? 0 : -1;
}

/* q_lock held: forget every queued packet (the writer is excluded by w_lock, so none is in flight). */
static void discard_queue_locked(mc_replay_store *st) {
    st->pq_seq += (uint64_t)st->pq_count;
    st->pq_count = 0;
    st->pq_head = 0;
    st->ring_r = st->ring_w = 0;
    for (int i = 0; i < st->n; i++) { st->pend_n[i] = 0; st->last_enq[i] = -1; }
    pthread_cond_broadcast(&st->q_done);
}

static void *writer_main(void *arg) {
    mc_replay_store *st = (mc_replay_store *)arg;
#ifdef __APPLE__
    pthread_setname_np("replay.writer");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
    for (;;) {
        pthread_mutex_lock(&st->q_lock);
        while (st->pq_count == 0 && !st->enforce && !st->stop) pthread_cond_wait(&st->q_work, &st->q_lock);
        int quit = st->stop && st->pq_count == 0;
        pthread_mutex_unlock(&st->q_lock);
        if (quit) break;

        pthread_mutex_lock(&st->w_lock);
        pthread_mutex_lock(&st->q_lock);
        int have = st->pq_count > 0;
        rp_pending d;
        if (have) d = st->pq[st->pq_head];
        int enforce = st->enforce;
        st->enforce = 0;
        pthread_mutex_unlock(&st->q_lock);
        if (enforce) {
            pthread_mutex_lock(&st->lock);
            enforce_limit_locked(st);
            pthread_mutex_unlock(&st->lock);
        }
        if (have) {
            int err = writer_put(st, &d);
            // clear/close cannot have touched the queue meanwhile (they need w_lock): the head is still d
            pthread_mutex_lock(&st->q_lock);
            st->pq_head = (st->pq_head + 1) % st->pq_cap;
            st->pq_count--;
            st->pq_seq++;
            st->pend_n[d.stream]--;
            st->ring_r = d.end;
            if (st->pq_count == 0) st->ring_r = st->ring_w = 0;   // empty: restart at 0 (no wrap padding)
            if (err) st->write_errors++;
            pthread_cond_broadcast(&st->q_done);
            pthread_mutex_unlock(&st->q_lock);
        }
        pthread_mutex_unlock(&st->w_lock);
    }
    return NULL;
}

/* Real-time safe: one memcpy under q_lock, no I/O, no allocation. */
int mc_replay_store_write(mc_replay_store *st, int stream, int64_t frame, const uint8_t *data, int size) {
    if (!st || stream < 0 || stream >= st->n || !data || size <= 0) return -1;
    int r = -1;
    pthread_mutex_lock(&st->q_lock);
    if (st->stop) goto out;
    if (frame <= st->last_enq[stream]) { r = 0; goto out; }   // out of order: ignore
    for (;;) {
        uint64_t pos = st->ring_w % st->ring_cap;
        uint64_t pad = pos + (uint64_t)size > st->ring_cap ? st->ring_cap - pos : 0;   // keep packets contiguous
        if ((uint64_t)size <= st->ring_cap && st->pq_count < st->pq_cap &&
            st->ring_w - st->ring_r + pad + (uint64_t)size <= st->ring_cap) {
            uint64_t start = st->ring_w + pad;
            memcpy(st->ring + start % st->ring_cap, data, (size_t)size);
            st->ring_w = start + (uint64_t)size;
            rp_pending *d = &st->pq[(st->pq_head + st->pq_count) % st->pq_cap];
            d->frame = frame; d->start = start; d->end = st->ring_w; d->size = size; d->stream = stream;
            st->pq_count++;
            st->pend_n[stream]++;
            st->last_enq[stream] = frame;
            if (st->ring_w - st->ring_r > st->max_queued) st->max_queued = st->ring_w - st->ring_r;
            pthread_cond_signal(&st->q_work);
            r = 0;
            break;
        }
        // full: the disk is not keeping up. Real-time callers drop rather than stall.
        if (!st->block_when_full || st->stop || (uint64_t)size > st->ring_cap) {
            st->dropped++;
            st->dropped_bytes += size;
            break;
        }
        pthread_cond_wait(&st->q_done, &st->q_lock);
    }
out:
    pthread_mutex_unlock(&st->q_lock);
    return r;
}

/* Newest still-queued packet of `stream` with frame <= `frame`, copied out.
   1 = found, 0 = none queued (look in the index), -1 = it was written meanwhile (look in the index). */
static int read_pending(mc_replay_store *st, int stream, int64_t frame, uint8_t **data, int *size, int64_t *got) {
    rp_pending d;
    uint64_t seq = 0;
    int found = 0;
    pthread_mutex_lock(&st->q_lock);
    if (st->pend_n[stream] > 0) {
        for (int i = st->pq_count - 1; i >= 0; i--) {
            const rp_pending *p = &st->pq[(st->pq_head + i) % st->pq_cap];
            if (p->stream == stream && p->frame <= frame) { d = *p; seq = st->pq_seq + (uint64_t)i; found = 1; break; }
        }
    }
    pthread_mutex_unlock(&st->q_lock);
    if (!found) return 0;
    uint8_t *buf = (uint8_t *)malloc((size_t)d.size + AV_INPUT_BUFFER_PADDING_SIZE);   // outside q_lock
    if (!buf) return 0;
    pthread_mutex_lock(&st->q_lock);
    int still = seq >= st->pq_seq && seq < st->pq_seq + (uint64_t)st->pq_count;
    if (still) memcpy(buf, st->ring + d.start % st->ring_cap, (size_t)d.size);
    pthread_mutex_unlock(&st->q_lock);
    if (!still) { free(buf); return -1; }
    memset(buf + d.size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    *data = buf; *size = d.size; *got = d.frame;
    return 1;
}

/* Oldest (newest = 0) or newest (newest = 1) queued frame of a stream, -1 = none. */
static int64_t pending_edge(mc_replay_store *st, int stream, int newest) {
    int64_t f = -1;
    pthread_mutex_lock(&st->q_lock);
    if (st->pend_n[stream] > 0) {
        for (int k = 0; k < st->pq_count; k++) {
            int i = newest ? st->pq_count - 1 - k : k;
            const rp_pending *p = &st->pq[(st->pq_head + i) % st->pq_cap];
            if (p->stream == stream) { f = p->frame; break; }
        }
    }
    pthread_mutex_unlock(&st->q_lock);
    return f;
}

int64_t mc_replay_store_first(mc_replay_store *st, int stream) {
    if (!st || stream < 0 || stream >= st->n) return -1;
    // queue first: a packet moving to the index meanwhile is then found there
    int64_t q = pending_edge(st, stream, 0);
    pthread_mutex_lock(&st->lock);
    rp_stream *s = &st->s[stream];
    int64_t f = s->count > 0 ? s->e[s->head % s->cap].frame : q;
    pthread_mutex_unlock(&st->lock);
    return f;
}

int64_t mc_replay_store_last(mc_replay_store *st, int stream) {
    if (!st || stream < 0 || stream >= st->n) return -1;
    int64_t q = pending_edge(st, stream, 1);      // queued packets are newer than any indexed one
    if (q >= 0) return q;
    pthread_mutex_lock(&st->lock);
    rp_stream *s = &st->s[stream];
    int64_t f = s->count > 0 ? s->e[(s->head + s->count - 1) % s->cap].frame : -1;
    pthread_mutex_unlock(&st->lock);
    return f;
}

int mc_replay_store_read(mc_replay_store *st, int stream, int64_t frame, uint8_t **data, int64_t *got_frame) {
    if (!st || stream < 0 || stream >= st->n || !data) return -1;
    *data = NULL;
    // Not yet on disk? Serve it from the queue. Queued packets are newer than every indexed one of the
    // stream, and a packet is indexed before it leaves the queue, so queue-then-index never misses one.
    int psize = 0;
    int64_t pframe = 0;
    if (read_pending(st, stream, frame, data, &psize, &pframe) == 1) {
        if (got_frame) *got_frame = pframe;
        return psize;
    }
    pthread_mutex_lock(&st->lock);
    rp_stream *s = &st->s[stream];
    if (s->count == 0 || frame < s->e[s->head % s->cap].frame) { pthread_mutex_unlock(&st->lock); return -1; }
    // binary search: newest entry with e.frame <= frame
    int64_t lo = 0, hi = s->count - 1;
    while (lo < hi) {
        int64_t mid = (lo + hi + 1) / 2;
        if (s->e[(s->head + mid) % s->cap].frame <= frame) lo = mid; else hi = mid - 1;
    }
    rp_entry e = s->e[(s->head + lo) % s->cap];
    if (s->r_fd < 0 || s->r_seg != e.seg) {
        if (s->r_fd >= 0) close(s->r_fd);
        char p[1100];
        seg_path(st, stream, e.seg, p, sizeof(p));
        s->r_fd = open(p, O_RDONLY);
        s->r_seg = e.seg;
    }
    int fd = s->r_fd;
    uint8_t *buf = fd >= 0 ? (uint8_t *)malloc((size_t)e.size + AV_INPUT_BUFFER_PADDING_SIZE) : NULL;
    int got = 0;
    while (buf && got < e.size) {
        ssize_t r = pread(fd, buf + got, (size_t)(e.size - got), e.off + got);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        got += (int)r;
    }
    pthread_mutex_unlock(&st->lock);
    if (!buf || got != e.size) { free(buf); return -1; }
    memset(buf + e.size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    *data = buf;
    if (got_frame) *got_frame = e.frame;
    return e.size;
}

void mc_replay_store_set_limit(mc_replay_store *st, int64_t max_bytes) {
    if (!st) return;
    pthread_mutex_lock(&st->lock);
    st->limit = max_bytes > 0 ? max_bytes : 0;
    pthread_mutex_unlock(&st->lock);
    // deleting segments is disk I/O: the writer thread does it
    pthread_mutex_lock(&st->q_lock);
    st->enforce = 1;
    pthread_cond_signal(&st->q_work);
    pthread_mutex_unlock(&st->q_lock);
}

int64_t mc_replay_store_bytes(mc_replay_store *st) {
    if (!st) return 0;
    pthread_mutex_lock(&st->lock);
    int64_t b = st->bytes;
    pthread_mutex_unlock(&st->lock);
    return b;
}

void mc_replay_store_flush(mc_replay_store *st) {
    if (!st) return;
    pthread_mutex_lock(&st->q_lock);
    while (st->pq_count > 0 && st->thread_ok) pthread_cond_wait(&st->q_done, &st->q_lock);
    pthread_mutex_unlock(&st->q_lock);
}

void mc_replay_store_get_stats(mc_replay_store *st, mc_replay_store_stats *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!st) return;
    pthread_mutex_lock(&st->q_lock);
    out->queued_packets = st->pq_count;
    out->queued_bytes = (int64_t)(st->ring_w - st->ring_r);
    out->max_queued_bytes = (int64_t)st->max_queued;
    out->queue_capacity = (int64_t)st->ring_cap;
    out->dropped_packets = st->dropped;
    out->dropped_bytes = st->dropped_bytes;
    out->write_errors = st->write_errors;
    pthread_mutex_unlock(&st->q_lock);
}

/* Caller holds w_lock and lock. */
static void clear_locked(mc_replay_store *st) {
    char p[1100];
    int top = st->low_seg;
    for (int i = 0; i < st->n; i++) if (st->s[i].w_seg > top) top = st->s[i].w_seg;
    for (int i = 0; i < st->n; i++) {
        rp_stream *s = &st->s[i];
        if (s->w_fd >= 0) close(s->w_fd);
        if (s->r_fd >= 0) close(s->r_fd);
        s->w_fd = s->r_fd = -1; s->w_seg = s->r_seg = -1;
        s->head = s->count = 0;
        for (int g = st->low_seg; g <= top; g++) { seg_path(st, i, g, p, sizeof(p)); unlink(p); }
    }
    st->bytes = 0;
    st->frame0 = -1;
    st->low_seg = 0;
}

void mc_replay_store_clear(mc_replay_store *st) {
    if (!st) return;
    pthread_mutex_lock(&st->w_lock);           // waits for the packet in flight (if any)
    pthread_mutex_lock(&st->q_lock);
    discard_queue_locked(st);
    pthread_mutex_unlock(&st->q_lock);
    pthread_mutex_lock(&st->lock);
    clear_locked(st);
    pthread_mutex_unlock(&st->lock);
    pthread_mutex_unlock(&st->w_lock);
}

/* Producers must be gone (encoders closed, render hook detached) before this is called. */
void mc_replay_store_close(mc_replay_store *st, int delete_files) {
    if (!st) return;
    if (delete_files) {
        // the files go away anyway: don't write what is still queued
        pthread_mutex_lock(&st->w_lock);
        pthread_mutex_lock(&st->q_lock);
        discard_queue_locked(st);
        st->stop = 1;
        pthread_cond_signal(&st->q_work);
        pthread_mutex_unlock(&st->q_lock);
        pthread_mutex_unlock(&st->w_lock);
    } else {
        // keep the footage: the writer drains the queue before it exits
        pthread_mutex_lock(&st->q_lock);
        st->stop = 1;
        pthread_cond_signal(&st->q_work);
        pthread_cond_broadcast(&st->q_done);
        pthread_mutex_unlock(&st->q_lock);
    }
    if (st->thread_ok) pthread_join(st->thread, NULL);
    st->thread_ok = 0;
    pthread_mutex_lock(&st->w_lock);
    pthread_mutex_lock(&st->lock);
    if (delete_files) {
        clear_locked(st);
        rmdir(st->dir);
    } else {
        for (int i = 0; i < st->n; i++) {
            if (st->s[i].w_fd >= 0) close(st->s[i].w_fd);
            if (st->s[i].r_fd >= 0) close(st->s[i].r_fd);
        }
    }
    pthread_mutex_unlock(&st->lock);
    pthread_mutex_unlock(&st->w_lock);
    store_free(st);
}

/* ---- packet sink ---- */

struct mc_replay_sink {
    mc_replay_store *st;
    int stream;
};

mc_replay_sink *mc_replay_sink_new(mc_replay_store *st, int stream) {
    mc_replay_sink *s = (mc_replay_sink *)calloc(1, sizeof(*s));
    s->st = st;
    s->stream = stream;
    return s;
}

void mc_replay_sink_free(mc_replay_sink *s) { free(s); }

void mc_replay_sink_cb(void *user, const uint8_t *data, int size, int64_t frame, int key) {
    (void)key;
    mc_replay_sink *s = (mc_replay_sink *)user;
    if (s && s->st) mc_replay_store_write(s->st, s->stream, frame, data, size);
}


/* ---- decoder ---- */

struct mc_replay_dec {
    AVCodecContext *c;
    AVPacket *pkt;
    AVFrame *frm;
    struct SwsContext *sws;
    int sw, sh, sfmt, dw, dh;
    AVBufferRef *hw;            // VideoToolbox device (hardware decode)
#ifdef __APPLE__
    CVPixelBufferPoolRef pool;  // BGRA output when a frame comes back in software
    int pw, ph;
#endif
};

mc_replay_dec *mc_replay_dec_open(void) { return mc_replay_dec_open_codec(0); }

static enum AVPixelFormat replay_hw_format(AVCodecContext *c, const enum AVPixelFormat *fmts) {
    (void)c;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        const AVPixFmtDescriptor *dsc = av_pix_fmt_desc_get(*p);
        if (dsc && !(dsc->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
    }
    return fmts[0];
}

static mc_replay_dec *dec_open(int codec_kind, int hardware) {
    enum AVCodecID id = codec_kind == 1 ? AV_CODEC_ID_PRORES : codec_kind == 2 ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264;
    const AVCodec *codec = avcodec_find_decoder(id);
    if (!codec) return NULL;
    mc_replay_dec *d = (mc_replay_dec *)calloc(1, sizeof(*d));
    d->c = avcodec_alloc_context3(codec);
    d->c->flags |= AV_CODEC_FLAG_LOW_DELAY;     // intra-only: one packet in, one picture out
    d->c->thread_count = codec_kind == 0 ? 2 : 0;   // ProRes/HEVC slices scale across all performance cores
    d->c->thread_type = FF_THREAD_SLICE;
    if (hardware && av_hwdevice_ctx_create(&d->hw, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
        d->c->hw_device_ctx = av_buffer_ref(d->hw);
        d->c->get_format = replay_hw_format;
    }
    if (avcodec_open2(d->c, codec, NULL) < 0) {
        if (d->hw) av_buffer_unref(&d->hw);
        avcodec_free_context(&d->c);
        free(d);
        return NULL;
    }
    d->pkt = av_packet_alloc();
    d->frm = av_frame_alloc();
    return d;
}

/* codec: 0 = H.264 intra, 1 = ProRes, 2 = HEVC intra. Software decode into BGRA (mc_replay_dec_decode). */
mc_replay_dec *mc_replay_dec_open_codec(int codec_kind) { return dec_open(codec_kind, 0); }

/* Same, decoding on the VideoToolbox engine (Apple Silicon: ~0.3 ms per 1080p frame vs 2–4 ms in
   software) for mc_replay_dec_decode_pb. Falls back to software per frame if the hardware declines. */
mc_replay_dec *mc_replay_dec_open_hw(int codec_kind) { return dec_open(codec_kind, 1); }

/* One packet in, one picture out (in d->frm). */
static int dec_frame(mc_replay_dec *d, const uint8_t *data, int size) {
    av_packet_unref(d->pkt);
    d->pkt->data = (uint8_t *)data;
    d->pkt->size = size;
    d->pkt->flags = AV_PKT_FLAG_KEY;
    if (avcodec_send_packet(d->c, d->pkt) < 0) {
        avcodec_flush_buffers(d->c);
        if (avcodec_send_packet(d->c, d->pkt) < 0) return -1;
    }
    int ret = avcodec_receive_frame(d->c, d->frm);
    if (ret == AVERROR(EAGAIN)) {          // a decoder that still buffers: drain this one picture
        avcodec_send_packet(d->c, NULL);
        ret = avcodec_receive_frame(d->c, d->frm);
        avcodec_flush_buffers(d->c);
    }
    return ret < 0 ? -1 : 0;
}

static int to_bgra(mc_replay_dec *d, AVFrame *f, uint8_t *bgra, int stride, int w, int h) {
    if (!d->sws || d->sw != f->width || d->sh != f->height || d->sfmt != f->format || d->dw != w || d->dh != h) {
        if (d->sws) sws_freeContext(d->sws);
        d->sws = sws_alloc_context();
        if (d->sws) {
            av_opt_set_int(d->sws, "srcw", f->width, 0);
            av_opt_set_int(d->sws, "srch", f->height, 0);
            av_opt_set_int(d->sws, "src_format", f->format, 0);
            av_opt_set_int(d->sws, "dstw", w, 0);
            av_opt_set_int(d->sws, "dsth", h, 0);
            av_opt_set_int(d->sws, "dst_format", AV_PIX_FMT_BGRA, 0);
            av_opt_set_int(d->sws, "sws_flags", SWS_BILINEAR, 0);
            av_opt_set_int(d->sws, "threads", 0, 0);
            if (sws_init_context(d->sws, NULL, NULL) < 0) { sws_freeContext(d->sws); d->sws = NULL; }
        }
        if (d->sws) {
            const int *c709 = sws_getCoefficients(SWS_CS_ITU709);
            sws_setColorspaceDetails(d->sws, c709, f->color_range == AVCOL_RANGE_JPEG, c709, 1, 0, 1 << 16, 1 << 16);
        }
        d->sw = f->width; d->sh = f->height; d->sfmt = f->format; d->dw = w; d->dh = h;
    }
    if (!d->sws) return -1;
    uint8_t *dst[4] = {bgra, NULL, NULL, NULL};
    int dstride[4] = {stride, 0, 0, 0};
    sws_scale(d->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, dst, dstride);
    return 0;
}

int mc_replay_dec_decode_pb(mc_replay_dec *d, const uint8_t *data, int size, int w, int h, void **out_pb) {
#ifdef __APPLE__
    if (!d || !data || size <= 0 || !out_pb) return -1;
    *out_pb = NULL;
    if (dec_frame(d, data, size) < 0) return -1;
    AVFrame *f = d->frm;
    if (f->format == AV_PIX_FMT_VIDEOTOOLBOX && f->data[3]) {
        CVPixelBufferRef pb = (CVPixelBufferRef)f->data[3];
        CVPixelBufferRetain(pb);
        av_frame_unref(f);
        *out_pb = pb;
        return 0;
    }
    if (!d->pool || d->pw != w || d->ph != h) {
        if (d->pool) { CVPixelBufferPoolRelease(d->pool); d->pool = NULL; }
        int fmt = kCVPixelFormatType_32BGRA;
        CFNumberRef cw = CFNumberCreate(NULL, kCFNumberIntType, &w), ch = CFNumberCreate(NULL, kCFNumberIntType, &h);
        CFNumberRef cf = CFNumberCreate(NULL, kCFNumberIntType, &fmt);
        CFDictionaryRef ios = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *k[] = {kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey,
                           kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey};
        const void *v[] = {cw, ch, cf, ios, kCFBooleanTrue};
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CVPixelBufferPoolCreate(NULL, NULL, attrs, &d->pool);
        CFRelease(attrs); CFRelease(ios); CFRelease(cf); CFRelease(ch); CFRelease(cw);
        d->pw = w; d->ph = h;
        if (!d->pool) { av_frame_unref(f); return -1; }
    }
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, d->pool, &pb) != kCVReturnSuccess || !pb) { av_frame_unref(f); return -1; }
    CVPixelBufferLockBaseAddress(pb, 0);
    int r = to_bgra(d, f, (uint8_t *)CVPixelBufferGetBaseAddress(pb), (int)CVPixelBufferGetBytesPerRow(pb), w, h);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    av_frame_unref(f);
    if (r < 0) { CVPixelBufferRelease(pb); return -1; }
    *out_pb = pb;
    return 0;
#else
    (void)d; (void)data; (void)size; (void)w; (void)h; (void)out_pb;
    return -1;
#endif
}

int mc_replay_dec_decode(mc_replay_dec *d, const uint8_t *data, int size, uint8_t *bgra, int stride, int w, int h) {
    if (!d || !data || size <= 0 || !bgra) return -1;
    if (dec_frame(d, data, size) < 0) return -1;
    AVFrame *f = d->frm;
    if (f->hw_frames_ctx || f->format == AV_PIX_FMT_VIDEOTOOLBOX) {     // hardware decoder used for BGRA output
        AVFrame *sw = av_frame_alloc();
        if (!sw || av_hwframe_transfer_data(sw, f, 0) < 0) { av_frame_free(&sw); av_frame_unref(f); return -1; }
        sw->color_range = f->color_range;
        av_frame_unref(f);
        int r = to_bgra(d, sw, bgra, stride, w, h);
        av_frame_free(&sw);
        return r;
    }
    int r = to_bgra(d, f, bgra, stride, w, h);
    av_frame_unref(f);
    return r;
}

void mc_replay_dec_close(mc_replay_dec *d) {
    if (!d) return;
    if (d->sws) sws_freeContext(d->sws);
#ifdef __APPLE__
    if (d->pool) CVPixelBufferPoolRelease(d->pool);
#endif
    av_frame_free(&d->frm);
    av_packet_free(&d->pkt);
    avcodec_free_context(&d->c);
    if (d->hw) av_buffer_unref(&d->hw);
    free(d);
}
