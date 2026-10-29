// Direct libsrt transport for SRT inputs/outputs (instead of FFmpeg's srt:// protocol) so the app can
// read live link statistics like vMix's SRT window: RTT, loss, retransmits, bandwidth, buffer.
#ifndef MC_SRT_H
#define MC_SRT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int connected;
    int is_sender;
    double rtt_ms;
    double bandwidth_mbps;       // estimated link capacity
    double rate_mbps;            // current send or receive rate
    int64_t pkts;                // packets sent/received (total)
    int64_t lost;                // packets lost (total)
    int64_t retransmitted;       // retransmitted (sender) / belated+retransmitted received
    int64_t dropped;             // too-late dropped (total)
    double loss_percent;         // over the last stats interval
    int buffer_ms;               // receiver buffer / sender buffer, in ms
    int latency_ms;              // negotiated latency
    char peer[64];               // remote address
    char mode[16];               // caller / listener / rendezvous
} mc_srt_stats;


#ifdef __cplusplus
}
#endif
#endif

/* Internal C-core API (not visible to Swift). Kept outside the include guard so it can be enabled
   by a later include with MC_SRT_INTERNAL defined. */
#if defined(MC_SRT_INTERNAL) && !defined(MC_SRT_INTERNAL_DECLS)
#define MC_SRT_INTERNAL_DECLS
#ifdef __cplusplus
extern "C" {
#endif
#ifdef MC_SRT_INTERNAL
typedef struct mc_srt mc_srt;
int mc_srt_supported(void);
/* Blocks until connected (listener: until a caller arrives). interrupt() returning non-zero aborts. */
mc_srt *mc_srt_open(const char *url, int is_sender, int (*interrupt)(void *), void *opaque, char *err, int errlen);
int mc_srt_read(mc_srt *s, uint8_t *buf, int size);          /* >0 bytes, AVERROR on error/eof */
int mc_srt_write(mc_srt *s, const uint8_t *buf, int size);
void mc_srt_get_stats(mc_srt *s, mc_srt_stats *out);
void mc_srt_close(mc_srt *s);
int mc_srt_backlog_ms(mc_srt *s);
#endif
#ifdef __cplusplus
}
#endif
#endif
