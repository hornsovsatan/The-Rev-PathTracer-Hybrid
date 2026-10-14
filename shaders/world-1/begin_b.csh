#version 460 compatibility
layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(8192, 1, 1); // = TRACE_VOXEL_COUNT / 256 untuk volume 128^3
uniform int frameCounter;
#include "/lib/pt/PTBuffers.glsl"

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id == 0u) {
        traceTriangleCount = 0u; traceReservedCounter = 0u;
        pointLightCount = 0u; diLightCount = 0u;
        if (frameCounter <= 1) { traceTextureLast = 0u; traceTextureReserved = 0u; }
    }
    if (id < 32768u) diLightLookup[id] = DI_INVALID;
    if (id < uint(TRACE_VOXEL_COUNT)) {
        traceHead[id] = TRACE_END;
        emissionBlockArea[id] = 0u;
        emissionBlockShape[id] = 0u;
    }
    if (frameCounter <= 1 && id < 16u) {
        traceTextureKeys[id].hash = 0u;
        traceTextureKeys[id].bounds = 0u;
    }
}
