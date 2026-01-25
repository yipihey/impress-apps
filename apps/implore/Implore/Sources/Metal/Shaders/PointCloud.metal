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

// MARK: - Additional Colormaps

// Plasma colormap
float4 plasma(float t) {
    t = saturate(t);

    float3 c0 = float3(0.050383, 0.029803, 0.527975);
    float3 c1 = float3(0.274191, 0.017055, 0.609861);
    float3 c2 = float3(0.494877, 0.011607, 0.657865);
    float3 c3 = float3(0.665129, 0.138182, 0.614178);
    float3 c4 = float3(0.798216, 0.280197, 0.469538);
    float3 c5 = float3(0.898581, 0.396782, 0.303763);
    float3 c6 = float3(0.973416, 0.558148, 0.153808);
    float3 c7 = float3(0.992440, 0.748340, 0.158970);
    float3 c8 = float3(0.940015, 0.975158, 0.131326);

    float3 color;
    if (t < 0.125) color = mix(c0, c1, t * 8.0);
    else if (t < 0.25) color = mix(c1, c2, (t - 0.125) * 8.0);
    else if (t < 0.375) color = mix(c2, c3, (t - 0.25) * 8.0);
    else if (t < 0.5) color = mix(c3, c4, (t - 0.375) * 8.0);
    else if (t < 0.625) color = mix(c4, c5, (t - 0.5) * 8.0);
    else if (t < 0.75) color = mix(c5, c6, (t - 0.625) * 8.0);
    else if (t < 0.875) color = mix(c6, c7, (t - 0.75) * 8.0);
    else color = mix(c7, c8, (t - 0.875) * 8.0);

    return float4(color, 1.0);
}

// Inferno colormap
float4 inferno(float t) {
    t = saturate(t);

    float3 c0 = float3(0.001462, 0.000466, 0.013866);
    float3 c1 = float3(0.132572, 0.047205, 0.262891);
    float3 c2 = float3(0.341500, 0.062325, 0.429425);
    float3 c3 = float3(0.550287, 0.161158, 0.505719);
    float3 c4 = float3(0.735683, 0.215906, 0.329894);
    float3 c5 = float3(0.878443, 0.391714, 0.102217);
    float3 c6 = float3(0.978422, 0.557937, 0.034931);
    float3 c7 = float3(0.992440, 0.772303, 0.247105);
    float3 c8 = float3(0.988362, 0.998364, 0.644924);

    float3 color;
    if (t < 0.125) color = mix(c0, c1, t * 8.0);
    else if (t < 0.25) color = mix(c1, c2, (t - 0.125) * 8.0);
    else if (t < 0.375) color = mix(c2, c3, (t - 0.25) * 8.0);
    else if (t < 0.5) color = mix(c3, c4, (t - 0.375) * 8.0);
    else if (t < 0.625) color = mix(c4, c5, (t - 0.5) * 8.0);
    else if (t < 0.75) color = mix(c5, c6, (t - 0.625) * 8.0);
    else if (t < 0.875) color = mix(c6, c7, (t - 0.75) * 8.0);
    else color = mix(c7, c8, (t - 0.875) * 8.0);

    return float4(color, 1.0);
}

// Magma colormap
float4 magma(float t) {
    t = saturate(t);

    float3 c0 = float3(0.001462, 0.000466, 0.013866);
    float3 c1 = float3(0.116387, 0.042226, 0.231919);
    float3 c2 = float3(0.270596, 0.050680, 0.403716);
    float3 c3 = float3(0.461840, 0.098304, 0.495251);
    float3 c4 = float3(0.665129, 0.176000, 0.514782);
    float3 c5 = float3(0.843884, 0.295413, 0.460928);
    float3 c6 = float3(0.961891, 0.506530, 0.453735);
    float3 c7 = float3(0.992440, 0.737758, 0.600227);
    float3 c8 = float3(0.987053, 0.991438, 0.749504);

    float3 color;
    if (t < 0.125) color = mix(c0, c1, t * 8.0);
    else if (t < 0.25) color = mix(c1, c2, (t - 0.125) * 8.0);
    else if (t < 0.375) color = mix(c2, c3, (t - 0.25) * 8.0);
    else if (t < 0.5) color = mix(c3, c4, (t - 0.375) * 8.0);
    else if (t < 0.625) color = mix(c4, c5, (t - 0.5) * 8.0);
    else if (t < 0.75) color = mix(c5, c6, (t - 0.625) * 8.0);
    else if (t < 0.875) color = mix(c6, c7, (t - 0.75) * 8.0);
    else color = mix(c7, c8, (t - 0.875) * 8.0);

    return float4(color, 1.0);
}

// Coolwarm diverging colormap
float4 coolwarm(float t) {
    t = saturate(t);

    float3 c0 = float3(0.230, 0.299, 0.754);  // Cool blue
    float3 c1 = float3(0.552, 0.691, 0.996);
    float3 c2 = float3(0.865, 0.865, 0.865);  // Neutral
    float3 c3 = float3(0.957, 0.647, 0.510);
    float3 c4 = float3(0.706, 0.016, 0.150);  // Warm red

    float3 color;
    if (t < 0.25) color = mix(c0, c1, t * 4.0);
    else if (t < 0.5) color = mix(c1, c2, (t - 0.25) * 4.0);
    else if (t < 0.75) color = mix(c2, c3, (t - 0.5) * 4.0);
    else color = mix(c3, c4, (t - 0.75) * 4.0);

    return float4(color, 1.0);
}

// MARK: - Wireframe Box Rendering

struct LineVertex {
    float3 position [[attribute(0)]];
    float4 color [[attribute(1)]];
};

struct LineVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex LineVertexOut vertex_wireframe(
    LineVertex in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    LineVertexOut out;
    out.position = uniforms.modelViewProjection * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 fragment_line(
    LineVertexOut in [[stage_in]]
) {
    return in.color;
}

// MARK: - Grid Rendering

vertex LineVertexOut vertex_grid(
    LineVertex in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    LineVertexOut out;
    out.position = uniforms.modelViewProjection * float4(in.position, 1.0);

    // Fade based on distance from camera
    float4 viewPos = uniforms.modelView * float4(in.position, 1.0);
    float fade = saturate(1.0 - (-viewPos.z / 50.0));
    out.color = float4(in.color.rgb, in.color.a * fade);

    return out;
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

// MARK: - ECDF Marginal Rendering

struct ECDFVertex {
    float2 position [[attribute(0)]];
    float value [[attribute(1)]];  // ECDF value 0-1
};

struct ECDFVertexOut {
    float4 position [[position]];
    float value;
};

struct ECDFUniforms {
    float2 origin;      // Panel origin in NDC
    float2 size;        // Panel size in NDC
    float4 lineColor;
    float4 fillColor;
    float lineWidth;
};

// ECDF as step function
vertex ECDFVertexOut vertex_ecdf(
    ECDFVertex in [[stage_in]],
    constant ECDFUniforms &ecdf [[buffer(1)]]
) {
    ECDFVertexOut out;

    // Map data position to panel coordinates
    float2 pos = ecdf.origin + in.position * ecdf.size;
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);  // NDC
    out.value = in.value;

    return out;
}

fragment float4 fragment_ecdf_line(
    ECDFVertexOut in [[stage_in]],
    constant ECDFUniforms &ecdf [[buffer(1)]]
) {
    return ecdf.lineColor;
}

fragment float4 fragment_ecdf_fill(
    ECDFVertexOut in [[stage_in]],
    constant ECDFUniforms &ecdf [[buffer(1)]]
) {
    return float4(ecdf.fillColor.rgb, ecdf.fillColor.a * 0.3);
}

// MARK: - Axis Rendering

struct AxisVertex {
    float2 position [[attribute(0)]];
};

struct AxisVertexOut {
    float4 position [[position]];
};

struct AxisUniforms {
    float4 color;
    float2 offset;  // Offset in NDC
};

vertex AxisVertexOut vertex_axis(
    AxisVertex in [[stage_in]],
    constant AxisUniforms &axis [[buffer(1)]]
) {
    AxisVertexOut out;
    float2 pos = in.position + axis.offset;
    out.position = float4(pos, 0.0, 1.0);
    return out;
}

fragment float4 fragment_axis(
    AxisVertexOut in [[stage_in]],
    constant AxisUniforms &axis [[buffer(1)]]
) {
    return axis.color;
}

// MARK: - Post-Processing (Bloom)

struct QuadVertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct QuadVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex QuadVertexOut vertex_fullscreen_quad(
    QuadVertex in [[stage_in]]
) {
    QuadVertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

struct BloomUniforms {
    float intensity;
    float threshold;
    float2 texelSize;
};

// Extract bright areas
fragment float4 fragment_bloom_threshold(
    QuadVertexOut in [[stage_in]],
    texture2d<float> inputTexture [[texture(0)]],
    constant BloomUniforms &bloom [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = inputTexture.sample(textureSampler, in.texCoord);

    float luminance = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float brightness = max(0.0, luminance - bloom.threshold);

    return float4(color.rgb * brightness, 1.0);
}

// Gaussian blur (horizontal or vertical based on texelSize)
fragment float4 fragment_bloom_blur(
    QuadVertexOut in [[stage_in]],
    texture2d<float> inputTexture [[texture(0)]],
    constant BloomUniforms &bloom [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    // 9-tap Gaussian blur
    float weights[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};

    float4 result = inputTexture.sample(textureSampler, in.texCoord) * weights[0];

    for (int i = 1; i < 5; i++) {
        float2 offset = bloom.texelSize * float(i);
        result += inputTexture.sample(textureSampler, in.texCoord + offset) * weights[i];
        result += inputTexture.sample(textureSampler, in.texCoord - offset) * weights[i];
    }

    return result;
}

// Combine original with bloom
fragment float4 fragment_bloom_combine(
    QuadVertexOut in [[stage_in]],
    texture2d<float> sceneTexture [[texture(0)]],
    texture2d<float> bloomTexture [[texture(1)]],
    constant BloomUniforms &bloom [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    float4 scene = sceneTexture.sample(textureSampler, in.texCoord);
    float4 bloomColor = bloomTexture.sample(textureSampler, in.texCoord);

    return scene + bloomColor * bloom.intensity;
}
