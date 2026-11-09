// Blackmagic DeckLink capture and playout.
// Requires the Desktop Video SDK headers (copy SDK "Mac/include" into ThirdParty/DeckLinkSDK/include)
// and the Desktop Video driver at runtime. Without the SDK this file compiles to stubs.
#include "mc_core.h"
#include "mc_util.h"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#if __has_include("DeckLinkAPI.h")
#define MC_HAVE_DECKLINK 1
#include "DeckLinkAPI.h"
#include "DeckLinkAPIVersion.h"
#else
#define MC_HAVE_DECKLINK 0
#endif

#if MC_HAVE_DECKLINK

#if defined(BLACKMAGIC_DECKLINK_API_VERSION) && BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
#define MC_DL_VIDEO_BUFFER 1  // SDK 14.3+: frame bytes via IDeckLinkVideoBuffer
#else
#define MC_DL_VIDEO_BUFFER 0
#endif

namespace {

std::string dl_string(
#ifdef __APPLE__
    CFStringRef s
#else
    const char *s
#endif
) {
    std::string out;
    if (!s) return out;
#ifdef __APPLE__
    char buf[512];
    if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) out = buf;
    CFRelease(s);
#else
    out = s;
    free((void *)s);
#endif
    return out;
}

// Scoped CPU access to a frame's pixels, for both old (GetBytes) and new (IDeckLinkVideoBuffer) SDKs.
class FrameAccess {
  public:
    FrameAccess(IDeckLinkVideoFrame *frame, bool write) {
#if MC_DL_VIDEO_BUFFER
        flags_ = write ? bmdBufferAccessWrite : bmdBufferAccessRead;
        if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buf_) == S_OK && buf_) {
            if (buf_->StartAccess(flags_) == S_OK) {
                started_ = true;
                if (buf_->GetBytes(&bytes_) != S_OK) bytes_ = nullptr;
            }
        }
#else
        (void)write;
        if (frame->GetBytes(&bytes_) != S_OK) bytes_ = nullptr;
#endif
    }
    ~FrameAccess() {
#if MC_DL_VIDEO_BUFFER
        if (buf_) {
            if (started_) buf_->EndAccess(flags_);
            buf_->Release();
        }
#endif
    }
    void *bytes() const { return bytes_; }

  private:
    void *bytes_ = nullptr;
#if MC_DL_VIDEO_BUFFER
    IDeckLinkVideoBuffer *buf_ = nullptr;
    BMDBufferAccessFlags flags_ = bmdBufferAccessRead;
    bool started_ = false;
#endif
};

IDeckLink *dl_device_at(int index) {
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return nullptr;
    IDeckLink *dev = nullptr, *found = nullptr;
    int i = 0;
    while (it->Next(&dev) == S_OK) {
        if (i++ == index) {
            found = dev;
            break;
        }
        dev->Release();
    }
    it->Release();
    return found;
}

}  // namespace

extern "C" int mc_decklink_available(void) {
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return 0;
    it->Release();
    return 1;
}

extern "C" int mc_decklink_list(char *buf, int bufsize) {
    if (buf && bufsize > 0) buf[0] = 0;
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return 0;
    IDeckLink *dev = nullptr;
    int count = 0, pos = 0;
    while (it->Next(&dev) == S_OK) {
#ifdef __APPLE__
        CFStringRef name = nullptr;
#else
        const char *name = nullptr;
#endif
        std::string n = (dev->GetDisplayName(&name) == S_OK) ? dl_string(name) : std::string("DeckLink");
        n = std::to_string(count + 1) + ": " + n;
        if (buf && pos + (int)n.size() + 2 < bufsize) {
            memcpy(buf + pos, n.data(), n.size());
            pos += (int)n.size();
            buf[pos++] = '\n';
            buf[pos] = 0;
        }
        count++;
        dev->Release();
    }
    it->Release();
    return count;
}

/* ------------------------------ input ------------------------------ */

class InputCallback;

struct mc_dl_in {
    IDeckLink *device = nullptr;
    IDeckLinkInput *input = nullptr;
    InputCallback *callback = nullptr;
    mc_callbacks cb{};
    std::vector<uint8_t> bgra;
    std::vector<float> audio;
    std::atomic<bool> had_signal{false};
    bool detection = true;
};

class InputCallback : public IDeckLinkInputCallback {
  public:
    explicit InputCallback(mc_dl_in *owner) : owner_(owner) {}
    virtual ~InputCallback() {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID *ppv) override {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++ref_; }
    ULONG STDMETHODCALLTYPE Release() override { return --ref_; }  // lifetime owned by mc_dl_in

    HRESULT STDMETHODCALLTYPE VideoInputFormatChanged(BMDVideoInputFormatChangedEvents events,
                                                      IDeckLinkDisplayMode *mode,
                                                      BMDDetectedVideoInputFormatFlags flags) override {
        (void)events;
        if (!mode) return S_OK;
        BMDPixelFormat pf = (flags & bmdDetectedVideoInputRGB444) ? bmdFormat8BitBGRA : bmdFormat8BitYUV;
        IDeckLinkInput *in = owner_->input;
        in->PauseStreams();
        in->EnableVideoInput(mode->GetDisplayMode(), pf, bmdVideoInputEnableFormatDetection);
        in->FlushStreams();
        in->StartStreams();
        if (owner_->cb.on_status) {
#ifdef __APPLE__
            CFStringRef name = nullptr;
#else
            const char *name = nullptr;
#endif
            std::string n = (mode->GetName(&name) == S_OK) ? dl_string(name) : std::string("?");
            std::string msg = "입력 포맷: " + n;
            owner_->cb.on_status(owner_->cb.user, MC_STATE_RUNNING, msg.c_str());
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE VideoInputFrameArrived(IDeckLinkVideoInputFrame *video,
                                                     IDeckLinkAudioInputPacket *audio) override {
        mc_dl_in *o = owner_;
        if (video) {
            bool no_signal = (video->GetFlags() & bmdFrameHasNoInputSource) != 0;
            if (no_signal) {
                if (o->had_signal.exchange(false) && o->cb.on_status)
                    o->cb.on_status(o->cb.user, MC_STATE_CONNECTING, "신호 없음");
            } else {
                if (!o->had_signal.exchange(true) && o->cb.on_status)
                    o->cb.on_status(o->cb.user, MC_STATE_RUNNING, "신호 수신 중");
                int w = (int)video->GetWidth(), h = (int)video->GetHeight();
                int rb = (int)video->GetRowBytes();
                FrameAccess access(video, false);
                const uint8_t *src = (const uint8_t *)access.bytes();
                if (src && o->cb.on_video && w > 0 && h > 0) {
                    BMDTimeValue t = 0, d = 0;
                    video->GetStreamTime(&t, &d, 1000000);
                    if (video->GetPixelFormat() == bmdFormat8BitBGRA) {
                        o->cb.on_video(o->cb.user, src, w, h, rb, (int64_t)t);
                    } else if (video->GetPixelFormat() == bmdFormat8BitYUV) {
                        size_t need = (size_t)w * h * 4;
                        if (o->bgra.size() < need) o->bgra.resize(need);
                        mc_uyvy_to_bgra(src, rb, o->bgra.data(), w * 4, w, h);
                        o->cb.on_video(o->cb.user, o->bgra.data(), w, h, w * 4, (int64_t)t);
                    }
                }
            }
        }
        if (audio && o->cb.on_audio) {
            void *p = nullptr;
            long n = audio->GetSampleFrameCount();
            if (n > 0 && audio->GetBytes(&p) == S_OK && p) {
                if ((long)o->audio.size() < n * 2) o->audio.resize((size_t)n * 2);
                mc_s32_to_float((const int32_t *)p, o->audio.data(), (int)(n * 2));
                o->cb.on_audio(o->cb.user, o->audio.data(), (int)n);
            }
        }
        return S_OK;
    }

  private:
    mc_dl_in *owner_;
    std::atomic<ULONG> ref_{1};
};

extern "C" mc_dl_in *mc_decklink_in_open(int device_index, mc_callbacks cb, char *err, int errlen) {
    auto fail = [&](const char *msg) -> mc_dl_in * {
        if (err && errlen > 0) snprintf(err, errlen, "%s", msg);
        return nullptr;
    };
    IDeckLink *dev = dl_device_at(device_index);
    if (!dev) return fail("DeckLink 장치를 찾을 수 없음");
    IDeckLinkInput *input = nullptr;
    if (dev->QueryInterface(IID_IDeckLinkInput, (void **)&input) != S_OK || !input) {
        dev->Release();
        return fail("이 장치는 입력을 지원하지 않음");
    }
    mc_dl_in *o = new mc_dl_in();
    o->device = dev;
    o->input = input;
    o->cb = cb;
    o->callback = new InputCallback(o);
    input->SetCallback(o->callback);
    HRESULT hr = input->EnableVideoInput(bmdModeHD1080i5994, bmdFormat8BitYUV, bmdVideoInputEnableFormatDetection);
    if (hr != S_OK) {
        o->detection = false;
        hr = input->EnableVideoInput(bmdModeHD1080i5994, bmdFormat8BitYUV, bmdVideoInputFlagDefault);
    }
    if (hr != S_OK) {
        input->SetCallback(nullptr);
        input->Release();
        dev->Release();
        delete o->callback;
        delete o;
        return fail("비디오 입력 활성화 실패 (다른 앱이 사용 중일 수 있음)");
    }
    input->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, 2);
    if (input->StartStreams() != S_OK) {
        input->DisableVideoInput();
        input->DisableAudioInput();
        input->SetCallback(nullptr);
        input->Release();
        dev->Release();
        delete o->callback;
        delete o;
        return fail("캡처 시작 실패");
    }
    if (cb.on_status)
        cb.on_status(cb.user, MC_STATE_CONNECTING,
                     o->detection ? "신호 대기 중 (자동 포맷 감지)" : "신호 대기 중 (1080i59.94 고정)");
    return o;
}

extern "C" void mc_decklink_in_close(mc_dl_in *o) {
    if (!o) return;
    o->input->StopStreams();
    o->input->DisableVideoInput();
    o->input->DisableAudioInput();
    o->input->SetCallback(nullptr);
    o->input->Release();
    o->device->Release();
    delete o->callback;
    delete o;
}

/* ------------------------------ output ----------------------------- */

struct mc_dl_out {
    IDeckLink *device = nullptr;
    IDeckLinkOutput *output = nullptr;
    IDeckLinkMutableVideoFrame *frames[2] = {nullptr, nullptr};
    IDeckLinkKeyer *keyer = nullptr;   // Fill & Key: frames are BGRA, alpha goes out as the key signal
    int which = 0;
    int width = 0, height = 0;
    int fps_num = 30, fps_den = 1;
    pthread_t thread;
    mc_mailbox box;
    pthread_mutex_t alock;
    mc_audio_fifo afifo;
    // audio clock-lock stats (written by the output thread, read by mc_decklink_out_stats)
    std::atomic<int> st_buffered{0}, st_target{0};
    std::atomic<int64_t> st_dropped{0}, st_inserted{0}, st_resyncs{0}, st_short{0};
};

/* Frame index (1…n-1) where removing or repeating one stereo sample is least audible: the flattest spot. */
static int quiet_point(const float *s, int n) {
    int best = n / 2;
    float bestd = 1e30f;
    for (int i = 1; i < n; i++) {
        float d = fabsf(s[i * 2] - s[i * 2 - 2]) + fabsf(s[i * 2 + 1] - s[i * 2 - 1]);
        if (d < bestd) { bestd = d; best = i; }
    }
    return best;
}

/* Audio is produced in the render (host) clock's rhythm but played out in the card's SDI reference clock.
   The two differ by tens of ppm, so without correction the card's buffer slowly fills (growing lip-sync
   offset, then dropped samples) or drains (clicks). Each loop we look at how much the card holds and steer
   it to `target`: small drift → drop / repeat one sample at a quiet point, at most every kMinGapMs;
   a large error (start, render stall) → resync at once with silence or by skipping the backlog. */
struct DlAudioClock {
    int frame_samples, target, deadband, hard;
    double avg = -1;            // smoothed card level before a write (sample frames)
    int warm = 0;               // loops since the last resync
    double last_fix_ms = 0;
    std::vector<int32_t> pend;  // converted samples the card has not accepted yet (written < requested)
    static constexpr int kMinGapMs = 50;   // ≤ 20 samples/s ≈ 400 ppm, well above real clock drift
    static constexpr int kMaxPend = MC_AUDIO_RATE / 2;

    DlAudioClock(int fps_num, int fps_den) {
        frame_samples = fps_num > 0 ? (int)((int64_t)MC_AUDIO_RATE * fps_den / fps_num) : 1600;
        if (frame_samples < 1) frame_samples = 1;
        target = 3 * frame_samples;     // ~3 video frames: one loop writes ~1 frame, so the card holds 3–4
        deadband = frame_samples / 2 > 32 ? frame_samples / 2 : 32;
        hard = 4 * frame_samples;
    }

    static double now_ms() { return mc_now_us() / 1000.0; }

    /* fbuf holds n stereo frames (room for n + 1). Adjusts it in place; returns the new frame count. */
    int correct(mc_dl_out *o, std::vector<float> &fbuf, int n, uint32_t buffered) {
        int level = (int)buffered + (int)(pend.size() / 2);     // queued ahead of this chunk
        o->st_buffered.store((int)buffered, std::memory_order_relaxed);
        o->st_target.store(target, std::memory_order_relaxed);
        if (n <= 0) return n;                                   // no audio this loop (output without audio)
        // after this write the card should hold about target + one frame
        int excess = level + n - (target + frame_samples);
        if (excess > hard) {                                    // backlog (render burst): skip the oldest audio
            int drop = excess;
            int from_pend = drop < (int)(pend.size() / 2) ? drop : (int)(pend.size() / 2);
            pend.erase(pend.begin(), pend.begin() + (size_t)from_pend * 2);
            int from_chunk = drop - from_pend < n ? drop - from_pend : n;
            if (from_chunk > 0) memmove(fbuf.data(), fbuf.data() + (size_t)from_chunk * 2, (size_t)(n - from_chunk) * 2 * sizeof(float));
            n -= from_chunk;
            resync(o);
            return n;
        }
        if (excess < -2 * frame_samples) {                      // start or underrun: pad with silence up front
            int pad = -excess;
            if (pad > target + frame_samples) pad = target + frame_samples;
            pend.insert(pend.begin(), (size_t)pad * 2, 0);
            resync(o);
            return n;
        }
        avg = avg < 0 ? level : avg + (level - avg) / 64.0;
        if (++warm < 64 || n < 4) return n;                     // let the average settle first
        double t = now_ms();
        if (t - last_fix_ms < kMinGapMs) return n;
        if (avg > target + deadband) {                          // card clock slower: remove one sample
            int i = quiet_point(fbuf.data(), n);
            memmove(fbuf.data() + i * 2, fbuf.data() + (i + 1) * 2, (size_t)(n - i - 1) * 2 * sizeof(float));
            n--;
            avg -= 1;
            last_fix_ms = t;
            o->st_dropped.fetch_add(1, std::memory_order_relaxed);
        } else if (avg < target - deadband) {                   // card clock faster: repeat one sample
            int i = quiet_point(fbuf.data(), n);
            memmove(fbuf.data() + (i + 1) * 2, fbuf.data() + i * 2, (size_t)(n - i) * 2 * sizeof(float));
            n++;
            avg += 1;
            last_fix_ms = t;
            o->st_inserted.fetch_add(1, std::memory_order_relaxed);
        }
        return n;
    }

    void resync(mc_dl_out *o) {
        avg = -1;
        warm = 0;
        o->st_resyncs.fetch_add(1, std::memory_order_relaxed);
    }

    /* Writes pend; whatever the card does not take stays in pend for the next loop. */
    void write(mc_dl_out *o) {
        if (pend.empty()) return;
        uint32_t want = (uint32_t)(pend.size() / 2), written = 0;
        if (o->output->WriteAudioSamplesSync(pend.data(), want, &written) != S_OK) written = 0;
        if (written > want) written = want;
        if (written < want) o->st_short.fetch_add(1, std::memory_order_relaxed);
        pend.erase(pend.begin(), pend.begin() + (size_t)written * 2);
        if ((int)(pend.size() / 2) > kMaxPend) {                // card refuses audio for long: don't grow forever
            pend.erase(pend.begin(), pend.end() - (size_t)kMaxPend * 2);
            resync(o);
        }
    }
};

static void *dl_out_thread(void *arg) {
    mc_dl_out *o = (mc_dl_out *)arg;
    std::vector<uint8_t> local((size_t)o->width * o->height * 4);
    std::vector<float> fbuf;
    DlAudioClock clock(o->fps_num, o->fps_den);
    for (;;) {
        pthread_mutex_lock(&o->box.lock);
        while (!o->box.has_frame && !o->box.stop) pthread_cond_wait(&o->box.cond, &o->box.lock);
        if (o->box.stop) {
            pthread_mutex_unlock(&o->box.lock);
            break;
        }
        bool ok = o->box.width == o->width && o->box.height == o->height;
        if (ok) memcpy(local.data(), o->box.data, local.size());
        o->box.has_frame = 0;
        pthread_mutex_unlock(&o->box.lock);
        if (!ok) continue;

        IDeckLinkMutableVideoFrame *f = o->frames[o->which];
        o->which ^= 1;
        {
            FrameAccess access(f, true);
            uint8_t *dst = (uint8_t *)access.bytes();
            if (dst && o->keyer) {
                int rb = (int)f->GetRowBytes();
                for (int y = 0; y < o->height; y++)
                    memcpy(dst + (size_t)y * rb, local.data() + (size_t)y * o->width * 4, (size_t)o->width * 4);
            } else if (dst) {
                mc_bgra_to_uyvy(local.data(), o->width * 4, dst, (int)f->GetRowBytes(), o->width, o->height);
            }
        }
        o->output->DisplayVideoFrameSync(f);

        pthread_mutex_lock(&o->alock);
        int n = o->afifo.count;
        if ((int)fbuf.size() < (n + 1) * 2) fbuf.resize((size_t)(n + 1) * 2);   // +1: room for a repeated sample
        if (n > 0) n = mc_afifo_read(&o->afifo, fbuf.data(), n);
        pthread_mutex_unlock(&o->alock);
        uint32_t buffered = 0;
        if (o->output->GetBufferedAudioSampleFrameCount(&buffered) == S_OK) n = clock.correct(o, fbuf, n, buffered);
        if (n > 0) {
            size_t at = clock.pend.size();
            clock.pend.resize(at + (size_t)n * 2);
            mc_float_to_s32(fbuf.data(), clock.pend.data() + at, n * 2);
        }
        clock.write(o);
    }
    return nullptr;
}

extern "C" mc_dl_out *mc_decklink_out_open(int device_index, int width, int height, int fps_num, int fps_den,
                                           int external_key, char *err, int errlen) {
    auto fail = [&](const char *msg) -> mc_dl_out * {
        if (err && errlen > 0) snprintf(err, errlen, "%s", msg);
        return nullptr;
    };
    IDeckLink *dev = dl_device_at(device_index);
    if (!dev) return fail("DeckLink 장치를 찾을 수 없음");
    IDeckLinkOutput *out = nullptr;
    if (dev->QueryInterface(IID_IDeckLinkOutput, (void **)&out) != S_OK || !out) {
        dev->Release();
        return fail("이 장치는 출력을 지원하지 않음");
    }
    // Find a display mode matching the program format; prefer progressive.
    BMDDisplayMode chosen = bmdModeUnknown;
    for (int pass = 0; pass < 2 && chosen == bmdModeUnknown; pass++) {
        IDeckLinkDisplayModeIterator *mit = nullptr;
        if (out->GetDisplayModeIterator(&mit) != S_OK || !mit) break;
        IDeckLinkDisplayMode *m = nullptr;
        while (mit->Next(&m) == S_OK) {
            BMDTimeValue dur = 0;
            BMDTimeScale scale = 0;
            m->GetFrameRate(&dur, &scale);
            bool sizeOk = m->GetWidth() == width && m->GetHeight() == height;
            bool rateOk = (int64_t)scale * fps_den == (int64_t)dur * fps_num;
            bool prog = m->GetFieldDominance() == bmdProgressiveFrame;
            if (sizeOk && rateOk && (pass == 1 || prog)) chosen = m->GetDisplayMode();
            m->Release();
            if (chosen != bmdModeUnknown) break;
        }
        mit->Release();
    }
    if (chosen == bmdModeUnknown) {
        out->Release();
        dev->Release();
        return fail("이 장치가 현재 프로그램 포맷을 지원하지 않음");
    }
    IDeckLinkKeyer *keyer = nullptr;
    if (external_key) {
        bool supported = false;
#if defined(BLACKMAGIC_DECKLINK_API_VERSION) && BLACKMAGIC_DECKLINK_API_VERSION >= 0x0b000000
        IDeckLinkProfileAttributes *attr = nullptr;
        if (dev->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attr) == S_OK && attr) {
#else
        IDeckLinkAttributes *attr = nullptr;
        if (dev->QueryInterface(IID_IDeckLinkAttributes, (void **)&attr) == S_OK && attr) {
#endif
            attr->GetFlag(BMDDeckLinkSupportsExternalKeying, &supported);
            attr->Release();
        }
        if (!supported || dev->QueryInterface(IID_IDeckLinkKeyer, (void **)&keyer) != S_OK || !keyer) {
            out->Release();
            dev->Release();
            return fail("이 DeckLink는 외부 키(Fill & Key)를 지원하지 않음 — Duo 2/Quad 2는 Desktop Video Setup에서 SDI 1·2를 묶어야 합니다");
        }
    }
    if (out->EnableVideoOutput(chosen, bmdVideoOutputFlagDefault) != S_OK) {
        if (keyer) keyer->Release();
        out->Release();
        dev->Release();
        return fail("비디오 출력 활성화 실패 (다른 앱이 사용 중일 수 있음)");
    }
    out->EnableAudioOutput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, 2,
                           bmdAudioOutputStreamContinuous);
    mc_dl_out *o = new mc_dl_out();
    o->device = dev;
    o->output = out;
    o->width = width;
    o->height = height;
    o->fps_num = fps_num;
    o->fps_den = fps_den > 0 ? fps_den : 1;
    o->keyer = keyer;
    if (keyer) {
        keyer->Enable(true);        // external: fill on SDI A, key on SDI B
        keyer->SetLevel(255);
    }
    for (int i = 0; i < 2; i++) {
        BMDPixelFormat pf = keyer ? bmdFormat8BitBGRA : bmdFormat8BitYUV;
        int rowBytes = keyer ? width * 4 : width * 2;
        if (out->CreateVideoFrame(width, height, rowBytes, pf, bmdFrameFlagDefault, &o->frames[i]) != S_OK) {
            for (int j = 0; j < i; j++) o->frames[j]->Release();
            if (keyer) { keyer->Disable(); keyer->Release(); }
            out->DisableAudioOutput();
            out->DisableVideoOutput();
            out->Release();
            dev->Release();
            delete o;
            return fail("출력 프레임 생성 실패");
        }
    }
    mc_mailbox_init(&o->box);
    pthread_mutex_init(&o->alock, nullptr);
    mc_afifo_init(&o->afifo, MC_AUDIO_RATE);
    pthread_create(&o->thread, nullptr, dl_out_thread, o);
    return o;
}

extern "C" void mc_decklink_out_video(mc_dl_out *o, const uint8_t *bgra, int stride) {
    if (o && bgra) mc_mailbox_put(&o->box, bgra, o->width, o->height, stride);
}

extern "C" void mc_decklink_out_audio(mc_dl_out *o, const float *stereo, int frames) {
    if (!o || !stereo) return;
    pthread_mutex_lock(&o->alock);
    mc_afifo_write(&o->afifo, stereo, frames);
    pthread_mutex_unlock(&o->alock);
}

extern "C" void mc_decklink_out_stats(mc_dl_out *o, mc_dl_out_stats *s) {
    if (!s) return;
    memset(s, 0, sizeof(*s));
    if (!o) return;
    s->buffered_audio = o->st_buffered.load(std::memory_order_relaxed);
    s->target_audio = o->st_target.load(std::memory_order_relaxed);
    s->samples_dropped = o->st_dropped.load(std::memory_order_relaxed);
    s->samples_inserted = o->st_inserted.load(std::memory_order_relaxed);
    s->resyncs = o->st_resyncs.load(std::memory_order_relaxed);
    s->short_writes = o->st_short.load(std::memory_order_relaxed);
}

extern "C" void mc_decklink_out_close(mc_dl_out *o) {
    if (!o) return;
    pthread_mutex_lock(&o->box.lock);
    o->box.stop = 1;
    pthread_cond_signal(&o->box.cond);
    pthread_mutex_unlock(&o->box.lock);
    pthread_join(o->thread, nullptr);
    if (o->keyer) {
        o->keyer->Disable();
        o->keyer->Release();
    }
    o->output->DisableAudioOutput();
    o->output->DisableVideoOutput();
    for (auto *f : o->frames)
        if (f) f->Release();
    o->output->Release();
    o->device->Release();
    mc_mailbox_destroy(&o->box);
    mc_afifo_free(&o->afifo);
    pthread_mutex_destroy(&o->alock);
    delete o;
}

#else /* !MC_HAVE_DECKLINK */

extern "C" int mc_decklink_available(void) { return 0; }
extern "C" int mc_decklink_list(char *buf, int bufsize) {
    if (buf && bufsize > 0) buf[0] = 0;
    return 0;
}
extern "C" mc_dl_in *mc_decklink_in_open(int, mc_callbacks, char *err, int errlen) {
    if (err && errlen > 0) snprintf(err, errlen, "DeckLink SDK 없이 빌드됨");
    return nullptr;
}
extern "C" void mc_decklink_in_close(mc_dl_in *) {}
extern "C" mc_dl_out *mc_decklink_out_open(int, int, int, int, int, int, char *err, int errlen) {
    if (err && errlen > 0) snprintf(err, errlen, "DeckLink SDK 없이 빌드됨");
    return nullptr;
}
extern "C" void mc_decklink_out_video(mc_dl_out *, const uint8_t *, int) {}
extern "C" void mc_decklink_out_audio(mc_dl_out *, const float *, int) {}
extern "C" void mc_decklink_out_stats(mc_dl_out *, mc_dl_out_stats *s) {
    if (s) memset(s, 0, sizeof(*s));
}
extern "C" void mc_decklink_out_close(mc_dl_out *) {}

#endif
