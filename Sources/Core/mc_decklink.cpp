// Blackmagic DeckLink capture and playout.
// Requires the Desktop Video SDK headers (copy SDK "Mac/include" into ThirdParty/DeckLinkSDK/include)
// and the Desktop Video driver at runtime. Without the SDK this file compiles to stubs.
#include "mc_core.h"
#include "mc_util.h"

#include <atomic>
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
    int which = 0;
    int width = 0, height = 0;
    pthread_t thread;
    mc_mailbox box;
    pthread_mutex_t alock;
    mc_audio_fifo afifo;
};

static void *dl_out_thread(void *arg) {
    mc_dl_out *o = (mc_dl_out *)arg;
    std::vector<uint8_t> local((size_t)o->width * o->height * 4);
    std::vector<float> fbuf;
    std::vector<int32_t> ibuf;
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
            if (dst) mc_bgra_to_uyvy(local.data(), o->width * 4, dst, (int)f->GetRowBytes(), o->width, o->height);
        }
        o->output->DisplayVideoFrameSync(f);

        pthread_mutex_lock(&o->alock);
        int n = o->afifo.count;
        if ((int)fbuf.size() < n * 2) fbuf.resize((size_t)n * 2);
        if (n > 0) n = mc_afifo_read(&o->afifo, fbuf.data(), n);
        pthread_mutex_unlock(&o->alock);
        if (n > 0) {
            if ((int)ibuf.size() < n * 2) ibuf.resize((size_t)n * 2);
            mc_float_to_s32(fbuf.data(), ibuf.data(), n * 2);
            uint32_t written = 0;
            o->output->WriteAudioSamplesSync(ibuf.data(), (uint32_t)n, &written);
        }
    }
    return nullptr;
}

extern "C" mc_dl_out *mc_decklink_out_open(int device_index, int width, int height, int fps_num, int fps_den,
                                           char *err, int errlen) {
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
    if (out->EnableVideoOutput(chosen, bmdVideoOutputFlagDefault) != S_OK) {
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
    for (int i = 0; i < 2; i++) {
        if (out->CreateVideoFrame(width, height, width * 2, bmdFormat8BitYUV, bmdFrameFlagDefault, &o->frames[i]) !=
            S_OK) {
            for (int j = 0; j < i; j++) o->frames[j]->Release();
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

extern "C" void mc_decklink_out_close(mc_dl_out *o) {
    if (!o) return;
    pthread_mutex_lock(&o->box.lock);
    o->box.stop = 1;
    pthread_cond_signal(&o->box.cond);
    pthread_mutex_unlock(&o->box.lock);
    pthread_join(o->thread, nullptr);
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
extern "C" mc_dl_out *mc_decklink_out_open(int, int, int, int, int, char *err, int errlen) {
    if (err && errlen > 0) snprintf(err, errlen, "DeckLink SDK 없이 빌드됨");
    return nullptr;
}
extern "C" void mc_decklink_out_video(mc_dl_out *, const uint8_t *, int) {}
extern "C" void mc_decklink_out_audio(mc_dl_out *, const float *, int) {}
extern "C" void mc_decklink_out_close(mc_dl_out *) {}

#endif
