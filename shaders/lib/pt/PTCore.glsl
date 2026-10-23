#ifndef PT_GLSL
#define PT_GLSL

#include "/lib/pt/PTBuffers.glsl"
uniform sampler2D traceBlockAtlas;
uniform sampler2D traceBlockSpecularAtlas;

#define SSPT_MAX_STEPS 256
#define SSPT_MIN_STEPS 16
#define SSPT_BINARY_STEPS 5
#define SSPT_PIXEL_STRIDE 2.0
#define SSPT_START_BIAS 0.06
#define SSPT_DEPTH_THICKNESS 0.25
#define SSPT_DEPTH_THICKNESS_SCALE 0.0015
#define SSPT_SCREEN_MARGIN 0.002
#define SSPT_UNBOUNDED_DISTANCE 1e30
#define TRACE_VOLUME_ENTRY_BIAS 0.002
#define TRACE_TRANSPARENT_ALPHA_MIN 0.01
#define TRACE_TRANSPARENT_ALPHA 0.95
#define TRACE_TRANSPARENT_BIAS 0.002
#define TRACE_TRANSPARENT_MAX_LAYERS 8 // [4 8 12 16 24 32 48 64 96 128]
#define TRACE_PRIMITIVE_SLOT_MAX 4194304u
#define TRACE_PRIMITIVE_SLOT_MASK 0x003fffffu
#define TRACE_PRIMITIVE_COMPACT_FACE_BIT 0x00800000u
// A ray crossing the complete 128^3 volume can cross up to 384 boundaries.
#define TRACE_PT_MAX_STEPS (3 * (TRACE_SIZE_X + TRACE_SIZE_Y + TRACE_SIZE_Z))
#define TRACE_CHAIN_HARD_CAP 256
#define TRACE_TEXTURE_INDEX_ATLAS 4095u
#define TRACE_TEXTURE_INDEX_MASK 0x00000fffu
#define TRACE_TINT_SHIFT 12u
#define TRACE_EMISSION_SHIFT 28u
#define TRACE_EMISSION_MASK 0x0000000fu
const ivec3 traceVoxelSize = ivec3(TRACE_SIZE_X, TRACE_SIZE_Y, TRACE_SIZE_Z);
const ivec3 traceVoxelHalf = ivec3(TRACE_SIZE_X / 2, TRACE_SIZE_Y / 2, TRACE_SIZE_Z / 2);
struct TraceTriangle {
    vec4 p0;
    vec4 e1;
    vec4 e2;
    uvec4 data;
    uint nextRef;
    float skyAccess;
};
struct TriHit {
    uint diLight;
    bool hit;
    bool screenSpace;
    bool exitedVolume;
    float t;
    vec3 color;
    vec3 skyLight;
    float skyAccess;
    vec3 screenLight;
    float emission;
    float rawEmission; // Uncompensated surface appearance.
    float roughness;
    float materialValue;
    float alpha;
    vec3 transmittance;
    vec3 normal;
    vec3 position;
};
struct TraceSurfaceSample {
    vec4 albedo;
    float labEmission;
    float roughness;
    float materialValue;
};
struct TraceCompactFace {
    ivec3 faceMin;
    int axis;
    int planeSide;
    vec2 uvOrigin;
    vec2 uvAxisA;
    vec2 uvAxisB;
    vec2 uvMin;
    vec2 uvMax;
    vec3 skyLight;
    float skyAccess;
    uint packedData;
    uint nextRef;
};
uint flattenTraceVoxel(ivec3 voxel) {
    return uint(voxel.x + voxel.y * TRACE_SIZE_X + voxel.z * TRACE_SIZE_X * TRACE_SIZE_Y);
}
bool traceVoxelInside(ivec3 voxel) {
    return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, traceVoxelSize));
}
float luminance3(vec3 c) {
    return max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.0);
}
float safeInvAbs(float x) {
    return abs(x) > 1e-8 ? abs(1.0 / x) : 1e30;
}
float firstVoxelBoundaryT(float origin, float dir, int voxelCoord, int halfCoord) {
    float cellMin = float(voxelCoord - halfCoord);
    float boundary = dir > 0.0 ? cellMin + 1.0 : cellMin;
    return abs(dir) > 1e-8 ? (boundary - origin) / dir : 1e30;
}
#include "/lib/pt/PTSampling.glsl"
vec3 sampleCosineHemisphereDirection(vec2 noisePair, vec3 normalDir) {
    float phi = noisePair.x * 6.2831853;
    float r = sqrt(noisePair.y);
    float x = r * cos(phi);
    float y = r * sin(phi);
    float z = sqrt(max(1.0 - noisePair.y, 0.0));
    vec3 tangent = normalize(abs(normalDir.y) < 0.999
        ? cross(vec3(0.0, 1.0, 0.0), normalDir)
        : cross(vec3(1.0, 0.0, 0.0), normalDir));
    vec3 bitangent = cross(normalDir, tangent);
    return normalize(tangent * x + bitangent * y + normalDir * z);
}
TraceTriangle loadTraceTriangle(uint slotIndex) {
    TraceTriangle tri;
    uvec4 p0Data = tracePrimitiveSlots[slotIndex + 0u];
    uvec4 e1Data = tracePrimitiveSlots[slotIndex + 1u];
    uvec4 e2Data = tracePrimitiveSlots[slotIndex + 2u];
    tri.nextRef = ((p0Data.x & 7u) << 0u)
        | ((p0Data.y & 7u) << 3u)
        | ((p0Data.z & 7u) << 6u)
        | ((e1Data.x & 7u) << 9u)
        | ((e1Data.y & 7u) << 12u)
        | ((e1Data.z & 7u) << 15u)
        | ((e2Data.x & 7u) << 18u)
        | ((e2Data.y & 7u) << 21u);
    p0Data.xyz &= uvec3(0xfffffff8u);
    e1Data.xyz &= uvec3(0xfffffff8u);
    e2Data.xy &= uvec2(0xfffffff8u);
    tri.p0 = uintBitsToFloat(p0Data);
    vec2 skyRedAndAccess = unpackHalf2x16(p0Data.w);
    tri.p0.w = skyRedAndAccess.x;
    tri.skyAccess = skyRedAndAccess.y;
    tri.e1 = uintBitsToFloat(e1Data);
    tri.e2 = uintBitsToFloat(e2Data);
    tri.data = tracePrimitiveSlots[slotIndex + 3u];
    return tri;
}
int traceFaceTangentAxisA(int axis) {
    return axis == 0 ? 1 : 0;
}
int traceFaceTangentAxisB(int axis) {
    return axis == 2 ? 1 : 2;
}
TraceCompactFace loadTraceCompactFace(uint slotIndex, ivec3 voxel) {
    uvec4 data = tracePrimitiveSlots[slotIndex];
    TraceCompactFace face;
    face.nextRef = data.y & 0x00ffffffu;
    face.axis = int((data.y >> 24u) & 3u);
    face.planeSide = int((data.y >> 26u) & 1u);
    face.faceMin = voxel - traceVoxelHalf;
    if (face.axis >= 0 && face.axis <= 2) {
        face.faceMin[face.axis] += face.planeSide;
    }

    vec2 atlasSize = vec2(max(textureSize(traceBlockAtlas, 0), ivec2(1)));
    uvec2 tileOffset = uvec2(data.x & 65535u, (data.x >> 16u) & 65535u);
    float tileSize = exp2(float((data.z >> 23u) & 31u));
    uint orientation = (data.z >> 20u) & 7u;
    bool axisAAlongU = (orientation & 1u) != 0u;
    float axisASign = (orientation & 2u) != 0u ? 1.0 : -1.0;
    float axisBSign = (orientation & 4u) != 0u ? 1.0 : -1.0;
    vec2 tangent = axisAAlongU
        ? vec2(axisASign, 0.0) : vec2(0.0, axisASign);
    vec2 bitangent = axisAAlongU
        ? vec2(0.0, axisBSign) : vec2(axisBSign, 0.0);
    vec2 tileOrigin = -min(tangent, vec2(0.0)) - min(bitangent, vec2(0.0));
    vec2 tileBase = vec2(tileOffset);
    face.uvOrigin = (tileBase + tileOrigin * tileSize) / atlasSize;
    face.uvAxisA = tangent * tileSize / atlasSize;
    face.uvAxisB = bitangent * tileSize / atlasSize;
    face.uvMin = (tileBase + vec2(0.5)) / atlasSize;
    face.uvMax = (tileBase + vec2(tileSize - 0.5)) / atlasSize;

    uvec3 sky = uvec3(
        data.w & 1023u,
        (data.w >> 10u) & 1023u,
        (data.w >> 20u) & 1023u
    );
    face.skyLight = vec3(sky) / 1023.0;
    face.skyAccess = float((data.z >> 28u) & 15u) / 15.0;
    uint tint565 = data.z & 0xffffu;
    uint emission = (data.z >> 16u) & 15u;
    face.packedData = TRACE_TEXTURE_INDEX_ATLAS
        | (tint565 << TRACE_TINT_SHIFT)
        | (emission << TRACE_EMISSION_SHIFT);
    return face;
}
bool intersectTraceTriangle(vec3 rayOrigin, vec3 rayDir, TraceTriangle tri, out float t, out vec3 normal, out vec3 bary) {
    vec3 p0 = tri.p0.xyz;
    vec3 e1 = tri.e1.xyz;
    vec3 e2 = tri.e2.xyz;
    vec3 pvec = cross(rayDir, e2);
    float det = dot(e1, pvec);
    if (abs(det) < 1e-7) return false;
    float invDet = 1.0 / det;
    vec3 tvec = rayOrigin - p0;
    float u = dot(tvec, pvec) * invDet;
    if (u < -1e-5 || u > 1.00001) return false;
    vec3 qvec = cross(tvec, e1);
    float v = dot(rayDir, qvec) * invDet;
    if (v < -1e-5 || u + v > 1.00001) return false;
    t = dot(e2, qvec) * invDet;
    if (t <= 1e-4) return false;
    bary = vec3(1.0 - u - v, u, v);
    normal = normalize(cross(e1, e2));
    if (dot(normal, rayDir) > 0.0) normal = -normal;
    return true;
}
bool intersectTraceCompactFace(
    vec3 rayOrigin,
    vec3 rayDir,
    TraceCompactFace face,
    out float t,
    out vec3 normal,
    out vec2 uv
) {
    int axis = face.axis;
    if (axis < 0 || axis > 2 || abs(rayDir[axis]) < 1e-8) return false;
    t = (float(face.faceMin[axis]) - rayOrigin[axis]) / rayDir[axis];
    if (t <= 1e-4) return false;
    vec3 hitPosition = rayOrigin + rayDir * t;
    int axisA = traceFaceTangentAxisA(axis);
    int axisB = traceFaceTangentAxisB(axis);
    vec2 local = vec2(
        hitPosition[axisA] - float(face.faceMin[axisA]),
        hitPosition[axisB] - float(face.faceMin[axisB])
    );
    if (any(lessThan(local, vec2(-1e-5))) ||
        any(greaterThan(local, vec2(1.00001)))) return false;
    local = clamp(local, vec2(0.0), vec2(1.0));
    normal = vec3(0.0);
    normal[axis] = rayDir[axis] > 0.0 ? -1.0 : 1.0;
    // Geometry still reaches the complete closed edge. Only texture lookup
    // is inset, so both nearest and linear sampling stay inside this sprite.
    uv = clamp(
        face.uvOrigin + face.uvAxisA * local.x + face.uvAxisB * local.y,
        face.uvMin, face.uvMax
    );
    return true;
}
vec3 unpackTraceTriangleSkyLight(TraceTriangle tri) {
    return max(vec3(tri.p0.w, tri.e1.w, tri.e2.w), vec3(0.0));
}
float unpackTraceTriangleEmission(TraceTriangle tri) {
    uint packedEmission = (tri.data.w >> TRACE_EMISSION_SHIFT) & TRACE_EMISSION_MASK;
    return float(packedEmission) / 15.0;
}
uint getTraceTextureIndex(TraceTriangle tri) {
    return tri.data.w & TRACE_TEXTURE_INDEX_MASK;
}
float unpackTracePrimitiveEmission(uint packedData) {
    uint packedEmission = (packedData >> TRACE_EMISSION_SHIFT) & TRACE_EMISSION_MASK;
    return float(packedEmission) / 15.0;
}
uint getTracePrimitiveTextureIndex(uint packedData) {
    return packedData & TRACE_TEXTURE_INDEX_MASK;
}
vec3 unpackTraceTint565(uint packedData) {
    uint t = packedData >> TRACE_TINT_SHIFT;
    float r = float(t & 31u) / 31.0;
    float g = float((t >> 5u) & 63u) / 63.0;
    float b = float((t >> 11u) & 31u) / 31.0;
    return vec3(r, g, b);
}
vec2 unpackTraceUV(uint packedUV, bool isAtlas) {
    return isAtlas ? unpackUnorm2x16(packedUV) : unpackHalf2x16(packedUV);
}
vec2 traceTriangleUV(TraceTriangle tri, vec3 bary) {
    bool isAtlas = getTraceTextureIndex(tri) == TRACE_TEXTURE_INDEX_ATLAS;
    vec2 uv0 = unpackTraceUV(tri.data.x, isAtlas);
    vec2 uv1 = unpackTraceUV(tri.data.y, isAtlas);
    vec2 uv2 = unpackTraceUV(tri.data.z, isAtlas);
    vec2 uv = uv0 * bary.x + uv1 * bary.y + uv2 * bary.z;
    if (isAtlas) {
        vec2 uvMin = min(uv0, min(uv1, uv2));
        vec2 uvMax = max(uv0, max(uv1, uv2));
        vec2 halfTexel = 0.5 / vec2(max(textureSize(traceBlockAtlas, 0), ivec2(1)));
        vec2 inset = min(halfTexel, (uvMax - uvMin) * 0.5);
        uv = clamp(uv, uvMin + inset, uvMax - inset);
    }
    return uv;
}
TraceSurfaceSample sampleTracePrimitiveSurface(
    uint textureIndex,
    vec2 uv,
    uint packedData
) {
    TraceSurfaceSample surface;
    surface.albedo = vec4(1.0);
    surface.labEmission = 0.0;
    surface.roughness = 1.0;
    surface.materialValue = 0.0;
    if (textureIndex == TRACE_TEXTURE_INDEX_ATLAS) {
        surface.albedo = textureLod(traceBlockAtlas, uv, 0.0);
        vec4 specularSample = textureLod(traceBlockSpecularAtlas, uv, 0.0);
        float smoothness = clamp(specularSample.r, 0.0, 1.0);
        surface.roughness = (1.0 - smoothness) * (1.0 - smoothness);
        surface.materialValue = clamp(specularSample.g, 0.0, 1.0);
        float specA = specularSample.a;
        float specA255 = floor(clamp(specA, 0.0, 1.0) * 255.0 + 0.5);
        surface.labEmission = specA255 < 255.0 ? specA255 / 254.0 : 0.0;
    } else if (textureIndex < 16u) {
        uint bounds = traceTextureKeys[textureIndex].bounds;
        uvec2 size = max(
            uvec2(bounds & 0xffffu, bounds >> 16u),
            uvec2(1u)
        );
        uint offset = textureIndex * 1048576u;
        vec2 wrappedUV = fract(uv);
        uvec2 texel = uvec2(clamp(wrappedUV, vec2(0.0), vec2(0.999999)) * vec2(size));
        uint dataIndex = offset + texel.x + texel.y * size.x;
        uint texelPayload = traceTextureData[dataIndex];
        uint materialByte = (texelPayload >> 24u) & 255u;
        surface.albedo = vec4(
            float(texelPayload & 255u) / 255.0,
            float((texelPayload >> 8u) & 255u) / 255.0,
            float((texelPayload >> 16u) & 255u) / 255.0,
            materialByte < 255u ? 1.0 : 0.0
        );
        surface.labEmission = materialByte < 255u ? float(materialByte) / 254.0 : 0.0;
    }
    surface.albedo.rgb *= unpackTraceTint565(packedData);
    surface.albedo = clamp(surface.albedo, vec4(0.0), vec4(1.0));
    // Atlas and compact copies store sRGB; trace hits always return linear RGB.
    surface.albedo.rgb = srgbToLinear(surface.albedo.rgb);
    return surface;
}
TraceSurfaceSample sampleTraceTriangleSurface(TraceTriangle tri, vec3 bary) {
    return sampleTracePrimitiveSurface(
        getTraceTextureIndex(tri), traceTriangleUV(tri, bary), tri.data.w
    );
}
TriHit makeEmptyTriHit(float maxDistance) {
    TriHit h;
    h.diLight = DI_INVALID;
    h.hit = false;
    h.screenSpace = false;
    h.exitedVolume = false;
    h.t = maxDistance;
    h.color = vec3(0.0);
    h.skyLight = vec3(0.0);
    h.skyAccess = 0.0;
    h.screenLight = vec3(0.0);
    h.emission = 0.0;
    h.rawEmission = 0.0;
    h.roughness = 1.0;
    h.materialValue = 0.0;
    h.alpha = 0.0;
    h.transmittance = vec3(1.0);
    h.normal = vec3(0.0, 1.0, 0.0);
    h.position = vec3(0.0);
    return h;
}
vec3 getTraceTransmissionFilter(vec3 surfaceColor, float alpha) {
    float opacity = clamp(alpha, 0.0, 1.0);
    // RGB filters transmission; alpha attenuates energy.
    return clamp(surfaceColor, vec3(0.0), vec3(1.0)) * (1.0 - opacity);
}
bool findNearestTriangleInVoxel(
    ivec3 voxel,
    vec3 rayOrigin,
    vec3 rayDir,
    float minDistance,
    float tExitCell,
    float maxDistance,
    out TriHit nearest
) {
    nearest = makeEmptyTriHit(min(maxDistance, tExitCell + 0.02));
    uint nodeRef = traceHead[flattenTraceVoxel(voxel)];
    bool foundInCell = false;
    for (int guard = 0; guard < TRACE_CHAIN_HARD_CAP && nodeRef != TRACE_END; guard++) {
        if ((nodeRef & 0x00400000u) != 0u) break;
        bool compactFace =
            (nodeRef & TRACE_PRIMITIVE_COMPACT_FACE_BIT) != 0u;
        uint slotIndex = nodeRef & TRACE_PRIMITIVE_SLOT_MASK;
        uint slotCount = compactFace ? 1u : 4u;
        if (slotIndex > TRACE_PRIMITIVE_SLOT_MAX - slotCount) break;
        float tHit;
        vec3 nHit;
        vec3 hitSkyLight;
        float hitSkyAccess;
        float hitEmission;
        TraceSurfaceSample hitSurface;
        bool primitiveHit = false;
        uint nextRef = TRACE_END;
        if (compactFace) {
            TraceCompactFace face = loadTraceCompactFace(slotIndex, voxel);
            nextRef = face.nextRef;
            vec2 hitUv;
            primitiveHit = intersectTraceCompactFace(
                rayOrigin, rayDir, face, tHit, nHit, hitUv
            );
            if (primitiveHit) {
                hitSurface = sampleTracePrimitiveSurface(
                    getTracePrimitiveTextureIndex(face.packedData),
                    hitUv,
                    face.packedData
                );
                hitSkyLight = face.skyLight;
                hitSkyAccess = face.skyAccess;
                hitEmission = unpackTracePrimitiveEmission(face.packedData);
            }
        } else {
            TraceTriangle tri = loadTraceTriangle(slotIndex);
            nextRef = tri.nextRef;
            vec3 baryHit;
            primitiveHit = intersectTraceTriangle(
                rayOrigin, rayDir, tri, tHit, nHit, baryHit
            );
            if (primitiveHit) {
                hitSurface = sampleTraceTriangleSurface(tri, baryHit);
                hitSkyLight = unpackTraceTriangleSkyLight(tri);
                hitSkyAccess = tri.skyAccess;
                hitEmission = unpackTraceTriangleEmission(tri);
            }
        }
        if (primitiveHit) {
            if (tHit >= max(1e-4, minDistance) &&
                tHit <= min(nearest.t, tExitCell + 0.02) &&
                tHit < maxDistance) {
                float hitAlpha = clamp(hitSurface.albedo.a, 0.0, 1.0);
                if (hitAlpha > TRACE_TRANSPARENT_ALPHA_MIN) {
                    nearest.diLight = diPrimitiveLight[slotIndex];
                    nearest.hit = true;
                    nearest.t = tHit;
                    nearest.normal = nHit;
                    nearest.color = hitSurface.albedo.rgb;
                    nearest.skyLight = hitSkyLight;
                    nearest.skyAccess = hitSkyAccess;
                    nearest.rawEmission = clamp(
                        hitEmission + hitSurface.labEmission, 0.0, 1.0
                    );
                    nearest.emission = nearest.rawEmission * emissionAreaGain(emissionPrimitiveOwner[slotIndex]);
                    nearest.roughness = hitSurface.roughness;
                    nearest.materialValue = hitSurface.materialValue;
                    nearest.alpha = hitAlpha;
                    nearest.position = rayOrigin + rayDir * tHit;
                    foundInCell = true;
                }
            }
        }
        if (nextRef == nodeRef) break;
        nodeRef = nextRef;
    }
    return foundInCell;
}
TriHit traceTriangleWorld(vec3 rayOriginGrid, vec3 rayDirPlayer, float maxDistance) {
    TriHit result = makeEmptyTriHit(maxDistance);
    vec3 rayDir = normalize(rayDirPlayer);
    ivec3 voxel = traceVoxelHalf + ivec3(floor(rayOriginGrid));
    if (!traceVoxelInside(voxel)) {
        result.exitedVolume = true;
        result.t = 0.0;
        return result;
    }
    ivec3 stepVoxel = ivec3(
        rayDir.x > 0.0 ? 1 : (rayDir.x < 0.0 ? -1 : 0),
        rayDir.y > 0.0 ? 1 : (rayDir.y < 0.0 ? -1 : 0),
        rayDir.z > 0.0 ? 1 : (rayDir.z < 0.0 ? -1 : 0)
    );
    vec3 tMax = vec3(
        firstVoxelBoundaryT(rayOriginGrid.x, rayDir.x, voxel.x, traceVoxelHalf.x),
        firstVoxelBoundaryT(rayOriginGrid.y, rayDir.y, voxel.y, traceVoxelHalf.y),
        firstVoxelBoundaryT(rayOriginGrid.z, rayDir.z, voxel.z, traceVoxelHalf.z)
    );
    vec3 tDelta = vec3(safeInvAbs(rayDir.x), safeInvAbs(rayDir.y), safeInvAbs(rayDir.z));
    vec3 transmittance = vec3(1.0);
    float rayMinT = 1e-4;
    float tCurrent = 0.0;
    int transparentLayers = 0;
    for (int stepId = 0; stepId < TRACE_PT_MAX_STEPS; stepId++) {
        if (!traceVoxelInside(voxel)) break;
        if (tCurrent > maxDistance) break;
        float tExitCell = min(tMax.x, min(tMax.y, tMax.z));
        if (traceHead[flattenTraceVoxel(voxel)] != TRACE_END) {
            float searchMinT = max(tCurrent, rayMinT);
            while (searchMinT <= min(maxDistance, tExitCell + 0.02)) {
                TriHit candidate;
                if (!findNearestTriangleInVoxel(
                    voxel, rayOriginGrid, rayDir,
                    searchMinT, tExitCell, maxDistance,
                    candidate
                )) break;
                if (candidate.alpha >= TRACE_TRANSPARENT_ALPHA) {
                    candidate.transmittance = transmittance;
                    return candidate;
                }
                transmittance *= getTraceTransmissionFilter(candidate.color, candidate.alpha);
                transparentLayers++;
                rayMinT = candidate.t + TRACE_TRANSPARENT_BIAS;
                searchMinT = rayMinT;
                if (luminance3(transmittance) < 0.001 ||
                    transparentLayers >= TRACE_TRANSPARENT_MAX_LAYERS) {
                    result.transmittance = vec3(0.0);
                    return result;
                }
            }
        }
        if (tMax.x <= tMax.y && tMax.x <= tMax.z) {
            tCurrent = tMax.x;
            tMax.x += tDelta.x;
            voxel.x += stepVoxel.x;
        } else if (tMax.y <= tMax.z) {
            tCurrent = tMax.y;
            tMax.y += tDelta.y;
            voxel.y += stepVoxel.y;
        } else {
            tCurrent = tMax.z;
            tMax.z += tDelta.z;
            voxel.z += stepVoxel.z;
        }
    }
    if (!traceVoxelInside(voxel) && tCurrent < maxDistance) {
        result.exitedVolume = true;
        result.t = max(tCurrent, 0.0);
    }
    result.transmittance = transmittance;
    return result;
}

//==============================================================================//
// Shadow ray ANY-HIT: berhenti di hit opak pertama, hanya sampel albedo
//==============================================================================//
vec4 sampleTraceAlbedoOnly(uint textureIndex, vec2 uv, uint packedData) {
    if (textureIndex == TRACE_TEXTURE_INDEX_ATLAS) {
        vec4 a = textureLod(traceBlockAtlas, uv, 0.0);
        a.rgb = srgbToLinear(clamp(a.rgb * unpackTraceTint565(packedData), 0.0, 1.0));
        return a;
    }
    return sampleTracePrimitiveSurface(textureIndex, uv, packedData).albedo;
}

vec3 traceShadowWorld(vec3 rayOriginGrid, vec3 rayDirIn, float maxDistance) {
    vec3 rayDir = normalize(rayDirIn);
    ivec3 voxel = traceVoxelHalf + ivec3(floor(rayOriginGrid));
    if (!traceVoxelInside(voxel)) return vec3(1.0);

    ivec3 stepVoxel = ivec3(sign(rayDir));
    vec3 tMax = vec3(
        firstVoxelBoundaryT(rayOriginGrid.x, rayDir.x, voxel.x, traceVoxelHalf.x),
        firstVoxelBoundaryT(rayOriginGrid.y, rayDir.y, voxel.y, traceVoxelHalf.y),
        firstVoxelBoundaryT(rayOriginGrid.z, rayDir.z, voxel.z, traceVoxelHalf.z));
    vec3 tDelta = vec3(safeInvAbs(rayDir.x), safeInvAbs(rayDir.y), safeInvAbs(rayDir.z));

    vec3  transmittance = vec3(1.0);
    float tCurrent = 0.0;
    int   layers = 0;

    for (int stepId = 0; stepId < TRACE_PT_MAX_STEPS; ++stepId) {
        if (!traceVoxelInside(voxel) || tCurrent > maxDistance) break;
        float tExitCell = min(tMax.x, min(tMax.y, tMax.z));

        uint nodeRef = traceHead[flattenTraceVoxel(voxel)];
        for (int guard = 0; guard < TRACE_CHAIN_HARD_CAP && nodeRef != TRACE_END; ++guard) {
            if ((nodeRef & 0x00400000u) != 0u) break;
            bool compactFace = (nodeRef & TRACE_PRIMITIVE_COMPACT_FACE_BIT) != 0u;
            uint slotIndex = nodeRef & TRACE_PRIMITIVE_SLOT_MASK;
            if (slotIndex > TRACE_PRIMITIVE_SLOT_MAX - (compactFace ? 1u : 4u)) break;

            uint nextRef; bool hit = false; float tHit = 0.0; vec3 nHit; vec4 albedo = vec4(1.0);
            if (compactFace) {
                TraceCompactFace face = loadTraceCompactFace(slotIndex, voxel);
                nextRef = face.nextRef;
                vec2 uv;
                if (intersectTraceCompactFace(rayOriginGrid, rayDir, face, tHit, nHit, uv) && tHit < maxDistance) {
                    hit = true;
                    albedo = sampleTraceAlbedoOnly(TRACE_TEXTURE_INDEX_ATLAS, uv, face.packedData);
                }
            } else {
                TraceTriangle tri = loadTraceTriangle(slotIndex);
                nextRef = tri.nextRef;
                vec3 bary;
                if (intersectTraceTriangle(rayOriginGrid, rayDir, tri, tHit, nHit, bary) && tHit < maxDistance) {
                    hit = true;
                    albedo = sampleTraceAlbedoOnly(getTraceTextureIndex(tri), traceTriangleUV(tri, bary), tri.data.w);
                }
            }

            if (hit) {
                float a = clamp(albedo.a, 0.0, 1.0);
                if (a >= TRACE_TRANSPARENT_ALPHA) return vec3(0.0); // opak -> langsung gelap
                // transparan: hitung hanya di sel tempat titik hit berada (hindari dobel hitung)
                if (a > TRACE_TRANSPARENT_ALPHA_MIN && tHit >= tCurrent && tHit < tExitCell) {
                    transmittance *= getTraceTransmissionFilter(albedo.rgb, a);
                    if (luminance3(transmittance) < 0.001 || ++layers >= TRACE_TRANSPARENT_MAX_LAYERS) return vec3(0.0);
                }
            }
            if (nextRef == nodeRef) break;
            nodeRef = nextRef;
        }

        if (tMax.x <= tMax.y && tMax.x <= tMax.z) { tCurrent = tMax.x; tMax.x += tDelta.x; voxel.x += stepVoxel.x; }
        else if (tMax.y <= tMax.z)                { tCurrent = tMax.y; tMax.y += tDelta.y; voxel.y += stepVoxel.y; }
        else                                      { tCurrent = tMax.z; tMax.z += tDelta.z; voxel.z += stepVoxel.z; }
    }
    return transmittance;
}

//==============================================================================//
// Point light STOKASTIK: pilih 1 lampu sebanding kontribusinya, 1 shadow ray.
// Unbiased: E[vis * total] = sum(w_i * vis_i). Dulu N lampu x 8 ray.
//==============================================================================//
uint ptPLCounter = 0u;

float ptPointLightWeight(vec4 light, vec3 P, vec3 N) {
    if (light.w <= 0.0) return 0.0;
    vec3 d = light.xyz - P;
    float d2 = dot(d, d);
    if (d2 <= 1e-8) return 0.0;
    float c = dot(N, d) * inversesqrt(d2);
    return c > 0.0 ? 0.4774648293 * light.w * c / d2 : 0.0;
}

vec3 getPointLightIllumination(vec3 positionGrid, vec3 normalGrid) {
    if (PT_POINT_LIGHT_STRENGTH <= 0.0) return vec3(0.0);
    if (!traceVoxelInside(traceVoxelHalf + ivec3(floor(positionGrid)))) return vec3(0.0);
    uint count = min(pointLightCount, pointLightCapacity);
    if (count == 0u) return vec3(0.0);

    float total = 0.0;
    for (uint i = 0u; i < count; ++i) total += ptPointLightWeight(pointLights[i], positionGrid, normalGrid);
    if (total <= 0.0) return vec3(0.0);

    uint h = ptRandomHash(floatBitsToUint(positionGrid.x)
           ^ ptRandomHash(floatBitsToUint(positionGrid.z)
           ^ ptRandomHash(floatBitsToUint(positionGrid.y) + uint(frameCounter) * 0x9e3779b9u + (ptPLCounter++) * 0x85ebca6bu)));
    float u0 = float(h & 0xffffu) / 65536.0;
    float u1 = float(h >> 16u) / 65536.0;
    float u2 = float(ptRandomHash(h) >> 8u) / 16777216.0;

    float target = u0 * total, acc = 0.0;
    uint chosen = count - 1u;
    for (uint i = 0u; i < count; ++i) {
        acc += ptPointLightWeight(pointLights[i], positionGrid, normalGrid);
        if (acc > target) { chosen = i; break; }
    }

    vec3 lightPos = pointLights[chosen].xyz;
    vec3 dirC = normalize(lightPos - positionGrid);
    if (LIGHT_BLOCK_RADIUS > 0.0) {
        vec3 ax = abs(dirC.y) < 0.999 ? vec3(0, 1, 0) : vec3(1, 0, 0);
        vec3 t  = normalize(cross(ax, dirC));
        vec3 bt = cross(dirC, t);
        float r = sqrt(u1) * float(LIGHT_BLOCK_RADIUS), a = 6.2831853 * u2;
        lightPos += t * (r * cos(a)) + bt * (r * sin(a));
    }
    vec3 origin = positionGrid + normalGrid * 0.002;
    vec3 d = lightPos - origin;
    float dist = length(d);
    if (dist <= 1e-4) return vec3(0.0);
    return traceShadowWorld(origin, d / dist, max(dist - 0.0001, 0.0001)) * total;
}

#endif // PT_GLSL
