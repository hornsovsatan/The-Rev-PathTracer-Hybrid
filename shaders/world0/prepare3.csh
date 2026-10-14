#version 460 compatibility

#include "/lib/Utility.glsl"

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(1, 1, 1);

#include "/lib/pt/PTBuffers.glsl"

shared float blockSum[256];

void main() {
#ifdef PT_EMISSIVE_NEE
    uint lane  = gl_LocalInvocationID.x;
    uint count = min(diLightCount, diLightCapacity);
    uint start = lane * 64u;
    uint end   = min(start + 64u, count);

    float sum = 0.0;
    for (uint i = start; i < end; ++i) {
        float power = max(diLightProxy[i].w * emissionAreaGain(diLights[i].meta.y), 1e-12);
        diLightProxy[i].w = power;
        sum += power;
        diLightCDF[i] = sum;
    }
    blockSum[lane] = sum;
    barrier();

    if (lane == 0u) {
        float prefix = 0.0;
        for (uint i = 0u; i < 256u; ++i) {
            float v = blockSum[i];
            blockSum[i] = prefix;
            prefix += v;
        }
    }
    barrier();

    for (uint i = start; i < end; ++i) diLightCDF[i] += blockSum[lane];
#endif
}
