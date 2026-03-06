#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Colour space IDs matching Swift ColourSpaceInfo.ID
constant int CS_SRGB      = 0;
constant int CS_DISPLAY_P3 = 1;
constant int CS_REC2020   = 2;

vertex VertexOut videoVertexShader(uint vertexID [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2(-1,  1), float2( 1, -1), float2( 1,  1)
    };
    float2 texCoords[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Simple passthrough (same colour space or no transform needed)
fragment float4 videoFragmentShader(VertexOut in [[stage_in]],
                                    texture2d<float> texture [[texture(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    return texture.sample(texSampler, in.texCoord);
}

// sRGB OETF (linear -> sRGB gamma)
float3 linearToSRGB(float3 linear) {
    float3 lo = linear * 12.92;
    float3 hi = 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
    return mix(lo, hi, step(0.0031308, linear));
}

// sRGB EOTF (sRGB gamma -> linear)
float3 srgbToLinear(float3 srgb) {
    float3 lo = srgb / 12.92;
    float3 hi = pow((srgb + 0.055) / 1.055, 2.4);
    return mix(lo, hi, step(0.04045, srgb));
}

// P3 to sRGB chromatic adaptation (Bradford, D65->D65 so just gamut mapping)
// Uses the 3x3 matrix to convert from Display P3 linear to sRGB linear
float3 p3LinearToSrgbLinear(float3 p3) {
    // Display P3 -> sRGB (both D65 white point)
    float3x3 m = float3x3(
        float3( 1.2249,  -0.2247,  0.0),
        float3(-0.0420,   1.0419,  0.0),
        float3(-0.0197,  -0.0786,  1.0979)
    );
    return m * p3;
}

// sRGB linear to P3 linear
float3 srgbLinearToP3Linear(float3 srgb) {
    float3x3 m = float3x3(
        float3( 0.8225,   0.1774,  0.0),
        float3( 0.0332,   0.9669,  0.0),
        float3( 0.0171,   0.0724,  0.9108)
    );
    return m * srgb;
}

// Colour-managed fragment shader with source/destination colour space transform
struct ColourParams {
    int sourceCS;
    int destCS;
    float edrHeadroom;   // EDR headroom (1.0 = SDR, >1.0 = HDR)
};

fragment float4 videoColourFragmentShader(VertexOut in [[stage_in]],
                                          texture2d<float> texture [[texture(0)]],
                                          constant ColourParams& params [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float4 colour = texture.sample(texSampler, in.texCoord);

    // If source == dest, passthrough
    if (params.sourceCS == params.destCS) {
        return colour;
    }

    // Convert source to linear sRGB as interchange space
    float3 linear;
    if (params.sourceCS == CS_DISPLAY_P3) {
        // P3 encoded with sRGB transfer function -> linear sRGB
        linear = p3LinearToSrgbLinear(srgbToLinear(colour.rgb));
    } else if (params.sourceCS == CS_REC2020) {
        // For Rec.2020, approximate with sRGB EOTF (simplified)
        linear = srgbToLinear(colour.rgb);
    } else {
        // sRGB
        linear = srgbToLinear(colour.rgb);
    }

    // Convert linear sRGB to destination
    float3 output;
    if (params.destCS == CS_DISPLAY_P3) {
        output = linearToSRGB(srgbLinearToP3Linear(linear));
    } else if (params.destCS == CS_REC2020) {
        output = linearToSRGB(linear); // simplified
    } else {
        output = linearToSRGB(linear);
    }

    // Apply EDR headroom scaling for HDR displays
    if (params.edrHeadroom > 1.0) {
        output *= params.edrHeadroom;
    }

    return float4(output, colour.a);
}
