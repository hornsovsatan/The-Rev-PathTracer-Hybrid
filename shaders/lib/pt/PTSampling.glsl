#ifndef LIGHT_AND_SHADOW_SAMPLING_GLSL
#define LIGHT_AND_SHADOW_SAMPLING_GLSL

// Path tracing random sequences.
uint ptRandomHash(uint value) {
    value ^= value >> 16u;
    value *= 0x7feb352du;
    value ^= value >> 15u;
    value *= 0x846ca68bu;
    return value ^ (value >> 16u);
}

uint ptPixelSeed(ivec2 pixel, int frame, uint dimension) {
    return ptRandomHash(uint(pixel.x) ^ ptRandomHash(uint(pixel.y) + 0x9e3779b9u) ^
        ptRandomHash(uint(frame) + 0x85ebca6bu) ^ ptRandomHash(dimension + 0xc2b2ae35u));
}

float ptRandomFloat(uint seed) {
    // Exactly representable [0,1), with no accumulating float-frame precision loss.
    return float(ptRandomHash(seed) >> 8u) * (1.0 / 16777216.0);
}

vec2 ptRandomPair(ivec2 pixel, int frame, uint dimension) {
    uint seed = ptPixelSeed(pixel, frame, dimension);
    return vec2(ptRandomFloat(seed), ptRandomFloat(seed ^ 0x68bc21ebu));
}

// PBR direction sampling.
// Visible GGX normals, Heitz 2018: https://jcgt.org/published/0007/04/01/
vec3 sampleVisibleGGX(vec2 xi, vec3 normal, vec3 view, float alpha) {
    vec3 axis = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 tangent = normalize(cross(axis, normal));
    vec3 bitangent = cross(normal, tangent);
    vec3 localView = vec3(dot(view, tangent), dot(view, bitangent), dot(view, normal));
    vec3 stretchedView = normalize(vec3(alpha * localView.xy, localView.z));
    float xyLength2 = dot(stretchedView.xy, stretchedView.xy);
    vec3 basisX = xyLength2 > 0.0
        ? vec3(-stretchedView.y, stretchedView.x, 0.0) * inversesqrt(xyLength2)
        : vec3(1.0, 0.0, 0.0);
    vec3 basisY = cross(stretchedView, basisX);
    float radius = sqrt(xi.x);
    float angle = 6.28318530718 * xi.y;
    vec2 disk = radius * vec2(cos(angle), sin(angle));
    float blend = 0.5 * (1.0 + stretchedView.z);
    disk.y = mix(sqrt(max(1.0 - disk.x * disk.x, 0.0)), disk.y, blend);
    vec3 hemisphere = disk.x * basisX + disk.y * basisY +
        sqrt(max(1.0 - dot(disk, disk), 0.0)) * stretchedView;
    vec3 localNormal = normalize(vec3(alpha * hemisphere.xy, max(hemisphere.z, 0.0)));
    return normalize(tangent * localNormal.x + bitangent * localNormal.y + normal * localNormal.z);
}

float visibleGGXWeight(float NoV, float NoL, float alpha) {
    float alpha2 = alpha * alpha;
    float rootV = sqrt(NoV * NoV * (1.0 - alpha2) + alpha2);
    float rootL = sqrt(NoL * NoL * (1.0 - alpha2) + alpha2);
    // G2 / G1(V): the matching BRDF/PDF ratio is bounded by one.
    return NoL * (NoV + rootV) / max(NoL * rootV + NoV * rootL, 1e-8);
}

#endif
