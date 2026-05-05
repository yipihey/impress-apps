#include <metal_stdlib>
using namespace metal;

// Fullscreen quad vertex shader for 2D slice display.
// Generates a quad from vertex_id (6 vertices, 2 triangles).

struct SliceVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex SliceVertexOut slice_vertex(uint vid [[vertex_id]]) {
    // Two-triangle fullscreen quad: CCW winding
    //   0--2/3
    //   | / |
    //  1/4--5
    constexpr float2 positions[6] = {
        {-1.0, 1.0}, {-1.0, -1.0}, { 1.0,  1.0},
        { 1.0, 1.0}, {-1.0, -1.0}, { 1.0, -1.0}
    };
    constexpr float2 texcoords[6] = {
        {0.0, 0.0}, {0.0, 1.0}, {1.0, 0.0},
        {1.0, 0.0}, {0.0, 1.0}, {1.0, 1.0}
    };

    SliceVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = texcoords[vid];
    return out;
}

// Fragment shader: nearest-neighbor sampling of the pre-colormapped RGBA texture.
// Scientists need to see individual grid cells, so no bilinear filtering.
fragment float4 slice_fragment(
    SliceVertexOut in [[stage_in]],
    texture2d<float> sliceTexture [[texture(0)]]
) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
    return sliceTexture.sample(nearestSampler, in.texCoord);
}
