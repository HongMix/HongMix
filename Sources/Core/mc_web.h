// Embedded Chromium (CEF) web engine for Web Browser inputs — off-screen rendering like vMix:
// GPU frames (IOSurface) at the program rate, page audio straight to the mixer, mouse/keyboard/IME input.
// All functions must be called on the main thread except where noted.
#ifndef MC_WEB_H
#define MC_WEB_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct mc_web mc_web;

/* iosurface: IOSurfaceRef, valid only during the call (copy it). Main thread. */
typedef void (*mc_web_frame_cb)(void *user, void *iosurface, int width, int height);
/* CPU fallback frame (BGRA, top-left origin). Main thread. */
typedef void (*mc_web_cpu_frame_cb)(void *user, const uint8_t *bgra, int width, int height, int stride);
/* Planar float audio. Audio thread. */
typedef void (*mc_web_audio_cb)(void *user, const float *const *planes, int channels, int frames, int sample_rate);
/* 0 loading, 1 loaded, 2 error, 3 title changed; message = URL / error text / title. Main thread. */
typedef void (*mc_web_status_cb)(void *user, int state, const char *message);

typedef struct {
    mc_web_frame_cb on_frame;
    mc_web_cpu_frame_cb on_cpu_frame;
    mc_web_audio_cb on_audio;
    mc_web_status_cb on_status;
    void *user;
} mc_web_callbacks;

int mc_web_available(void);            /* engine compiled in and framework present in the app */
const char *mc_web_version(void);
int mc_web_init(void);                 /* lazy, idempotent; 1 = ready */
void mc_web_shutdown(void);

mc_web *mc_web_open(const char *url, int width, int height, int fps, int transparent, mc_web_callbacks cb);
void mc_web_close(mc_web *w);
void mc_web_navigate(mc_web *w, const char *url);
void mc_web_reload(mc_web *w);
void mc_web_back(mc_web *w);
void mc_web_forward(mc_web *w);
void mc_web_set_fps(mc_web *w, int fps);
void mc_web_eval_js(mc_web *w, const char *js);

/* Input. x/y in page pixels (top-left). modifiers = NSEvent.modifierFlags raw value. */
void mc_web_mouse_move(mc_web *w, int x, int y, int modifiers, int leave);
void mc_web_mouse_button(mc_web *w, int x, int y, int button /*0 L,1 M,2 R*/, int up, int clicks, int modifiers);
void mc_web_mouse_wheel(mc_web *w, int x, int y, int dx, int dy, int modifiers);
/* type: 0 raw key down, 1 key up, 2 char */
void mc_web_key(mc_web *w, int type, int mac_key_code, int windows_key_code, uint16_t character,
                uint16_t unmodified_character, int modifiers);
void mc_web_focus(mc_web *w, int focus);
void mc_web_ime_set_composition(mc_web *w, const char *utf8, int sel_start, int sel_end);
void mc_web_ime_commit(mc_web *w, const char *utf8);
void mc_web_ime_cancel(mc_web *w);
/* edit commands: 0 copy, 1 cut, 2 paste, 3 select all, 4 undo, 5 redo */
void mc_web_edit(mc_web *w, int command);

#ifdef __cplusplus
}
#endif
#endif
