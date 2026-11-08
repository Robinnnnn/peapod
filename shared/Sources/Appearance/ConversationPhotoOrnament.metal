#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Orthographic sphere projection mixed gently with the original crop. The
// center stays fixed and the perimeter samples the original perimeter exactly.
[[ stitchable ]] half4 conversationPhotoSphere(float2 position, SwiftUI::Layer photo, float diameter) {
    float2 p = (position / diameter - 0.5) * 2.0;
    float radius = length(p);
    if (radius > 1.0) { return half4(0); }
    float curvedRadius = asin(min(radius, 1.0)) / (M_PI_F * 0.5);
    // Keep central features gentle; let the outer portion roll around the ball.
    float curvature = 0.22 + 0.22 * smoothstep(0.45, 1.0, radius);
    float sampleRadius = mix(radius, curvedRadius, curvature);
    float2 samplePoint = radius > 0.0001 ? p * (sampleRadius / radius) : p;
    half4 color = photo.sample((samplePoint * 0.5 + 0.5) * diameter);

    float z = sqrt(max(0.0, 1.0 - radius * radius));
    float3 normal = float3(p.x, p.y, z);
    float illumination = max(0.0, dot(normal, normalize(float3(-0.38, -0.48, 1.0))));
    float shade = 0.70 + 0.30 * illumination;
    color.rgb *= half(shade);
    return color;
}

// A reflection on the actual curved surface, with a soft lobe and a smaller
// specular core. It feathers continuously instead of painting a white shape.
[[ stitchable ]] half4 conversationOrnamentGloss(float2 position, half4 color, float diameter) {
    float2 p = (position / diameter - 0.5) * 2.0;
    float radiusSquared = dot(p, p);
    if (radiusSquared > 1.0) { return half4(0); }
    float3 normal = float3(p, sqrt(max(0.0, 1.0 - radiusSquared)));
    float alignment = max(0.0, dot(normal, normalize(float3(-0.54, -0.66, 0.53))));
    float reflection = 0.20 * pow(alignment, 38.0) + 0.50 * pow(alignment, 150.0);
    color.rgb = mix(color.rgb, half3(1.0, 0.985, 0.955) * color.a, half(reflection));
    return color;
}

// Smooth, nonperiodic grain: long warp fibers with much fainter cross threads.
// Coordinates are display pixels so the texture stays fine at every scale.
static float conversationRibbonGrainHash(float2 point) {
    float3 p = fract(float3(point.x, point.y, point.x) * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

static float conversationRibbonGrain(float2 point) {
    float2 cell = floor(point);
    float2 fraction = fract(point);
    float2 blend = fraction * fraction * (3.0 - 2.0 * fraction);
    float top = mix(conversationRibbonGrainHash(cell),
                    conversationRibbonGrainHash(cell + float2(1.0, 0.0)), blend.x);
    float bottom = mix(conversationRibbonGrainHash(cell + float2(0.0, 1.0)),
                       conversationRibbonGrainHash(cell + float2(1.0, 1.0)), blend.x);
    return mix(top, bottom, blend.y) - 0.5;
}

// Draw over a white Rectangle. A broad asymmetric sheen and soft selvedges give
// a narrow, flat ivory ribbon material without metallic stripes or animation.
[[ stitchable ]] half4 conversationRibbonSatin(
    float2 position, half4 color, float2 size, float displayScale
) {
    if (!all(isfinite(size)) || size.x <= 0.0 || size.y <= 0.0) {
        return half4(0.0);
    }
    float scale = isfinite(displayScale) ? max(displayScale, 1.0) : 1.0;
    float u = clamp(position.x / max(size.x, 0.0001), 0.0, 1.0);
    float sheenPosition = (u - 0.36) / 0.26;
    float sheen = 0.065 * exp(-sheenPosition * sheenPosition);
    float selvedge = 0.035 * exp(-u * 22.0) + 0.085 * exp(-(1.0 - u) * 18.0);
    float2 pixel = position * scale;
    float warp = conversationRibbonGrain(pixel * float2(0.90, 0.065));
    float weft = conversationRibbonGrain(pixel * float2(0.13, 0.85) + float2(17.0, 9.0));
    float texture = 0.007 * warp + 0.003 * weft;
    // Color effects return linear RGB; keep enough warmth/edge contrast against paper.
    float3 ivory = clamp(float3(0.815, 0.760, 0.607) + sheen - selvedge + texture, 0.0, 1.0);
    return half4(half3(ivory) * color.a, color.a);
}
