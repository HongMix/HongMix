// Embedded Chromium (CEF) for Web Browser inputs. See mc_web.h.
// Built with -DMC_HAVE_CEF=1 when ThirdParty/cef is present (scripts/fetch-cef.sh); otherwise stubs.
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#include "mc_web.h"

#if MC_HAVE_CEF
#include <string>
#include <vector>
#include <set>
#include <mutex>
#include "include/cef_app.h"
#include "include/cef_version.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include "include/cef_audio_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/wrapper/cef_library_loader.h"
#endif

// ---------------------------------------------------------------------------------------------
// NSApplication subclass (Info.plist NSPrincipalClass). CEF requires the app to implement
// CefAppProtocol so Chromium knows when -sendEvent: is on the stack.
#if MC_HAVE_CEF
@interface BraceletMixApplication : NSApplication <CefAppProtocol> {
@private
    BOOL handlingSendEvent_;
}
@end
@implementation BraceletMixApplication
- (BOOL)isHandlingSendEvent { return handlingSendEvent_; }
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent { handlingSendEvent_ = handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent sendingEventScoper;
    [super sendEvent:event];
}
@end
#else
@interface BraceletMixApplication : NSApplication
@end
@implementation BraceletMixApplication
@end
#endif

#if !MC_HAVE_CEF
// ---------------------------------------------------------------------------------------------
extern "C" {
int mc_web_available(void) { return 0; }
const char *mc_web_version(void) { return "내장 브라우저 엔진 없음"; }
int mc_web_init(void) { return 0; }
void mc_web_shutdown(void) {}
mc_web *mc_web_open(const char *, int, int, int, int, mc_web_callbacks) { return nullptr; }
void mc_web_close(mc_web *) {}
void mc_web_navigate(mc_web *, const char *) {}
void mc_web_reload(mc_web *) {}
void mc_web_back(mc_web *) {}
void mc_web_forward(mc_web *) {}
void mc_web_set_fps(mc_web *, int) {}
void mc_web_eval_js(mc_web *, const char *) {}
void mc_web_mouse_move(mc_web *, int, int, int, int) {}
void mc_web_mouse_button(mc_web *, int, int, int, int, int, int) {}
void mc_web_mouse_wheel(mc_web *, int, int, int, int, int) {}
void mc_web_key(mc_web *, int, int, int, uint16_t, uint16_t, int) {}
void mc_web_focus(mc_web *, int) {}
void mc_web_ime_set_composition(mc_web *, const char *, int, int) {}
void mc_web_ime_commit(mc_web *, const char *) {}
void mc_web_ime_cancel(mc_web *) {}
void mc_web_edit(mc_web *, int) {}
}
#else
// ---------------------------------------------------------------------------------------------
namespace {

CefScopedLibraryLoader *g_loader = nullptr;
bool g_inited = false;
bool g_failed = false;
NSTimer *g_pumpTimer = nil;
std::string g_version;

uint32_t cefModifiers(int mac) {
    uint32_t m = 0;
    NSEventModifierFlags f = (NSEventModifierFlags)(unsigned)mac;
    if (f & NSEventModifierFlagShift) m |= EVENTFLAG_SHIFT_DOWN;
    if (f & NSEventModifierFlagControl) m |= EVENTFLAG_CONTROL_DOWN;
    if (f & NSEventModifierFlagOption) m |= EVENTFLAG_ALT_DOWN;
    if (f & NSEventModifierFlagCommand) m |= EVENTFLAG_COMMAND_DOWN;
    if (f & NSEventModifierFlagCapsLock) m |= EVENTFLAG_CAPS_LOCK_ON;
    if ((unsigned)mac & (1u << 30)) m |= EVENTFLAG_LEFT_MOUSE_BUTTON;   // set by the app while dragging
    return m;
}

// SwiftUI creates its own NSApplication subclass (ignoring NSPrincipalClass), so the protocol Chromium
// needs is added to whatever class NSApp is, at runtime.
BOOL g_handlingSendEvent = NO;
IMP g_origSendEvent = nullptr;
BOOL bmIsHandlingSendEvent(id, SEL) { return g_handlingSendEvent; }
void bmSetHandlingSendEvent(id, SEL, BOOL v) { g_handlingSendEvent = v; }
void bmSendEvent(id self, SEL cmd, NSEvent *event) {
    BOOL old = g_handlingSendEvent;
    g_handlingSendEvent = YES;
    ((void (*)(id, SEL, NSEvent *))g_origSendEvent)(self, cmd, event);
    g_handlingSendEvent = old;
}
void installCefAppProtocol() {
    if ([NSApp conformsToProtocol:@protocol(CefAppProtocol)]) return;
    Class c = [NSApp class];
    class_addMethod(c, @selector(isHandlingSendEvent), (IMP)bmIsHandlingSendEvent, "B@:");
    class_addMethod(c, @selector(setHandlingSendEvent:), (IMP)bmSetHandlingSendEvent, "v@:B");
    Method m = class_getInstanceMethod(c, @selector(sendEvent:));
    g_origSendEvent = method_getImplementation(m);
    if (!class_addMethod(c, @selector(sendEvent:), (IMP)bmSendEvent, method_getTypeEncoding(m))) {
        method_setImplementation(m, (IMP)bmSendEvent);
    }
    class_addProtocol(c, @protocol(CrAppProtocol));
    class_addProtocol(c, @protocol(CrAppControlProtocol));
    class_addProtocol(c, @protocol(CefAppProtocol));
}

void doPump() {
    if (g_inited) CefDoMessageLoopWork();
}

class App : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    void OnBeforeCommandLineProcessing(const CefString &process_type, CefRefPtr<CefCommandLine> cl) override {
        if (!process_type.empty()) return;
        cl->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");
        cl->AppendSwitch("disable-background-timer-throttling");
        cl->AppendSwitch("disable-renderer-backgrounding");
        cl->AppendSwitch("disable-backgrounding-occluded-windows");
        cl->AppendSwitch("use-mock-keychain");          // never prompt for the login keychain
    }
    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay_ms > 0 ? delay_ms : 0) * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ doPump(); });
    }
    IMPLEMENT_REFCOUNTING(App);
};

class Client;
}  // namespace

struct mc_web {
    CefRefPtr<Client> client;
};

namespace {

std::set<Client *> g_clients;

class Client : public CefClient,
               public CefRenderHandler,
               public CefAudioHandler,
               public CefLifeSpanHandler,
               public CefLoadHandler,
               public CefDisplayHandler {
public:
    Client(int w, int h, mc_web_callbacks cb) : w_(w), h_(h), cb_(cb) {}

    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
    CefRefPtr<CefAudioHandler> GetAudioHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

    // ---- render
    void GetViewRect(CefRefPtr<CefBrowser>, CefRect &rect) override { rect = CefRect(0, 0, w_, h_); }
    bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo &info) override {
        info.device_scale_factor = 1.0f;
        info.depth = 24;
        info.depth_per_component = 8;
        info.rect = CefRect(0, 0, w_, h_);
        info.available_rect = info.rect;
        return true;
    }
    void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList &, const void *buffer, int width,
                 int height) override {
        if (type == PET_VIEW && cb_.on_cpu_frame && !closed_)
            cb_.on_cpu_frame(cb_.user, (const uint8_t *)buffer, width, height, width * 4);
    }
    void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList &,
                            const CefAcceleratedPaintInfo &info) override {
        if (type != PET_VIEW || closed_ || !cb_.on_frame || !info.shared_texture_io_surface) return;
        IOSurfaceRef s = (IOSurfaceRef)info.shared_texture_io_surface;
        cb_.on_frame(cb_.user, (void *)s, (int)IOSurfaceGetWidth(s), (int)IOSurfaceGetHeight(s));
    }

    // ---- audio (page audio goes to the mixer instead of the speakers)
    bool GetAudioParameters(CefRefPtr<CefBrowser>, CefAudioParameters &params) override {
        params.channel_layout = CEF_CHANNEL_LAYOUT_STEREO;
        params.sample_rate = 48000;
        params.frames_per_buffer = 480;
        return true;
    }
    void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters &params, int channels) override {
        channels_ = channels;
        rate_ = params.sample_rate;
    }
    void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float **data, int frames, int64_t) override {
        if (cb_.on_audio && !closed_) cb_.on_audio(cb_.user, data, channels_, frames, rate_);
    }
    void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override {}
    void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString &) override {}

    // ---- life span
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        browser_ = browser;
        browser->GetHost()->SetFocus(true);
        browser->GetHost()->WasResized();
        if (!pendingURL_.empty()) {
            browser->GetMainFrame()->LoadURL(pendingURL_);
            pendingURL_.clear();
        }
    }
    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int, const CefString &target_url,
                       const CefString &, WindowOpenDisposition, bool, const CefPopupFeatures &, CefWindowInfo &,
                       CefRefPtr<CefClient> &, CefBrowserSettings &, CefRefPtr<CefDictionaryValue> &, bool *) override {
        // like vMix: open popups / target=_blank in the same input
        browser->GetMainFrame()->LoadURL(target_url);
        return true;
    }
    void OnBeforeClose(CefRefPtr<CefBrowser>) override {
        browser_ = nullptr;
        g_clients.erase(this);
    }

    // ---- load / display
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool, bool) override {
        if (!cb_.on_status || closed_) return;
        std::string url = browser->GetMainFrame()->GetURL().ToString();
        cb_.on_status(cb_.user, isLoading ? 0 : 1, url.c_str());
    }
    void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
        if (cb_.on_status && !closed_) cb_.on_status(cb_.user, 3, title.ToString().c_str());
    }
    void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString &text,
                     const CefString &url) override {
        if (!frame->IsMain() || code == ERR_ABORTED || !cb_.on_status || closed_) return;
        std::string m = "로드 실패: " + text.ToString() + " (" + url.ToString() + ")";
        cb_.on_status(cb_.user, 2, m.c_str());
    }

    CefRefPtr<CefBrowser> browser() { return browser_; }
    void setPendingURL(const std::string &u) { pendingURL_ = u; }
    void markClosed() { closed_ = true; }

private:
    int w_, h_;
    mc_web_callbacks cb_;
    CefRefPtr<CefBrowser> browser_;
    std::string pendingURL_;
    int channels_ = 2;
    int rate_ = 48000;
    bool closed_ = false;
    IMPLEMENT_REFCOUNTING(Client);
};

CefRefPtr<CefBrowserHost> host(mc_web *w) {
    if (!w || !w->client || !w->client->browser()) return nullptr;
    return w->client->browser()->GetHost();
}

CefMouseEvent mouseEvent(int x, int y, int mods) {
    CefMouseEvent e;
    e.x = x;
    e.y = y;
    e.modifiers = cefModifiers(mods);
    return e;
}

std::string bundlePath(NSString *sub) {
    return std::string([[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:sub] UTF8String]);
}

}  // namespace

extern "C" {

int mc_web_available(void) {
    NSString *fw = [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:@"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
    NSString *helper = [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:@"BraceletMix Helper.app/Contents/MacOS/BraceletMix Helper"];
    return [[NSFileManager defaultManager] fileExistsAtPath:fw] &&
           [[NSFileManager defaultManager] fileExistsAtPath:helper] && !g_failed;
}

const char *mc_web_version(void) {
    if (g_version.empty()) {
        char b[96];
        snprintf(b, sizeof(b), "Chromium %d.%d.%d.%d (CEF %d.%d.%d)", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR,
                 CHROME_VERSION_BUILD, CHROME_VERSION_PATCH, CEF_VERSION_MAJOR, CEF_VERSION_MINOR, CEF_VERSION_PATCH);
        g_version = b;
    }
    return g_version.c_str();
}

int mc_web_init(void) {
    if (g_inited) return 1;
    if (g_failed || !mc_web_available()) return 0;
    installCefAppProtocol();
    if (![NSApp conformsToProtocol:@protocol(CefAppProtocol)]) {
        NSLog(@"[mc_web] NSApp (%@) is not a CefAppProtocol application — check NSPrincipalClass", [NSApp class]);
        g_failed = true;
        return 0;
    }
    g_loader = new CefScopedLibraryLoader();
    if (!g_loader->LoadInMain()) {
        NSLog(@"[mc_web] failed to load the Chromium Embedded Framework");
        g_failed = true;
        return 0;
    }
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    std::vector<char *> argv;
    for (NSString *a in args) argv.push_back(strdup([a UTF8String]));
    CefMainArgs main_args((int)argv.size(), argv.data());

    CefSettings s;
    s.no_sandbox = true;
    s.windowless_rendering_enabled = true;
    s.external_message_pump = true;
    s.multi_threaded_message_loop = false;
    s.log_severity = LOGSEVERITY_WARNING;
    CefString(&s.browser_subprocess_path) = bundlePath(@"Contents/Frameworks/BraceletMix Helper.app/Contents/MacOS/BraceletMix Helper");
    CefString(&s.framework_dir_path) = bundlePath(@"Contents/Frameworks/Chromium Embedded Framework.framework");
    CefString(&s.main_bundle_path) = std::string([[[NSBundle mainBundle] bundlePath] UTF8String]);
    NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *cache = [support stringByAppendingPathComponent:@"BraceletMix/Browser"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    CefString(&s.root_cache_path) = std::string([cache UTF8String]);
    CefString(&s.cache_path) = std::string([[cache stringByAppendingPathComponent:@"Default"] UTF8String]);
    CefString(&s.locale) = "ko";

    CefRefPtr<App> app(new App());
    if (!CefInitialize(main_args, s, app.get(), nullptr)) {
        NSLog(@"[mc_web] CefInitialize failed");
        g_failed = true;
        return 0;
    }
    g_inited = true;
    // backup pump in case a scheduled wake-up is missed
    g_pumpTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer *) { doPump(); }];
    [[NSRunLoop mainRunLoop] addTimer:g_pumpTimer forMode:NSRunLoopCommonModes];
    return 1;
}

void mc_web_shutdown(void) {
    if (!g_inited) return;
    for (Client *c : std::set<Client *>(g_clients)) {
        c->markClosed();
        if (c->browser()) c->browser()->GetHost()->CloseBrowser(true);
    }
    for (int i = 0; i < 50 && !g_clients.empty(); i++) {
        CefDoMessageLoopWork();
        [NSThread sleepForTimeInterval:0.01];
    }
    [g_pumpTimer invalidate];
    g_pumpTimer = nil;
    g_inited = false;
    CefShutdown();
    delete g_loader;
    g_loader = nullptr;
}

mc_web *mc_web_open(const char *url, int width, int height, int fps, int transparent, mc_web_callbacks cb) {
    if (!mc_web_init()) return nullptr;
    mc_web *w = new mc_web();
    w->client = new Client(width, height, cb);
    g_clients.insert(w->client.get());
    CefWindowInfo wi;
    wi.SetAsWindowless(nullptr);
    wi.shared_texture_enabled = true;                      // GPU frames (IOSurface), no CPU copies
    CefBrowserSettings bs;
    bs.windowless_frame_rate = fps > 0 ? (fps > 60 ? 60 : fps) : 60;
    bs.background_color = transparent ? 0x00000000 : 0xFFFFFFFF;
    std::string u = url ? url : "about:blank";
    if (!CefBrowserHost::CreateBrowser(wi, w->client.get(), u, bs, nullptr, nullptr)) {
        g_clients.erase(w->client.get());
        delete w;
        return nullptr;
    }
    return w;
}

void mc_web_close(mc_web *w) {
    if (!w) return;
    if (w->client) {
        w->client->markClosed();
        if (w->client->browser()) w->client->browser()->GetHost()->CloseBrowser(true);
    }
    delete w;
}

void mc_web_navigate(mc_web *w, const char *url) {
    if (!w || !url) return;
    if (w->client->browser()) w->client->browser()->GetMainFrame()->LoadURL(url);
    else w->client->setPendingURL(url);
}
void mc_web_reload(mc_web *w) { if (w && w->client->browser()) w->client->browser()->Reload(); }
void mc_web_back(mc_web *w) { if (w && w->client->browser()) w->client->browser()->GoBack(); }
void mc_web_forward(mc_web *w) { if (w && w->client->browser()) w->client->browser()->GoForward(); }
void mc_web_set_fps(mc_web *w, int fps) { if (auto h = host(w)) h->SetWindowlessFrameRate(fps > 60 ? 60 : fps); }
void mc_web_eval_js(mc_web *w, const char *js) {
    if (w && js && w->client->browser()) {
        CefRefPtr<CefFrame> f = w->client->browser()->GetMainFrame();
        f->ExecuteJavaScript(js, f->GetURL(), 0);
    }
}

void mc_web_mouse_move(mc_web *w, int x, int y, int mods, int leave) {
    if (auto h = host(w)) h->SendMouseMoveEvent(mouseEvent(x, y, mods), leave != 0);
}
void mc_web_mouse_button(mc_web *w, int x, int y, int button, int up, int clicks, int mods) {
    auto h = host(w);
    if (!h) return;
    if (!up) h->SetFocus(true);
    cef_mouse_button_type_t t = button == 2 ? MBT_RIGHT : (button == 1 ? MBT_MIDDLE : MBT_LEFT);
    h->SendMouseClickEvent(mouseEvent(x, y, mods), t, up != 0, clicks > 0 ? clicks : 1);
}
void mc_web_mouse_wheel(mc_web *w, int x, int y, int dx, int dy, int mods) {
    if (auto h = host(w)) h->SendMouseWheelEvent(mouseEvent(x, y, mods), dx, dy);
}
void mc_web_key(mc_web *w, int type, int mac_code, int win_code, uint16_t ch, uint16_t unmod, int mods) {
    auto h = host(w);
    if (!h) return;
    CefKeyEvent e;
    e.type = type == 1 ? KEYEVENT_KEYUP : (type == 2 ? KEYEVENT_CHAR : KEYEVENT_RAWKEYDOWN);
    e.modifiers = cefModifiers(mods);
    e.native_key_code = mac_code;
    e.windows_key_code = win_code;
    e.character = ch;
    e.unmodified_character = unmod;
    h->SendKeyEvent(e);
}
void mc_web_focus(mc_web *w, int focus) { if (auto h = host(w)) h->SetFocus(focus != 0); }
void mc_web_ime_set_composition(mc_web *w, const char *utf8, int sel_start, int sel_end) {
    auto h = host(w);
    if (!h || !utf8) return;
    CefString text(utf8);
    std::vector<CefCompositionUnderline> lines;
    CefCompositionUnderline u;
    u.range = CefRange(0, (uint32_t)text.length());
    u.color = 0xFF000000;
    u.background_color = 0;
    u.thick = 0;
    lines.push_back(u);
    h->ImeSetComposition(text, lines, CefRange::InvalidRange(), CefRange((uint32_t)sel_start, (uint32_t)sel_end));
}
void mc_web_ime_commit(mc_web *w, const char *utf8) {
    if (auto h = host(w)) h->ImeCommitText(CefString(utf8 ? utf8 : ""), CefRange::InvalidRange(), 0);
}
void mc_web_ime_cancel(mc_web *w) { if (auto h = host(w)) h->ImeCancelComposition(); }
void mc_web_edit(mc_web *w, int cmd) {
    if (!w || !w->client->browser()) return;
    CefRefPtr<CefFrame> f = w->client->browser()->GetFocusedFrame();
    if (!f) f = w->client->browser()->GetMainFrame();
    switch (cmd) {
    case 0: f->Copy(); break;
    case 1: f->Cut(); break;
    case 2: f->Paste(); break;
    case 3: f->SelectAll(); break;
    case 4: f->Undo(); break;
    case 5: f->Redo(); break;
    }
}

}  // extern "C"
#endif
