#define MC_SRT_INTERNAL 1
#include "mc_srt.h"
#include "mc_util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <libavutil/error.h>

#if __has_include(<srt/srt.h>)
#include <srt/srt.h>
#include <netdb.h>
#include <arpa/inet.h>

struct mc_srt {
    SRTSOCKET sock;
    SRTSOCKET listen_sock;
    int is_sender;
    int latency_ms;
    char mode[16];
    char peer[64];
    int (*interrupt)(void *);
    void *opaque;
    pthread_mutex_t lock;
    int closed;
    int64_t rcv_retrans_total;   // libsrt only reports received retransmissions per interval
    uint8_t pend[1500];          // remainder of a message when the caller asked for less than 1316 bytes
    int pend_off, pend_len;
};

static pthread_once_t g_srt_once = PTHREAD_ONCE_INIT;
static void srt_init_once(void) { srt_startup(); srt_setloglevel(3 /* LOG_ERR */); }

int mc_srt_supported(void) { return 1; }

/* "srt://host:port?mode=caller&latency=200000&passphrase=x&streamid=y&pbkeylen=16" (latency in µs, like FFmpeg) */
static void url_param(const char *q, const char *key, char *out, size_t n) {
    out[0] = 0;
    if (!q) return;
    size_t kl = strlen(key);
    const char *p = q;
    while (p && *p) {
        if (strncmp(p, key, kl) == 0 && p[kl] == '=') {
            p += kl + 1;
            size_t i = 0;
            while (*p && *p != '&' && i + 1 < n) {
                if (*p == '%' && p[1] && p[2]) {
                    char hx[3] = {p[1], p[2], 0};
                    out[i++] = (char)strtol(hx, NULL, 16);
                    p += 3;
                } else {
                    out[i++] = *p == '+' ? ' ' : *p;
                    p++;
                }
            }
            out[i] = 0;
            return;
        }
        p = strchr(p, '&');
        if (p) p++;
    }
}

static int resolve(const char *host, int port, struct sockaddr_storage *ss, int *len) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    char ps[16];
    snprintf(ps, sizeof(ps), "%d", port);
    if (getaddrinfo(host && *host ? host : "0.0.0.0", ps, &hints, &res) != 0 || !res) return -1;
    memcpy(ss, res->ai_addr, res->ai_addrlen);
    *len = (int)res->ai_addrlen;
    freeaddrinfo(res);
    return 0;
}

static void set_opts(SRTSOCKET s, const char *q, int is_sender, int *latency_ms_out) {
    char v[512];
    int yes = 1, no = 0;
    SRT_TRANSTYPE tt = SRTT_LIVE;
    srt_setsockflag(s, SRTO_TRANSTYPE, &tt, sizeof(tt));
    srt_setsockflag(s, SRTO_SENDER, is_sender ? &yes : &no, sizeof(int));
    int latency = 200;
    url_param(q, "latency", v, sizeof(v));
    if (*v) {
        long l = atol(v);
        latency = l > 10000 ? (int)(l / 1000) : (int)l;     // FFmpeg-style µs, or plain ms
    }
    srt_setsockflag(s, SRTO_LATENCY, &latency, sizeof(int));
    *latency_ms_out = latency;
    url_param(q, "passphrase", v, sizeof(v));
    if (*v) srt_setsockflag(s, SRTO_PASSPHRASE, v, (int)strlen(v));
    url_param(q, "pbkeylen", v, sizeof(v));
    if (*v) { int k = atoi(v); srt_setsockflag(s, SRTO_PBKEYLEN, &k, sizeof(int)); }
    url_param(q, "streamid", v, sizeof(v));
    if (*v) srt_setsockflag(s, SRTO_STREAMID, v, (int)strlen(v));
    url_param(q, "maxbw", v, sizeof(v));
    if (*v) { int64_t bw = atoll(v); srt_setsockflag(s, SRTO_MAXBW, &bw, sizeof(bw)); }
    int conntimeo = 4000;
    srt_setsockflag(s, SRTO_CONNTIMEO, &conntimeo, sizeof(int));
    int to = 200;
    srt_setsockflag(s, SRTO_RCVTIMEO, &to, sizeof(int));
    srt_setsockflag(s, SRTO_SNDTIMEO, &to, sizeof(int));
}

static void peer_name(SRTSOCKET s, char *out, size_t n) {
    struct sockaddr_storage ss;
    int len = sizeof(ss);
    out[0] = 0;
    if (srt_getpeername(s, (struct sockaddr *)&ss, &len) == 0 && ss.ss_family == AF_INET) {
        struct sockaddr_in *a = (struct sockaddr_in *)&ss;
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &a->sin_addr, ip, sizeof(ip));
        snprintf(out, n, "%s:%d", ip, ntohs(a->sin_port));
    }
}

mc_srt *mc_srt_open(const char *url, int is_sender, int (*interrupt)(void *), void *opaque, char *err, int errlen) {
    pthread_once(&g_srt_once, srt_init_once);
    if (!url || strncmp(url, "srt://", 6) != 0) {
        snprintf(err, errlen, "SRT URL 아님");
        return NULL;
    }
    char host[256] = {0};
    int port = 0;
    const char *hp = url + 6;
    const char *q = strchr(hp, '?');
    const char *colon = NULL;
    for (const char *c = hp; *c && c != q; c++) if (*c == ':') colon = c;
    if (!colon) { snprintf(err, errlen, "SRT 포트 없음"); return NULL; }
    size_t hl = (size_t)(colon - hp);
    if (hl >= sizeof(host)) hl = sizeof(host) - 1;
    memcpy(host, hp, hl);
    port = atoi(colon + 1);
    if (q) q++;

    char mode[16];
    url_param(q, "mode", mode, sizeof(mode));
    if (!*mode) {
        char listen[8];
        url_param(q, "listen", listen, sizeof(listen));
        strcpy(mode, (*listen == '1' || hl == 0) ? "listener" : "caller");
    }

    mc_srt *s = (mc_srt *)calloc(1, sizeof(*s));
    s->sock = SRT_INVALID_SOCK;
    s->listen_sock = SRT_INVALID_SOCK;
    s->is_sender = is_sender;
    s->interrupt = interrupt;
    s->opaque = opaque;
    snprintf(s->mode, sizeof(s->mode), "%s", mode);
    pthread_mutex_init(&s->lock, NULL);

    struct sockaddr_storage addr;
    int alen = 0;
    if (strcmp(mode, "listener") == 0) {
        SRTSOCKET ls = srt_create_socket();
        set_opts(ls, q, is_sender, &s->latency_ms);
        if (resolve(hl ? host : "0.0.0.0", port, &addr, &alen) < 0 || srt_bind(ls, (struct sockaddr *)&addr, alen) < 0 ||
            srt_listen(ls, 1) < 0) {
            snprintf(err, errlen, "SRT 리스너 열기 실패 (포트 %d): %s", port, srt_getlasterror_str());
            srt_close(ls);
            mc_srt_close(s);
            return NULL;
        }
        s->listen_sock = ls;
        int eid = srt_epoll_create();
        int ev = SRT_EPOLL_IN | SRT_EPOLL_ERR;
        srt_epoll_add_usock(eid, ls, &ev);
        for (;;) {
            if (interrupt && interrupt(opaque)) {
                srt_epoll_release(eid);
                snprintf(err, errlen, "중단됨");
                mc_srt_close(s);
                return NULL;
            }
            SRTSOCKET rd[1];
            int rn = 1;
            if (srt_epoll_wait(eid, rd, &rn, NULL, NULL, 200, NULL, NULL, NULL, NULL) > 0) {
                struct sockaddr_storage pa;
                int pl = sizeof(pa);
                SRTSOCKET a = srt_accept(ls, (struct sockaddr *)&pa, &pl);
                if (a != SRT_INVALID_SOCK) {
                    s->sock = a;
                    break;
                }
            }
        }
        srt_epoll_release(eid);
    } else {
        SRTSOCKET cs = srt_create_socket();
        set_opts(cs, q, is_sender, &s->latency_ms);
        if (strcmp(mode, "rendezvous") == 0) {
            int yes = 1;
            srt_setsockflag(cs, SRTO_RENDEZVOUS, &yes, sizeof(int));
            struct sockaddr_storage la;
            int ll = 0;
            char lp[16];
            url_param(q, "localport", lp, sizeof(lp));
            resolve("0.0.0.0", *lp ? atoi(lp) : port, &la, &ll);
            srt_bind(cs, (struct sockaddr *)&la, ll);
        }
        if (resolve(host, port, &addr, &alen) < 0) {
            snprintf(err, errlen, "호스트를 찾을 수 없음: %s", host);
            srt_close(cs);
            mc_srt_close(s);
            return NULL;
        }
        if (srt_connect(cs, (struct sockaddr *)&addr, alen) < 0) {
            int rej = srt_getrejectreason(cs);
            snprintf(err, errlen, "SRT 연결 실패: %s%s%s", srt_getlasterror_str(),
                     rej ? " · " : "", rej ? srt_rejectreason_str(rej) : "");
            srt_close(cs);
            mc_srt_close(s);
            return NULL;
        }
        s->sock = cs;
    }
    int lat = 0, ll = sizeof(int);
    if (srt_getsockflag(s->sock, is_sender ? SRTO_PEERLATENCY : SRTO_RCVLATENCY, &lat, &ll) == 0) s->latency_ms = lat;
    peer_name(s->sock, s->peer, sizeof(s->peer));
    return s;
}

int mc_srt_read(mc_srt *s, uint8_t *buf, int size) {
    if (s->pend_len > 0) {
        int n = size < s->pend_len ? size : s->pend_len;
        memcpy(buf, s->pend + s->pend_off, n);
        s->pend_off += n;
        s->pend_len -= n;
        return n;
    }
    for (;;) {
        if (s->interrupt && s->interrupt(s->opaque)) return AVERROR_EXIT;
        int direct = size >= 1500;
        int n = srt_recvmsg(s->sock, direct ? (char *)buf : (char *)s->pend, direct ? size : (int)sizeof(s->pend));
        if (n > 0 && !direct) {
            int c = size < n ? size : n;
            memcpy(buf, s->pend, c);
            s->pend_off = c;
            s->pend_len = n - c;
            return c;
        }
        if (n > 0) return n;
        if (n == 0) return AVERROR_EOF;
        int e = srt_getlasterror(NULL);
        if (e == SRT_EASYNCRCV || e == SRT_ETIMEOUT) continue;     // timeout: check interrupt and wait again
        return AVERROR(EIO);
    }
}

int mc_srt_write(mc_srt *s, const uint8_t *buf, int size) {
    int done = 0;
    while (done < size) {
        if (s->interrupt && s->interrupt(s->opaque)) return AVERROR_EXIT;
        int chunk = size - done > 1316 ? 1316 : size - done;
        int n = srt_sendmsg2(s->sock, (const char *)buf + done, chunk, NULL);
        if (n < 0) {
            int e = srt_getlasterror(NULL);
            if (e == SRT_EASYNCSND || e == SRT_ETIMEOUT) continue;
            return AVERROR(EIO);
        }
        done += chunk;
    }
    return size;
}

void mc_srt_get_stats(mc_srt *s, mc_srt_stats *o) {
    memset(o, 0, sizeof(*o));
    if (!s) return;
    pthread_mutex_lock(&s->lock);
    if (s->closed || s->sock == SRT_INVALID_SOCK) {
        pthread_mutex_unlock(&s->lock);
        return;
    }
    SRT_TRACEBSTATS st;
    if (srt_bstats(s->sock, &st, 1 /* clear interval counters */) == 0) {
        o->connected = srt_getsockstate(s->sock) == SRTS_CONNECTED;
        o->is_sender = s->is_sender;
        o->rtt_ms = st.msRTT;
        o->bandwidth_mbps = st.mbpsBandwidth;
        o->latency_ms = s->latency_ms;
        if (s->is_sender) {
            o->rate_mbps = st.mbpsSendRate;
            o->pkts = st.pktSentTotal;
            o->lost = st.pktSndLossTotal;
            o->retransmitted = st.pktRetransTotal;
            o->dropped = st.pktSndDropTotal;
            o->loss_percent = st.pktSent > 0 ? 100.0 * st.pktSndLoss / st.pktSent : 0;
            o->buffer_ms = st.msSndBuf;
        } else {
            o->rate_mbps = st.mbpsRecvRate;
            o->pkts = st.pktRecvTotal;
            o->lost = st.pktRcvLossTotal;
            s->rcv_retrans_total += st.pktRcvRetrans;
            o->retransmitted = s->rcv_retrans_total;
            o->dropped = st.pktRcvDropTotal;
            o->loss_percent = st.pktRecv > 0 ? 100.0 * st.pktRcvLoss / (st.pktRecv + st.pktRcvLoss) : 0;
            o->buffer_ms = st.msRcvBuf;
        }
    }
    snprintf(o->peer, sizeof(o->peer), "%s", s->peer);
    snprintf(o->mode, sizeof(o->mode), "%s", s->mode);
    pthread_mutex_unlock(&s->lock);
}

/* Milliseconds of data waiting in the receive buffer beyond the SRT latency (= backlog we hold). */
int mc_srt_backlog_ms(mc_srt *s) {
    if (!s || s->sock == SRT_INVALID_SOCK) return 0;
    SRT_TRACEBSTATS st;
    if (srt_bistats(s->sock, &st, 0, 1) != 0) return 0;
    int b = st.msRcvBuf - s->latency_ms;
    return b > 0 ? b : 0;
}

void mc_srt_close(mc_srt *s) {
    if (!s) return;
    pthread_mutex_lock(&s->lock);
    s->closed = 1;
    if (s->sock != SRT_INVALID_SOCK) srt_close(s->sock);
    if (s->listen_sock != SRT_INVALID_SOCK) srt_close(s->listen_sock);
    s->sock = s->listen_sock = SRT_INVALID_SOCK;
    pthread_mutex_unlock(&s->lock);
    pthread_mutex_destroy(&s->lock);
    free(s);
}

#else  /* no libsrt headers: FFmpeg's srt:// protocol is used instead */
struct mc_srt { int unused; };
int mc_srt_supported(void) { return 0; }
mc_srt *mc_srt_open(const char *u, int s, int (*i)(void *), void *o, char *e, int el) {
    (void)u; (void)s; (void)i; (void)o;
    snprintf(e, el, "libsrt 없음");
    return NULL;
}
int mc_srt_read(mc_srt *s, uint8_t *b, int n) { (void)s; (void)b; (void)n; return AVERROR(ENOSYS); }
int mc_srt_write(mc_srt *s, const uint8_t *b, int n) { (void)s; (void)b; (void)n; return AVERROR(ENOSYS); }
void mc_srt_get_stats(mc_srt *s, mc_srt_stats *o) { (void)s; memset(o, 0, sizeof(*o)); }
void mc_srt_close(mc_srt *s) { (void)s; }
int mc_srt_backlog_ms(mc_srt *s) { (void)s; return 0; }
#endif
