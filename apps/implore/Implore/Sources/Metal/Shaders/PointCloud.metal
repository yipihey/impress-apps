#include <metal_stdlib>
using namespace metal;

// MARK: - Vertex Types

struct PointVertex {
    float3 position [[attribute(0)]];
    float4 color [[attribute(1)]];
    float size [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

// MARK: - Uniforms

struct Uniforms {
    float4x4 modelViewProjection;
    float4x4 modelView;
    float pointSizeMultiplier;
    float time;
    float2 viewportSize;
};

struct Camera {
    float3 position;
    float3 target;
    float3 up;
    float fov;
    float near;
    float far;
    float aspectRatio;
};

// MARK: - Colormap

// Viridis colormap lookup (simplified)
float4 viridis(float t) {
    // Approximation of viridis colormap
    t = saturate(t);

    float3 c0 = float3(0.267004, 0.004874, 0.329415);
    float3 c1 = float3(0.282327, 0.140926, 0.457517);
    float3 c2 = float3(0.253935, 0.265254, 0.529983);
    float3 c3 = float3(0.206756, 0.371758, 0.553117);
    float3 c4 = float3(0.163625, 0.471133, 0.558148);
    float3 c5 = float3(0.127568, 0.566949, 0.550556);
    float3 c6 = float3(0.134692, 0.658636, 0.517649);
    float3 c7 = float3(0.266941, 0.748751, 0.440573);
    float3 c8 = float3(0.477504, 0.821444, 0.318195);
    float3 c9 = float3(0.741388, 0.873449, 0.149561);
    float3 c10 = float3(0.993248, 0.906157, 0.143936);

    float3 color;
    if (t < 0.1) color = mix(c0, c1, t * 10.0);
    else if (t < 0.2) color = mix(c1, c2, (t - 0.1) * 10.0);
    else if (t < 0.3) color = mix(c2, c3, (t - 0.2) * 10.0);
    else if (t < 0.4) color = mix(c3, c4, (t - 0.3) * 10.0);
    else if (t < 0.5) color = mix(c4, c5, (t - 0.4) * 10.0);
    else if (t < 0.6) color = mix(c5, c6, (t - 0.5) * 10.0);
    else if (t < 0.7) color = mix(c6, c7, (t - 0.6) * 10.0);
    else if (t < 0.8) color = mix(c7, c8, (t - 0.7) * 10.0);
    else if (t < 0.9) color = mix(c8, c9, (t - 0.8) * 10.0);
    else color = mix(c9, c10, (t - 0.9) * 10.0);

    return float4(color, 1.0);
}

// MARK: - Vertex Shaders

// 2D Science mode - orthographic projection
vertex VertexOut vertex_science_2d(
    PointVertex in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;

    // Transform position
    out.position = uniforms.modelViewProjection * float4(in.position, 1.0);

    // Color from vertex or colormap
    out.color = in.color;

    // Point size
    out.pointSize = in.size * uniforms.pointSizeMultiplier;

    return out;
}

// 3D Box mode - perspective projection with depth cueing
vertex VertexOut vertex_box_3d(
    PointVertex in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;

    // Transform position
    float4 viewPos = uniforms.modelView * float4(in.position, 1.0);
    out.position = uniforms.modelViewProjection * float4(in.position, 1.0);

    // Depth cueing - fade color based on distance
    float depth = -viewPos.z;
    float depthFade = saturate(1.0 - depth / 100.0);

    // Color with depth cueing
    out.color = float4(in.color.rgb * depthFade, in.color.a);

    // Point size with perspective scaling
    float sizeFactor = 1.0 / (1.0 + depth * 0.01);
    out.pointSize = in.size * uniforms.pointSizeMultiplier * sizeFactor;

    return out;
}

// Art shader mode - custom effects
vertex VertexOut vertex_art(
    PointVertex in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;

    // Animated position
    float3 pos = in.position;
    pos.y += sin(in.position.x * 0.1 + uniforms.time) * 0.5;

    out.position = uniforms.modelViewProjection * float4(pos, 1.0);

    // Animated color
    float hue = fract(in.color.r + uniforms.time * 0.1);
    out.color = viridis(hue);

    // Animated size
    out.pointSize = in.size * uniforms.pointSizeMultiplier *
                    (1.0 + 0.2 * sin(uniforms.time * 2.0 + in.position.x));

    return out;
}

// MARK: - Fragment Shaders

// Basic point fragment - circular with antialiasing
fragment float4 fragment_point(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    // Circular point with soft edge
    float2 center = pointCoord - 0.5;
    float dist = length(center) * 2.0;

    // Soft edge for antialiasing
    float alpha = 1.0 - smoothstep(0.8, 1.0, dist);

    if (alpha < 0.01) discard_fragment();

    return float4(in.color.rgb, in.color.a * alpha);
}

// Point fragment with glow effect (for Art mode)
fragment float4 fragment_point_glow(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    float2 center = pointCoord - 0.5;
    float dist = length(center) * 2.0;

    // Core
    float core = 1.0 - smoothstep(0.0, 0.4, dist);

    // Glow
    float glow = 1.0 - smoothstep(0.0, 1.0, dist);
    glow = pow(glow, 3.0) * 0.5;

    float alpha = core + glow;

    if (alpha < 0.01) discard_fragment();

    // Brighter center
    float3 color = mix(in.color.rgb, float3(1.0), core * 0.5);

    return float4(color, alpha * in.color.a);
}

// MARK: - Selection Highlight

struct SelectionUniforms {
    float4 highlightColor;
    float pulsePhase;
};

fragment float4 fragment_selected(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant SelectionUniforms &selection [[buffer(2)]]
) {
    float2 center = pointCoord - 0.5;
    float dist = length(center) * 2.0;

    // Pulsing ring for selection
    float ring = smoothstep(0.6, 0.7, dist) * (1.0 - smoothstep(0.9, 1.0, dist));
    float pulse = 0.5 + 0.5 * sin(selection.pulsePhase);

    // Core
    float core = 1.0 - smoothstep(0.0, 0.6, dist);

    float3 color = mix(in.color.rgb, selection.highlightColor.rgb, ring * pulse);
    float alpha = max(core, ring);

    if (alpha < 0.01) discard_fragment();

    return float4(color, alpha);
}
