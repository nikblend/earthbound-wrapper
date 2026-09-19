//
//  Shaders.metal
//  EarthboundWrapper
//
//  One textured quad. All the interesting decisions — how big, where, cropped how
//  — are made on the CPU and arrive as a rectangle in normalised device
//  coordinates, because aspect-ratio arithmetic is far easier to reason about in
//  points than in a vertex shader.
//
//  The buffer arguments are bare `float4` and `float` rather than structs. A
//  single-member struct has the same layout, but matching the Swift `SIMD4<Float>`
//  immediately is one fewer thing to be wrong about.
//
//  Note the coordinate flip: Metal's NDC has y pointing up, a texture's v axis
//  points down. The rect arrives with y as its *bottom* edge, and v is inverted
//  here so both conventions stay honest on their own side.
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

/// Expands a unit quad to fill the rectangle described by `rect`, packed as
/// `(left, bottom, width, height)` in normalised device coordinates.
vertex VertexOut ebBlitVertex(uint vertexID [[vertex_id]],
                              constant float4 &rect [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };
    float2 corner = corners[vertexID];
    float2 origin = rect.xy;
    float2 extent = rect.zw;

    VertexOut out;
    out.position = float4(origin + corner * extent, 0.0, 1.0);
    // corner.y == 0 is the rect's bottom edge, which is v == 1 in the texture.
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

/// `smoothing` selects bilinear filtering when non-zero.
fragment float4 ebBlitFragment(VertexOut in [[stage_in]],
                               texture2d<float> source [[texture(0)]],
                               constant float &smoothing [[buffer(0)]]) {
    // Nearest is the honest default for 16-bit pixel art: it preserves the pixel
    // grid, so a non-integer scale factor turns into slightly uneven pixels rather
    // than a soft mush.
    constexpr sampler nearestSampler(coord::normalized,
                                     filter::nearest,
                                     address::clamp_to_edge);
    constexpr sampler smoothedSampler(coord::normalized,
                                      filter::linear,
                                      address::clamp_to_edge);

    if (smoothing > 0.5) {
        return source.sample(smoothedSampler, in.uv);
    }
    return source.sample(nearestSampler, in.uv);
}
