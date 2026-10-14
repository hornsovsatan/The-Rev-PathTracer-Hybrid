#if !defined INCLUDE_PT_BUFFERS
#define INCLUDE_PT_BUFFERS

// ===== Ukuran volume voxel (lihat Bagian 9 sebelum mengubah) =====
#define TRACE_SIZE_X 128
#define TRACE_SIZE_Y 128
#define TRACE_SIZE_Z 128
#define TRACE_VOXEL_COUNT (TRACE_SIZE_X * TRACE_SIZE_Y * TRACE_SIZE_Z)
#define TRACE_END 0x00ffffffu

const uint DI_INVALID         = 0xffffffffu;
const uint diLightCapacity    = 16384u;
const uint pointLightCapacity = 256u;
const uint  emissionAreaCellCount = uint(TRACE_VOXEL_COUNT);
const float emissionAreaUnits     = 65536.0;

struct TraceTextureKey { uint hash; uint bounds; };
struct DILight { vec4 p0; vec4 e1; vec4 e2; uvec4 data; uvec4 meta; };

// binding 3: counter + point light (dulu SSPT binding 0 dan 5)
layout(std430, binding = 3) buffer PTCounterBuffer {
    uint traceTriangleCount;
    uint traceReservedCounter;
    uint pointLightCount;
    uint pointLightReserved0;
    vec4 pointLights[256];
};
// binding 4: primitive slots
layout(std430, binding = 4) buffer TraceTriangleBuffer { uvec4 tracePrimitiveSlots[]; };
// binding 5: kepala linked-list per voxel
layout(std430, binding = 5) buffer TraceHeadBuffer { uint traceHead[]; };
// binding 6: area emisi
layout(std430, binding = 6) buffer EmissionAreaBuffer {
    uint emissionBlockArea[TRACE_VOXEL_COUNT];
    uint emissionBlockShape[TRACE_VOXEL_COUNT];
    uint emissionPrimitiveOwner[];
};
// binding 7: salinan tekstur
layout(std430, binding = 7) buffer TraceTextureBuffer {
    uint traceTextureLast;
    uint traceTextureReserved;
    TraceTextureKey traceTextureKeys[16];
    uint traceTextureData[];
};
// binding 8: DI lights + primitive->light map (dulu SSPT binding 6 dan 7)
layout(std430, binding = 8) buffer DILightBuffer {
    uint diLightCount;
    uint diPadding0, diPadding1, diPadding2;
    DILight diLights[16384];
    uint diLightLookup[32768];
    vec4 diLightProxy[16384];
    float diLightCDF[16384];
    uint diPrimitiveLight[];
};

float emissionAreaGain(uint owner) {
    if (owner >= emissionAreaCellCount) return 1.0;
    if (emissionBlockShape[owner] == 1u) return 1.0;
    uint area = emissionBlockArea[owner];
    if (area == 0u) return 1.0;
    return 6.0 * emissionAreaUnits / float(area);
}

vec3 srgbToLinear(vec3 v) {
    v = max(v, vec3(0.0));
    return mix(v / 12.92, pow((v + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), v));
}

#endif
