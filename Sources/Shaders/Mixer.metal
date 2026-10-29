#include <metal_stdlib>
using namespace metal;

// Per-source rendering parameters. Must match `LayerParams` in MetalMixer.swift
// (6 ints, 22 floats, then keyOn + 6 floats; all 4-byte scalars, same order).
struct LayerParams {
    int has;          // a texture is bound
    int premul;       // source alpha is premultiplied
    int mirror;
    int deinterlace;  // simple line blend
    int sharpen;
    int hasCC;        // colour correction active
    float srcW, srcH;
    float zoom, panX, panY;
    float cropL, cropT, cropR, cropB;   // fraction removed from each edge (0..1)
    float alpha;                        // input opacity (0..1)
    float mixAlpha;                     // overlay fade / layer visibility (0..1)
    float gainR, gainG, gainB;
    float gammaR, gammaG, gammaB;
    float liftR, liftG, liftB;
    float saturation, hue;              // saturation multiplier, hue degrees
    int keyOn;                          // colour / chroma key
    float keyR, keyG, keyB;
    float keyTol, keySoft, keySpill;
    int yuv;      // 0 = BGRA texture; 1..4 = NV12 planes (luma tex + CbCr tex): 1 709 video, 2 601 video, 3 709 full, 4 601 full
};

/// One source = luma (or BGRA) texture + optional CbCr texture. Decoder frames stay in NV12:
/// converting here costs nothing extra and saves a full-frame conversion per decoded frame.
static float4 srcSample(texture2d<float> tex, texture2d<float> texC, sampler smp, float2 s, constant LayerParams &L) {
    if (L.yuv == 0) return tex.sample(smp, s);
    float y = tex.sample(smp, s).r;
    float2 c = texC.sample(smp, s).rg;
    bool full = L.yuv >= 3;
    if (full) { c -= 0.5; } else { y = (y - 16.0 / 255.0) * (255.0 / 219.0); c = (c - 128.0 / 255.0) * (255.0 / 224.0); }
    float3 rgb;
    if (L.yuv == 1 || L.yuv == 3) {
        rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
    } else {
        rgb = float3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x);
    }
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// Must match `MixParams` in MetalMixer.swift.
struct MixParams {
    float t;
    int transition;   // 0 none, 1 fade, 2 wipe, 3 slide, 4 dip, 5 merge, 6 fly, 7 crosszoom, 8 zoom
    float ftb;
    float outW, outH;
};

// Must match `TileParams` in MetalMixer.swift.
struct TileParams {
    float x, y, w, h;          // destination rect in pixels
    float borderR, borderG, borderB;
    float border;              // border width in pixels (0 = none)
};

static float2 fitUV(float2 uv, float sw, float sh, float dw, float dh, thread bool &inside) {
    float sa = sw / max(sh, 1.0);
    float da = dw / max(dh, 1.0);
    float2 scale = sa > da ? float2(1.0, da / sa) : float2(sa / da, 1.0);
    float2 off = (1.0 - scale) * 0.5;
    float2 s = (uv - off) / scale;
    inside = s.x >= 0.0 && s.y >= 0.0 && s.x <= 1.0 && s.y <= 1.0;
    return s;
}

static float3 colorCorrect(float3 c, constant LayerParams &L) {
    float3 lift = float3(L.liftR, L.liftG, L.liftB);
    float3 gain = float3(L.gainR, L.gainG, L.gainB);
    float3 gamma = max(float3(L.gammaR, L.gammaG, L.gammaB), float3(0.01));
    c = gain * (c + lift * (1.0 - c));
    c = pow(clamp(c, 0.0, 1.0), 1.0 / gamma);
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(luma), c, L.saturation);
    if (L.hue != 0.0) {
        // rotate chroma in YIQ space
        float a = L.hue * 0.01745329252;
        float cs = cos(a), sn = sin(a);
        float y = dot(c, float3(0.299, 0.587, 0.114));
        float i = dot(c, float3(0.596, -0.274, -0.322));
        float q = dot(c, float3(0.211, -0.523, 0.312));
        float i2 = i * cs - q * sn;
        float q2 = i * sn + q * cs;
        c = float3(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2, y - 1.106 * i2 + 1.703 * q2);
    }
    return clamp(c, 0.0, 1.0);
}

/// Samples one source with position/zoom/crop/mirror/deinterlace/sharpen/CC.
/// Returns straight (non-premultiplied) colour with alpha = source alpha * input opacity.
static float4 sampleLayer(texture2d<float> tex, texture2d<float> texC, sampler smp, float2 uv, constant LayerParams &L,
                          float dw, float dh) {
    if (L.has == 0) return float4(0.0);
    float z = max(L.zoom, 0.01);
    float2 p = (uv - 0.5 - float2(L.panX, -L.panY) * 0.5) / z + 0.5;
    bool inside = false;
    float2 s = fitUV(p, L.srcW, L.srcH, dw, dh, inside);
    if (!inside) return float4(0.0);
    if (s.x < L.cropL || s.x > 1.0 - L.cropR || s.y < L.cropT || s.y > 1.0 - L.cropB) return float4(0.0);
    if (L.mirror != 0) s.x = 1.0 - s.x;
    float4 c;
    float2 d = 1.0 / float2(max(L.srcW, 1.0), max(L.srcH, 1.0));
    if (L.deinterlace != 0) {
        c = (srcSample(tex, texC, smp, s, L) + srcSample(tex, texC, smp, s + float2(0.0, d.y), L)) * 0.5;
    } else {
        c = srcSample(tex, texC, smp, s, L);
    }
    if (L.sharpen != 0) {
        float4 blur = (srcSample(tex, texC, smp, s + float2(d.x, 0.0), L) + srcSample(tex, texC, smp, s - float2(d.x, 0.0), L) +
                       srcSample(tex, texC, smp, s + float2(0.0, d.y), L) + srcSample(tex, texC, smp, s - float2(0.0, d.y), L)) * 0.25;
        c.rgb = clamp(c.rgb + (c.rgb - blur.rgb) * 0.6, 0.0, 1.0);
    }
    if (L.premul != 0 && c.a > 0.0001) c.rgb /= c.a;
    if (L.keyOn != 0) {
        // chroma key in Cb/Cr (BT.709): distance from the key colour drives alpha, near-key pixels lose spill
        float3 kc = float3(L.keyR, L.keyG, L.keyB);
        float2 kcc = float2(dot(kc, float3(-0.1146, -0.3854, 0.5)), dot(kc, float3(0.5, -0.4542, -0.0458)));
        float2 pcc = float2(dot(c.rgb, float3(-0.1146, -0.3854, 0.5)), dot(c.rgb, float3(0.5, -0.4542, -0.0458)));
        float d = distance(pcc, kcc);
        float a = smoothstep(L.keyTol, L.keyTol + max(L.keySoft, 0.001), d);
        float luma = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
        float near = 1.0 - smoothstep(L.keyTol, L.keyTol + max(L.keySoft, 0.001) + 0.25, d);
        c.rgb = mix(c.rgb, float3(luma), clamp(L.keySpill * near, 0.0, 1.0));
        c.a *= a;
    }
    if (L.hasCC != 0) c.rgb = colorCorrect(c.rgb, L);
    c.a *= clamp(L.alpha, 0.0, 1.0);
    return c;
}

/// Opaque layer (program/preview): composited over black.
static float3 layerRGB(texture2d<float> tex, texture2d<float> texC, sampler smp, float2 uv, constant LayerParams &L, float dw, float dh) {
    float4 c = sampleLayer(tex, texC, smp, uv, L, dw, dh);
    return c.rgb * c.a;
}

static float3 zoomed(texture2d<float> tex, texture2d<float> texC, sampler smp, float2 uv, float scale, constant LayerParams &L,
                     float dw, float dh) {
    if (scale <= 0.0001) return float3(0.0);
    return layerRGB(tex, texC, smp, 0.5 + (uv - 0.5) / scale, L, dw, dh);
}

static float3 overlayOver(float3 c, texture2d<float> tex, texture2d<float> texC, sampler smp, float2 uv, constant LayerParams &L,
                          float dw, float dh) {
    if (L.has == 0 || L.mixAlpha <= 0.0) return c;
    float4 o = sampleLayer(tex, texC, smp, uv, L, dw, dh);
    float a = o.a * L.mixAlpha;
    return o.rgb * a + c * (1.0 - a);
}

// layers: 0 = A (program), 1 = B (preview/next), 2..5 = overlay 1..4, 6 = stinger
kernel void mixKernel(texture2d<float> texA [[texture(0)]],
                      texture2d<float> texB [[texture(1)]],
                      texture2d<float> texO1 [[texture(2)]],
                      texture2d<float> texO2 [[texture(3)]],
                      texture2d<float> texO3 [[texture(4)]],
                      texture2d<float> texO4 [[texture(5)]],
                      texture2d<float> texS [[texture(6)]],
                      texture2d<float, access::write> outTex [[texture(7)]],
                      texture2d<float> cA [[texture(8)]],
                      texture2d<float> cB [[texture(9)]],
                      texture2d<float> cO1 [[texture(10)]],
                      texture2d<float> cO2 [[texture(11)]],
                      texture2d<float> cO3 [[texture(12)]],
                      texture2d<float> cO4 [[texture(13)]],
                      texture2d<float> cS [[texture(14)]],
                      constant MixParams &p [[buffer(0)]],
                      constant LayerParams *layers [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(outTex.get_width(), outTex.get_height());
    float W = p.outW, H = p.outH;
    constant LayerParams &LA = layers[0];
    constant LayerParams &LB = layers[1];

    float3 a = layerRGB(texA, cA, smp, uv, LA, W, H);
    float3 c = a;

    if (p.transition != 0) {
        float t = clamp(p.t, 0.0, 1.0);
        float3 b = layerRGB(texB, cB, smp, uv, LB, W, H);
        switch (p.transition) {
        case 1:
            c = mix(a, b, t);
            break;
        case 2: {
            float e = 0.01;
            float k = smoothstep(t - e, t + e, uv.x);
            c = mix(b, a, k);
            break;
        }
        case 3:
            if (uv.x < 1.0 - t) {
                c = layerRGB(texA, cA, smp, float2(uv.x + t, uv.y), LA, W, H);
            } else {
                c = layerRGB(texB, cB, smp, float2(uv.x - (1.0 - t), uv.y), LB, W, H);
            }
            break;
        case 4:
            c = t < 0.5 ? mix(a, float3(0.0), t * 2.0) : mix(float3(0.0), b, (t - 0.5) * 2.0);
            break;
        case 5: {
            float s = smoothstep(0.0, 1.0, t);
            c = mix(zoomed(texA, cA, smp, uv, 1.0 + 0.15 * s, LA, W, H), zoomed(texB, cB, smp, uv, 0.87 + 0.13 * s, LB, W, H), s);
            break;
        }
        case 6: {
            float s = smoothstep(0.0, 1.0, t);
            float2 z = 0.5 + (uv - 0.5) / max(s, 0.0001);
            bool inB = z.x >= 0.0 && z.y >= 0.0 && z.x <= 1.0 && z.y <= 1.0;
            c = inB ? zoomed(texB, cB, smp, uv, s, LB, W, H) : a;
            break;
        }
        case 7: {
            float u = 1.0 - t;
            float3 za = zoomed(texA, cA, smp, uv, 1.0 + 3.0 * t * t, LA, W, H);
            float3 zb = zoomed(texB, cB, smp, uv, 1.0 + 3.0 * u * u, LB, W, H);
            c = mix(za, zb, smoothstep(0.35, 0.65, t));
            break;
        }
        case 8: {
            float s = 0.5 + 0.5 * smoothstep(0.0, 1.0, t);
            c = mix(a, zoomed(texB, cB, smp, uv, s, LB, W, H), t);
            break;
        }
        default:
            c = mix(a, b, t);
            break;
        }
    }

    c = overlayOver(c, texO1, cO1, smp, uv, layers[2], W, H);
    c = overlayOver(c, texO2, cO2, smp, uv, layers[3], W, H);
    c = overlayOver(c, texO3, cO3, smp, uv, layers[4], W, H);
    c = overlayOver(c, texO4, cO4, smp, uv, layers[5], W, H);
    c *= (1.0 - clamp(p.ftb, 0.0, 1.0));
    c = overlayOver(c, texS, cS, smp, uv, layers[6], W, H);   // stinger sits above everything
    outTex.write(float4(c, 1.0), gid);
}

/// Draws one source into a rectangle of the output (Output 2-4 buses, MultiView tiles).
kernel void tileKernel(texture2d<float> src [[texture(0)]],
                       texture2d<float, access::write> outTex [[texture(1)]],
                       texture2d<float> srcC [[texture(2)]],
                       constant TileParams &tp [[buffer(0)]],
                       constant LayerParams &L [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (float(gid.x) >= tp.w || float(gid.y) >= tp.h) return;
    uint2 dst = uint2(uint(tp.x) + gid.x, uint(tp.y) + gid.y);
    if (dst.x >= outTex.get_width() || dst.y >= outTex.get_height()) return;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(tp.w, tp.h);
    float3 c = layerRGB(src, srcC, smp, uv, L, tp.w, tp.h);
    if (tp.border > 0.0) {
        float fx = float(gid.x), fy = float(gid.y);
        if (fx < tp.border || fy < tp.border || fx >= tp.w - tp.border || fy >= tp.h - tp.border) {
            c = float3(tp.borderR, tp.borderG, tp.borderB);
        }
    }
    outTex.write(float4(c, 1.0), dst);
}

// ---- Input layers (vMix Layers / MultiView): rendered with blending into a transparent frame ----

struct ComposeParams {
    float w, h;           // destination rect size (pixels)
    float border;         // px
    float borderR, borderG, borderB;
};



struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut displayVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// fit = (srcW, srcH, dstW, dstH)
fragment float4 displayFragment(VOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                texture2d<float> texC [[texture(1)]],
                                constant float4 &fit [[buffer(0)]],
                                constant LayerParams &L [[buffer(1)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    bool inside = false;
    float2 s = fitUV(in.uv, fit.x, fit.y, fit.z, fit.w, inside);
    if (!inside) return float4(0.0, 0.0, 0.0, 1.0);
    return float4(srcSample(tex, texC, smp, s, L).rgb, 1.0);
}


/// Draws one layer into the current viewport (the layer's rectangle). Output is premultiplied; the
/// pipeline blends src + dst * (1 - srcAlpha), so layers stack with transparency.
fragment float4 composeFragment(VOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                texture2d<float> texC [[texture(1)]],
                                constant LayerParams &L [[buffer(0)]],
                                constant ComposeParams &cp [[buffer(1)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 px = in.uv * float2(cp.w, cp.h);
    if (cp.border > 0.0 && (px.x < cp.border || px.y < cp.border || px.x >= cp.w - cp.border || px.y >= cp.h - cp.border)) {
        return float4(cp.borderR, cp.borderG, cp.borderB, 1.0);
    }
    float4 c = sampleLayer(tex, texC, smp, in.uv, L, cp.w, cp.h);
    float a = clamp(c.a * L.mixAlpha, 0.0, 1.0);
    return float4(c.rgb * a, a);
}

// ---- 3D LUT (.cube) per input: source (BGRA or NV12) → LUT → premultiplied BGRA, same size ----

struct LutParams {
    float strength;
    float size;
    int premul;
    int pad;
    float dminR, dminG, dminB;
    float dmaxR, dmaxG, dmaxB;
};

kernel void lutKernel(texture2d<float> src [[texture(0)]],
                      texture2d<float, access::write> outTex [[texture(1)]],
                      texture2d<float> srcC [[texture(2)]],
                      texture3d<float> lut [[texture(3)]],
                      constant LayerParams &L [[buffer(0)]],
                      constant LutParams &lp [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint W = outTex.get_width(), H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) return;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float4 c = srcSample(src, srcC, smp, uv, L);
    float a = c.a;
    float3 rgb = (lp.premul != 0 && a > 0.0001) ? c.rgb / a : c.rgb;
    float3 dmin = float3(lp.dminR, lp.dminG, lp.dminB), dmax = float3(lp.dmaxR, lp.dmaxG, lp.dmaxB);
    float3 t = clamp((rgb - dmin) / max(dmax - dmin, float3(1e-5)), 0.0, 1.0);
    float n = lp.size;
    float3 g = lut.sample(smp, t * ((n - 1.0) / n) + 0.5 / n).rgb;
    rgb = mix(rgb, clamp(g, 0.0, 1.0), clamp(lp.strength, 0.0, 1.0));
    outTex.write(float4(rgb * a, a), gid);
}
