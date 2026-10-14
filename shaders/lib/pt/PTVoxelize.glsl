#define TRACE_PRIMITIVE_SLOT_MAX 4194304u
#define TRACE_PRIMITIVE_SLOT_MASK 0x003fffffu
#define TRACE_PRIMITIVE_COMPACT_FACE_BIT 0x00800000u
#define TRACE_MAX_VOXELS_PER_TRIANGLE 256     // dari 32
#define TRACE_DROP_LARGE_TRIANGLES 0          // dari 1: segitiga besar tidak dibuang
#define TRACE_REJECT_LARGE_CLOUDLIKE_TRIANGLES 1
#define TRACE_MAX_TRIANGLE_EDGE_LENGTH 16.0   // dari 4.0
#define TRACE_MAX_TRIANGLE_AABB_SPAN 16.0
#define TRACE_TEXTURE_KEY_COUNT 16u
#define TRACE_TEXTURE_INDEX_ATLAS 4095u
#define TRACE_TEXTURE_INDEX_MASK 0x00000fffu
#define TRACE_TINT_SHIFT 12u
#define TRACE_EMISSION_SHIFT 28u
#define TRACE_EMISSION_MASK 0x0000000fu
#define TRACE_TEXTURE_SLOT_SIDE 1024u
#define TRACE_TEXTURE_SLOT_TEXELS 1048576u
#define TRACE_TEXTURE_INDEX_NONE 4094u
const ivec3 traceVoxelSize = ivec3(TRACE_SIZE_X, TRACE_SIZE_Y, TRACE_SIZE_Z);
const ivec3 traceVoxelHalf = ivec3(TRACE_SIZE_X / 2, TRACE_SIZE_Y / 2, TRACE_SIZE_Z / 2);
#include "/lib/pt/PTSampling.glsl"
uint currentDILight = DI_INVALID;
uint currentEmissionOwner = 0xffffffffu;
uint flattenTraceVoxel(ivec3 voxel) {
    return uint(voxel.x + voxel.y * TRACE_SIZE_X + voxel.z * TRACE_SIZE_X * TRACE_SIZE_Y);
}
bool traceVoxelInside(ivec3 voxel) {
    return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, traceVoxelSize));
}
ivec2 voxelRangeAxis(float mn, float mx, int halfCoord) {
    const float eps = 1e-4;
    float h = float(halfCoord);
    float extent = mx - mn;
    if (extent < 1e-4) {
        int base = int(floor(mn + h + 1e-6));
        return ivec2(base - 1, base);
    }
    int a = int(floor(mn + h + eps));
    int b = int(ceil(mx + h - eps)) - 1;
    if (b < a) b = a;
    return ivec2(a, b);
}
bool traceTrianglePreCull(vec3 p0, vec3 p1, vec3 p2) {
    vec3 e1 = p1 - p0;
    vec3 e2 = p2 - p0;
#if TRACE_REJECT_LARGE_CLOUDLIKE_TRIANGLES == 1
    float maxEdgeLen2 = max(dot(e1, e1), max(dot(e2, e2), dot(p2 - p1, p2 - p1)));
    float maxEdgeLimit2 = TRACE_MAX_TRIANGLE_EDGE_LENGTH * TRACE_MAX_TRIANGLE_EDGE_LENGTH;
    vec3 rawSpan = max(max(p0, p1), p2) - min(min(p0, p1), p2);
    float maxSpan = max(max(rawSpan.x, rawSpan.y), rawSpan.z);
    if (maxEdgeLen2 > maxEdgeLimit2 || maxSpan > TRACE_MAX_TRIANGLE_AABB_SPAN) return false;
#endif
    vec3 n = cross(e1, e2);
    if (dot(n, n) < 1e-10) return false;
    vec3 triMin = min(min(p0, p1), p2);
    vec3 triMax = max(max(p0, p1), p2);
    vec3 volumeMin = -vec3(traceVoxelHalf);
    vec3 volumeMax =  vec3(traceVoxelHalf);
    if (any(lessThan(triMax, volumeMin)) || any(greaterThanEqual(triMin, volumeMax))) return false;
    ivec2 rx = voxelRangeAxis(triMin.x, triMax.x, traceVoxelHalf.x);
    ivec2 ry = voxelRangeAxis(triMin.y, triMax.y, traceVoxelHalf.y);
    ivec2 rz = voxelRangeAxis(triMin.z, triMax.z, traceVoxelHalf.z);
    ivec3 voxelMin = clamp(ivec3(rx.x, ry.x, rz.x), ivec3(0), traceVoxelSize - ivec3(1));
    ivec3 voxelMax = clamp(ivec3(rx.y, ry.y, rz.y), ivec3(0), traceVoxelSize - ivec3(1));
    ivec3 span = voxelMax - voxelMin + ivec3(1);
    int voxelCount = span.x * span.y * span.z;
#if TRACE_DROP_LARGE_TRIANGLES == 1
    if (voxelCount <= 0 || voxelCount > TRACE_MAX_VOXELS_PER_TRIANGLE) return false;
#else
    if (voxelCount <= 0) return false;
#endif
    return true;
}
uint packTint565(vec3 color) {
    uvec3 c = uvec3(clamp(color, 0.0, 1.0) * vec3(31.0, 63.0, 31.0) + vec3(0.5));
    return (c.r & 31u) | ((c.g & 63u) << 5u) | ((c.b & 31u) << 11u);
}
uint packTraceTextureTintAndEmission(uint textureIndex, vec3 tint, float emission) {
    uint packedEmission = uint(clamp(emission, 0.0, 1.0) * 15.0 + 0.5);
    return (textureIndex & TRACE_TEXTURE_INDEX_MASK)
        | (packTint565(tint) << TRACE_TINT_SHIFT)
        | ((packedEmission & TRACE_EMISSION_MASK) << TRACE_EMISSION_SHIFT);
}
uint traceStableTextureKey() {
    uint h = uint(max(gtextureId, 0)) + 1u;
    h *= 0x9e3779b9u;
    h ^= h >> 16u;
    h *= 0x7feb352du;
    h ^= h >> 15u;
    return h | 1u;
}
uvec2 traceTextureStorageSize(uvec2 sourceSize) {
    uint sourceMax = max(sourceSize.x, sourceSize.y);
    if (sourceMax <= TRACE_TEXTURE_SLOT_SIDE) return max(sourceSize, uvec2(1u));
    return max(
        (sourceSize * TRACE_TEXTURE_SLOT_SIDE + sourceMax - 1u) / sourceMax,
        uvec2(1u)
    );
}
uint traceTextureSourceLod(uvec2 sourceSize, uvec2 storageSize) {
    float ratio = float(max(sourceSize.x, sourceSize.y))
        / float(max(storageSize.x, storageSize.y));
    return uint(max(ceil(log2(max(ratio, 1.0))), 0.0));
}
bool addTraceTexture(
    uint key,
    uvec2 sourceSize,
    out uint textureIndex,
    out uint texOffset,
    out uint stride,
    out uvec2 storageSize,
    out uint sourceLod
) {
    storageSize = traceTextureStorageSize(sourceSize);
    sourceLod = traceTextureSourceLod(sourceSize, storageSize);
    for (uint attempt = 0u; attempt < TRACE_TEXTURE_KEY_COUNT; attempt++) {
        uint index = (key + ((attempt * attempt + attempt) >> 1u))
            & (TRACE_TEXTURE_KEY_COUNT - 1u);
        uint previous = atomicCompSwap(traceTextureKeys[index].hash, 0u, key);
        if (previous != 0u && previous != key) continue;

        textureIndex = index;
        texOffset = index * TRACE_TEXTURE_SLOT_TEXELS;
        stride = storageSize.x;
        if (previous == 0u) {
            traceTextureKeys[index].bounds = storageSize.x | (storageSize.y << 16u);
            memoryBarrierBuffer();
            return true;
        }

        uint bounds = traceTextureKeys[index].bounds;
        for (int spin = 0; spin < 32 && bounds == 0u; spin++) {
            memoryBarrierBuffer();
            bounds = traceTextureKeys[index].bounds;
        }
        if (bounds != 0u) {
            storageSize = uvec2(bounds & 0xffffu, bounds >> 16u);
            stride = max(storageSize.x, 1u);
        }
        return false;
    }
    textureIndex = TRACE_TEXTURE_INDEX_NONE;
    texOffset = 0u;
    stride = 1u;
    storageSize = uvec2(1u);
    sourceLod = 0u;
    return false;
}
uint packTraceUV(vec2 uv, uint textureIndex) {
    if (textureIndex == TRACE_TEXTURE_INDEX_ATLAS) {
        return packUnorm2x16(clamp(uv, vec2(0.0), vec2(1.0)));
    }
    return packHalf2x16(uv);
}
void setTraceTriangleNext(
    inout uvec4 p0Data,
    inout uvec4 e1Data,
    inout uvec4 e2Data,
    uint nextRef
) {
    uint nextValue = nextRef & 0x00ffffffu;
    p0Data.x = (p0Data.x & 0xfffffff8u) | ((nextValue >> 0u) & 7u);
    p0Data.y = (p0Data.y & 0xfffffff8u) | ((nextValue >> 3u) & 7u);
    p0Data.z = (p0Data.z & 0xfffffff8u) | ((nextValue >> 6u) & 7u);
    e1Data.x = (e1Data.x & 0xfffffff8u) | ((nextValue >> 9u) & 7u);
    e1Data.y = (e1Data.y & 0xfffffff8u) | ((nextValue >> 12u) & 7u);
    e1Data.z = (e1Data.z & 0xfffffff8u) | ((nextValue >> 15u) & 7u);
    e2Data.x = (e2Data.x & 0xfffffff8u) | ((nextValue >> 18u) & 7u);
    e2Data.y = (e2Data.y & 0xfffffff8u) | ((nextValue >> 21u) & 7u);
}
bool appendTraceTriangleToVoxel(
    ivec3 voxel,
    vec3 p0,
    vec3 p1,
    vec3 p2,
    vec2 uv0,
    vec2 uv1,
    vec2 uv2,
    vec3 tint,
    vec4 skyLight,
    float emission,
    uint textureIndex
) {
    if (!traceVoxelInside(voxel)) return false;
    uint slotIndex = atomicAdd(traceTriangleCount, 4u);
    if (slotIndex > TRACE_PRIMITIVE_SLOT_MAX - 4u) return false;
    emissionPrimitiveOwner[slotIndex] = currentEmissionOwner;
    diPrimitiveLight[slotIndex] = currentDILight;
    uint nodeRef = slotIndex;
    uint previousRef = atomicExchange(traceHead[flattenTraceVoxel(voxel)], nodeRef);
    uvec4 p0Data = floatBitsToUint(vec4(p0, skyLight.r));
    // Both sky payload fields store accessibility.
    p0Data.w = packHalf2x16(skyLight.ra);
    uvec4 e1Data = floatBitsToUint(vec4(p1 - p0, skyLight.g));
    uvec4 e2Data = floatBitsToUint(vec4(p2 - p0, skyLight.b));
    setTraceTriangleNext(p0Data, e1Data, e2Data, previousRef);
    tracePrimitiveSlots[slotIndex + 0u] = p0Data;
    tracePrimitiveSlots[slotIndex + 1u] = e1Data;
    tracePrimitiveSlots[slotIndex + 2u] = e2Data;
    tracePrimitiveSlots[slotIndex + 3u] = uvec4(
        packTraceUV(uv0, textureIndex),
        packTraceUV(uv1, textureIndex),
        packTraceUV(uv2, textureIndex),
        packTraceTextureTintAndEmission(textureIndex, tint, emission)
    );
    return true;
}
uint packTraceCompactSkyLight(vec3 skyLight) {
    uvec3 value = uvec3(clamp(skyLight, 0.0, 1.0) * 1023.0 + 0.5);
    return value.r | (value.g << 10u) | (value.b << 20u);
}
uint packTraceCompactSurface(vec3 tint, float emission, uint orientation) {
    uint packedEmission = uint(clamp(emission, 0.0, 1.0) * 15.0 + 0.5);
    return packTint565(tint)
        | ((packedEmission & 15u) << 16u)
        // Low 3 bits encode UV orientation, the next 5 encode log2(tile size).
        | ((orientation & 255u) << 20u);
}
bool packTraceAtlasTile(
    vec2 uvOrigin,
    vec2 uvAxisA,
    vec2 uvAxisB,
    out uint atlasData,
    out uint orientation
) {
    vec2 atlasSize = vec2(max(textureSize(gtexture, 0), ivec2(1)));
    vec2 originPixel = uvOrigin * atlasSize;
    vec2 axisAPixel = uvAxisA * atlasSize;
    vec2 axisBPixel = uvAxisB * atlasSize;
    bool axisAAlongU = abs(axisAPixel.x) > abs(axisAPixel.y);
    float axisAValue = axisAAlongU ? axisAPixel.x : axisAPixel.y;
    float axisBValue = axisAAlongU ? axisBPixel.y : axisBPixel.x;
    float axisAOff = axisAAlongU ? axisAPixel.y : axisAPixel.x;
    float axisBOff = axisAAlongU ? axisBPixel.x : axisBPixel.y;
    if (abs(axisAOff) > 0.05 || abs(axisBOff) > 0.05) return false;
    uint tileSize = uint(round(0.5 * (abs(axisAValue) + abs(axisBValue))));
    if (tileSize == 0u || (tileSize & (tileSize - 1u)) != 0u) return false;
    if (max(abs(abs(axisAValue) - float(tileSize)),
            abs(abs(axisBValue) - float(tileSize))) > 0.05) return false;
    int tileLevel = findMSB(tileSize);
    if (tileLevel < 0 || tileLevel > 31) return false;

    vec2 cornerA = originPixel + axisAPixel;
    vec2 cornerB = originPixel + axisBPixel;
    vec2 cornerAB = cornerA + axisBPixel;
    vec2 tileBase = min(min(originPixel, cornerA), min(cornerB, cornerAB));
    if (any(lessThan(tileBase, vec2(-0.05)))
        || any(greaterThan(tileBase + float(tileSize), atlasSize + vec2(0.05)))) {
        return false;
    }
    // Store exact sprite origins; unsupported origins use ordinary triangles.
    vec2 roundedBase = round(tileBase);
    if (any(greaterThan(abs(tileBase - roundedBase), vec2(0.05))) ||
        any(lessThan(roundedBase, vec2(0.0))) ||
        any(greaterThan(roundedBase, vec2(65535.0)))) return false;
    uvec2 tileOffset = uvec2(roundedBase);
    atlasData = (tileOffset.x & 65535u) | ((tileOffset.y & 65535u) << 16u);
    orientation = uint(axisAAlongU)
        | (uint(axisAValue > 0.0) << 1u)
        | (uint(axisBValue > 0.0) << 2u)
        | (uint(tileLevel) << 3u);
    return true;
}
bool appendTraceCompactFaceToVoxel(
    ivec3 voxel,
    int axis,
    int facePlane,
    uint atlasData,
    uint orientation,
    vec3 tint,
    vec4 skyLight,
    float emission
) {
    if (!traceVoxelInside(voxel)) return false;
    ivec3 cellMin = voxel - traceVoxelHalf;
    int planeSide = facePlane - cellMin[axis];
    if (planeSide < 0 || planeSide > 1) return false;
    uint slotIndex = atomicAdd(traceTriangleCount, 1u);
    if (slotIndex >= TRACE_PRIMITIVE_SLOT_MAX) return false;
    emissionPrimitiveOwner[slotIndex] = currentEmissionOwner;
    diPrimitiveLight[slotIndex] = currentDILight;
    uint nodeRef = TRACE_PRIMITIVE_COMPACT_FACE_BIT | slotIndex;
    uint previousRef = atomicExchange(traceHead[flattenTraceVoxel(voxel)], nodeRef);
    tracePrimitiveSlots[slotIndex] = uvec4(
        atlasData,
        (previousRef & 0x00ffffffu)
            | ((uint(axis) & 3u) << 24u)
            | ((uint(planeSide) & 1u) << 26u),
        packTraceCompactSurface(tint, emission, orientation)
            | (uint(clamp(skyLight.a, 0.0, 1.0) * 15.0 + 0.5) << 28u),
        packTraceCompactSkyLight(skyLight.rgb)
    );
    return true;
}
int traceFaceTangentAxisA(int axis) {
    return axis == 0 ? 1 : 0;
}
int traceFaceTangentAxisB(int axis) {
    return axis == 2 ? 1 : 2;
}
bool voxelizeTraceCompactUnitFace(
    vec3 p0,
    vec3 p1,
    vec3 p2,
    vec3 p3,
    vec2 uv0,
    vec2 uv1,
    vec2 uv2,
    vec2 uv3,
    vec3 tint,
    vec4 skyLight,
    float emission,
    uint textureIndex
) {
    // Compact faces currently use direct block-atlas UVs.  Entity textures and
    // unusual texture sources retain the full triangle representation.
    if (textureIndex != TRACE_TEXTURE_INDEX_ATLAS) return false;
    vec3 positions[4] = vec3[4](p0, p1, p2, p3);
    vec2 uvs[4] = vec2[4](uv0, uv1, uv2, uv3);
    vec3 faceMin = min(min(p0, p1), min(p2, p3));
    vec3 faceMax = max(max(p0, p1), max(p2, p3));
    vec3 extent = faceMax - faceMin;
    bvec3 flatAxis = lessThan(abs(extent), vec3(0.002));
    int flatCount = int(flatAxis.x) + int(flatAxis.y) + int(flatAxis.z);
    if (flatCount != 1) return false;
    int axis = flatAxis.x ? 0 : (flatAxis.y ? 1 : 2);
    int axisA = traceFaceTangentAxisA(axis);
    int axisB = traceFaceTangentAxisB(axis);
    if (abs(extent[axisA] - 1.0) > 0.002 ||
        abs(extent[axisB] - 1.0) > 0.002) return false;
    vec3 roundedMin = round(faceMin);
    vec3 roundedMax = round(faceMax);
    if (any(greaterThan(abs(faceMin - roundedMin), vec3(0.002))) ||
        any(greaterThan(abs(faceMax - roundedMax), vec3(0.002)))) return false;

    vec2 uvOrigin = vec2(0.0);
    vec2 uvEndA = vec2(0.0);
    vec2 uvEndB = vec2(0.0);
    bool foundOrigin = false;
    bool foundA = false;
    bool foundB = false;
    for (int i = 0; i < 4; i++) {
        float a = positions[i][axisA] - faceMin[axisA];
        float b = positions[i][axisB] - faceMin[axisB];
        if (a < 0.5 && b < 0.5) {
            uvOrigin = uvs[i];
            foundOrigin = true;
        } else if (a > 0.5 && b < 0.5) {
            uvEndA = uvs[i];
            foundA = true;
        } else if (a < 0.5 && b > 0.5) {
            uvEndB = uvs[i];
            foundB = true;
        }
    }
    if (!foundOrigin || !foundA || !foundB) return false;

    uint atlasData;
    uint orientation;
    if (!packTraceAtlasTile(
        uvOrigin, uvEndA - uvOrigin, uvEndB - uvOrigin,
        atlasData, orientation
    )) return false;
    int facePlane = int(roundedMin[axis]);

    // Index the same integer-snapped geometry used by compact-face decoding.
    ivec2 rx = voxelRangeAxis(roundedMin.x, roundedMax.x, traceVoxelHalf.x);
    ivec2 ry = voxelRangeAxis(roundedMin.y, roundedMax.y, traceVoxelHalf.y);
    ivec2 rz = voxelRangeAxis(roundedMin.z, roundedMax.z, traceVoxelHalf.z);
    ivec3 voxelMin = clamp(
        ivec3(rx.x, ry.x, rz.x), ivec3(0), traceVoxelSize - ivec3(1)
    );
    ivec3 voxelMax = clamp(
        ivec3(rx.y, ry.y, rz.y), ivec3(0), traceVoxelSize - ivec3(1)
    );
    for (int x = voxelMin.x; x <= voxelMax.x; x++) {
        for (int y = voxelMin.y; y <= voxelMax.y; y++) {
            for (int z = voxelMin.z; z <= voxelMax.z; z++) {
                appendTraceCompactFaceToVoxel(
                    ivec3(x, y, z), axis, facePlane,
                    atlasData, orientation, tint, skyLight, emission
                );
            }
        }
    }
    return true;
}
void voxelizeTraceTriangle(
    vec3 p0,
    vec3 p1,
    vec3 p2,
    vec2 uv0,
    vec2 uv1,
    vec2 uv2,
    vec3 tint,
    vec4 skyLight,
    float emission,
    uint textureIndex
) {
    vec3 e1 = p1 - p0;
    vec3 e2 = p2 - p0;
#if TRACE_REJECT_LARGE_CLOUDLIKE_TRIANGLES == 1
    float maxEdgeLen2 = max(dot(e1, e1), max(dot(e2, e2), dot(p2 - p1, p2 - p1)));
    float maxEdgeLimit2 = TRACE_MAX_TRIANGLE_EDGE_LENGTH * TRACE_MAX_TRIANGLE_EDGE_LENGTH;
    vec3 rawSpan = max(max(p0, p1), p2) - min(min(p0, p1), p2);
    float maxSpan = max(max(rawSpan.x, rawSpan.y), rawSpan.z);
    if (maxEdgeLen2 > maxEdgeLimit2 || maxSpan > TRACE_MAX_TRIANGLE_AABB_SPAN) return;
#endif
    vec3 n = cross(e1, e2);
    float area2 = dot(n, n);
    if (area2 < 1e-10) return;
    vec3 normal = normalize(n);
    vec3 triMin = min(min(p0, p1), p2);
    vec3 triMax = max(max(p0, p1), p2);
    vec3 volumeMin = -vec3(traceVoxelHalf);
    vec3 volumeMax =  vec3(traceVoxelHalf);
    if (any(lessThan(triMax, volumeMin)) || any(greaterThanEqual(triMin, volumeMax))) return;
    ivec2 rx = voxelRangeAxis(triMin.x, triMax.x, traceVoxelHalf.x);
    ivec2 ry = voxelRangeAxis(triMin.y, triMax.y, traceVoxelHalf.y);
    ivec2 rz = voxelRangeAxis(triMin.z, triMax.z, traceVoxelHalf.z);
    ivec3 voxelMin = ivec3(rx.x, ry.x, rz.x);
    ivec3 voxelMax = ivec3(rx.y, ry.y, rz.y);
    voxelMin = clamp(voxelMin, ivec3(0), traceVoxelSize - ivec3(1));
    voxelMax = clamp(voxelMax, ivec3(0), traceVoxelSize - ivec3(1));
    ivec3 span = voxelMax - voxelMin + ivec3(1);
    int voxelCount = span.x * span.y * span.z;
#if TRACE_DROP_LARGE_TRIANGLES == 1
    if (voxelCount <= 0 || voxelCount > TRACE_MAX_VOXELS_PER_TRIANGLE) return;
#else
    if (voxelCount <= 0) return;
#endif
    float planeThreshold = dot(abs(normal), vec3(0.5)) + 0.001;
    int inserted = 0;
    for (int x = voxelMin.x; x <= voxelMax.x; x++) {
        for (int y = voxelMin.y; y <= voxelMax.y; y++) {
            for (int z = voxelMin.z; z <= voxelMax.z; z++) {
                if (inserted >= TRACE_MAX_VOXELS_PER_TRIANGLE) return;
                ivec3 voxel = ivec3(x, y, z);
                vec3 voxelCenter = vec3(voxel - traceVoxelHalf) + vec3(0.5);
                float planeDist = abs(dot(normal, voxelCenter - p0));
                if (planeDist > planeThreshold) continue;
                appendTraceTriangleToVoxel(
                    voxel,
                    p0, p1, p2, uv0, uv1, uv2,
                    tint, skyLight, emission, textureIndex
                );
                inserted++;
            }
        }
    }
}
// Stratified integration of alpha-tested emitting coverage over a triangle.
vec2 traceEmissionStats(vec3 a, vec3 b, vec3 c, vec2 ua, vec2 ub, vec2 uc, float seed) {
#ifndef MC_SPECULAR_MAP
    if (seed<=0.0) return vec2(0.0);
#endif
    float coverage = 0.0;
    float power = 0.0;
    for (int y=0;y<8;++y) for (int x=0;x<8;++x) {
        float u=sqrt((float(x)+0.5)/8.0);
        float v=(float(y)+0.5)/8.0;
        vec2 uv=ua*(1.0-u)+ub*(u*(1.0-v))+uc*(u*v);
        vec4 albedo=textureLod(gtexture,uv,0.0);
        float alpha=albedo.a;
        float emissive=seed;
#ifdef MC_SPECULAR_MAP
        float lab=textureLod(specular,uv,0.0).a;
        emissive=max(emissive,lab < 1.0 ? lab : 0.0);
#endif
        coverage += float(alpha>0.01 && emissive>0.0);
        if(alpha>=0.95) power+=clamp(emissive,0.0,1.0)*dot(albedo.rgb*albedo.rgb,vec3(0.2126,0.7152,0.0722));
    }
    return 0.5*length(cross(b-a,c-a))*vec2(coverage,power)/64.0;
}
// Keep selection independent of voxel-list duplication. Missing tiny textured
// emitters remain BSDF-only; their primitive map is DI_INVALID.
void registerDILight(vec3 p0, vec3 p1, vec3 p2, vec2 uv0, vec2 uv1, vec2 uv2,
    vec3 tint, float emission, uint textureIndex, bool quad, vec2 stats) {
    currentDILight = DI_INVALID;
    #ifndef PT_EMISSIVE_NEE
    return;
#endif
    if (stats.x <= 0.0) return;
    uint id = atomicAdd(diLightCount, 1u);
    if (id >= diLightCapacity) return;
    DILight light;
    light.p0 = vec4(p0, length(cross(p1-p0,p2-p0)) * (quad ? 1.0 : 0.5));
    light.e1 = vec4(p1-p0,0.0);
    light.e2 = vec4(quad ? p2-p1 : p2-p0,0.0);
    bool atlas = textureIndex == TRACE_TEXTURE_INDEX_ATLAS;
    light.data = uvec4(atlas ? packUnorm2x16(uv0) : packHalf2x16(uv0),
        atlas ? packUnorm2x16(uv1) : packHalf2x16(uv1),
        atlas ? packUnorm2x16(uv2) : packHalf2x16(uv2),
        packTraceTextureTintAndEmission(textureIndex,tint,emission));
    // Quantized absolute position survives camera-relative grid shifts.
    ivec3 absoluteCell = ivec3(floor(cameraPosition));
    ivec3 quantized=ivec3(round(p0*4096.0));
    uvec3 key=uvec3((quantized>>12)+absoluteCell);
    uvec3 subcell=uvec3(quantized)&uvec3(4095u);
    uint hash = ptRandomHash(key.x)^ptRandomHash(key.y+17u)^ptRandomHash(key.z+31u);
    hash=ptRandomHash(hash^subcell.x^(subcell.y<<12u))^ptRandomHash(subcell.z);
    for (int k=0;k<3;++k) {
        hash = ptRandomHash(hash ^ uint(int(round(light.e1[k]*4096.0))));
        hash = ptRandomHash(hash ^ uint(int(round(light.e2[k]*4096.0))));
    }
    hash = ptRandomHash(hash ^ light.data.x ^ light.data.y ^ light.data.z ^ light.data.w);
    light.meta = uvec4(hash,currentEmissionOwner,quad ? 1u : 0u,0u);
    diLights[id] = light;
    vec3 center=p0+(light.e1.xyz+light.e2.xyz)*(quad ? 0.5 : 1.0/3.0);
    float tintPower=max(dot(tint*tint,vec3(0.2126,0.7152,0.0722)),1e-4);
    diLightProxy[id]=vec4(center,max(stats.y*tintPower,light.p0.w*1e-6));
    // Resolve a stable identity back to this frame's non-deterministic append ID.
    for (uint probe=0u;probe<32u;++probe) {
        uint cell=(hash+probe)&32767u;
        if (atomicCompSwap(diLightLookup[cell],DI_INVALID,id)==DI_INVALID) break;
    }
    currentDILight = id;
}
void writeTraceMeshTriangle() {
    bool isQuad = vTraceQuadMarker[0] == 0;
    // Minecraft submits a quad as two consecutive raster triangles.  The
    // first triangle contains enough information to reconstruct the fourth
    // corner, so the second invocation does no mesh-building work.
    if (isQuad && (gl_PrimitiveIDIn & 1) != 0) return;
    if ((vTraceValid[0] | vTraceValid[1] | vTraceValid[2]) == 0u) return;
    vec3 p0 = vTracePlayerPos[0];
    vec3 p1 = vTracePlayerPos[1];
    vec3 p2 = vTracePlayerPos[2];
    if (!traceTrianglePreCull(p0, p1, p2)) return;
    vec2 uv0 = vTexcoord[0];
    vec2 uv1 = vTexcoord[1];
    vec2 uv2 = vTexcoord[2];
    vec3 tint = clamp((vGlcolor[0].rgb + vGlcolor[1].rgb + vGlcolor[2].rgb) * 0.3333333, vec3(0.0), vec3(1.0));
    vec4 skyLight = (vTraceSkyLight[0] + vTraceSkyLight[1] + vTraceSkyLight[2]) * 0.3333333;
    float emission = (vTraceEmission[0] + vTraceEmission[1] + vTraceEmission[2]) * 0.3333333;
    vec2 emissionStats=traceEmissionStats(p0,p1,p2,uv0,uv1,uv2,emission);
    if(isQuad) emissionStats+=traceEmissionStats(p2,p0+p2-p1,p0,uv2,uv0+uv2-uv1,uv0,emission);
    currentEmissionOwner = 0xffffffffu;
#if defined TRACE_STAGE_TERRAIN
    ivec3 ownerCell=ivec3(floor(vTraceBlockCenter[0]))+traceVoxelHalf;
    if (traceVoxelInside(ownerCell)) {
        currentEmissionOwner=flattenTraceVoxel(ownerCell);
        vec3 center=vTraceBlockCenter[0];
        vec3 lo=min(p0,min(p1,p2))-center;
        vec3 hi=max(p0,max(p1,p2))-center;
        vec3 span=hi-lo;
        vec3 n=abs(normalize(cross(p1-p0,p2-p0)));
        bool axisAligned=max(n.x,max(n.y,n.z))>0.9999;
        float faceArea=length(cross(p1-p0,p2-p0));
        bool unitFace=isQuad && axisAligned && abs(faceArea-1.0)<0.0001 &&
            all(lessThanEqual(abs(lo),vec3(0.5001))) && all(lessThanEqual(abs(hi),vec3(0.5001))) &&
            abs(dot((p0+p2)*0.5-center,n))>0.4999;
        atomicOr(emissionBlockShape[currentEmissionOwner],unitFace?1u:2u);
        if (emissionStats.x>0.0) atomicAdd(emissionBlockArea[currentEmissionOwner],uint(max(round(emissionStats.x*emissionAreaUnits),1.0)));
    }
#endif
    uint textureIndex = TRACE_TEXTURE_INDEX_NONE;
    uint texOffset = 0u;
    uint stride = 1u;
    uvec2 texSize = uvec2(textureSize(gtexture, 0));
    bool validTexSize = texSize.x > 0u && texSize.y > 0u;
    if (!validTexSize) return;
#if defined TRACE_STAGE_TERRAIN
    // Terrain always samples the known block atlas.  It never hashes or copies
    // the bound texture, which keeps the hot shadow-build path texture-free.
    textureIndex = TRACE_TEXTURE_INDEX_ATLAS;
#else
    uvec2 storageSize = uvec2(1u);
    uint sourceLod = 0u;
    uint textureKey = traceStableTextureKey();
    bool needsCopy = addTraceTexture(
        textureKey, texSize,
        textureIndex, texOffset, stride, storageSize, sourceLod
    );
    if (textureIndex == TRACE_TEXTURE_INDEX_NONE) return;
    if (needsCopy) {
        emitTraceTextureCopyQuad(
            texOffset, stride, storageSize, sourceLod
        );
    }
#endif
    registerDILight(p0,p1,p2,uv0,uv1,uv2,tint,emission,textureIndex,isQuad,emissionStats);
    if (isQuad) {
        vec3 p3 = p0 + p2 - p1;
        vec2 uv3 = uv0 + uv2 - uv1;
        if (voxelizeTraceCompactUnitFace(
            p0, p1, p2, p3,
            uv0, uv1, uv2, uv3,
            tint, skyLight, emission, textureIndex
        )) return;

        // Non-unit and non-axis-aligned quads still avoid a second geometry
        // invocation, but retain two ordinary triangles for exact tracing.
        voxelizeTraceTriangle(
            p0, p1, p2, uv0, uv1, uv2,
            tint, skyLight, emission, textureIndex
        );
        voxelizeTraceTriangle(
            p2, p3, p0, uv2, uv3, uv0,
            tint, skyLight, emission, textureIndex
        );
        return;
    }
    voxelizeTraceTriangle(
        p0, p1, p2, uv0, uv1, uv2,
        tint, skyLight, emission, textureIndex
    );
}
