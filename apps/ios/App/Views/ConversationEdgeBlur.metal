#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// bands = (topEdge, topClear, bottomClear, bottomEdge) in viewport points.
// sigmas = peak Gaussian sigma of the top and bottom bands, reached only at the edges.
[[ stitchable ]] half4 conversationEdgeBlur(
    float2 position, SwiftUI::Layer layer, float originY,
    float4 bands, float2 sigmas, float2 axis, float maximumRadius, float pixelStep
) {
    float y = originY + position.y;
    // Normalized depth: 0 at the clear line, 1 at the physical edge. Sigma eases in
    // quadratically, so softening develops over several lines with no plateau.
    float top = bands.y > bands.x ? saturate((bands.y - y) / (bands.y - bands.x)) : 0.0;
    float bottom = bands.w > bands.z ? saturate((y - bands.z) / (bands.w - bands.z)) : 0.0;
    float sigma = max(sigmas.x * top * top, sigmas.y * bottom * bottom);
    float radius = min(3.0 * sigma, maximumRadius);
    // Cover every source pixel. Sparse point-spaced taps create stripes at 3x.
    float step = max(pixelStep, maximumRadius / 48.0);
    if (radius < step * 0.5) return layer.sample(position);

    sigma = radius / 3.0;
    float inverseVariance = 0.5 / (sigma * sigma);
    int limit = int(ceil(radius / step));
    float4 color = float4(layer.sample(position));
    float total = 1.0;
    // Pair adjacent Gaussian taps using bilinear sampling, keeping a dense kernel
    // with at most 49 texture reads per pass and no added color or opacity layer.
    for (int i = 1; i <= 48; i += 2) {
        if (i > limit) break;
        float distance1 = float(i) * step;
        float distance2 = float(i + 1) * step;
        float weight1 = exp(-distance1 * distance1 * inverseVariance);
        float weight2 = i + 1 <= limit ? exp(-distance2 * distance2 * inverseVariance) : 0.0;
        float weight = weight1 + weight2;
        if (weight < 0.000001) break;
        float offset = (distance1 * weight1 + distance2 * weight2) / weight;
        color += weight * (float4(layer.sample(position + axis * offset))
                         + float4(layer.sample(position - axis * offset)));
        total += 2.0 * weight;
    }
    return half4(color / total);
}
