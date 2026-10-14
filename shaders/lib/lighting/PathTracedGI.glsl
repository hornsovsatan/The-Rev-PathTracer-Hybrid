#if !defined INCLUDE_LIB_LIGHTING_PTGI
#define INCLUDE_LIB_LIGHTING_PTGI

#include "/lib/pt/PTCore.glsl"

#define PT_INV_PI    0.31830988618
#define PT_SHADOW_EPS 0.01

//================================================================================================//
// Helper
//================================================================================================//

vec3 ptToRec2020(vec3 c) { return c * sRGB_2_Rec2020; }

// Dimensi random unik per sampel (s), vertex path (v), dan kegunaan (k)
uint ptDim(int s, int v, int k) {
    return (uint(s) << 22u) + (uint(v) << 16u) + uint(k);
}

vec3 ptSkyRadiance(vec3 dir) {
#if defined DIMENSION_OVERWORLD
    return AtmosphereSkyView(atmosphereViewPos, dir, sunDirWorld);
#else
    return vec3(0.0);
#endif
}

float ptCloudShadow(vec3 posGrid) {
#if defined DIMENSION_OVERWORLD && defined CLOUD_SHADOWS && defined PT_CLOUD_SHADOWS
    vec3 worldPos = posGrid - fract(cameraPosition);
    vec2 coord = WorldToCloudShadowScreenPos(worldPos).xy;
    return texture(cloudShadowTex, saturate(coord)).x;
#elif defined DIMENSION_OVERWORLD && !defined CLOUD_SHADOWS
    return 1.0 - wetness * 0.96;
#else
    return 1.0;
#endif
}

// Arah ke titik acak pada cakram matahari/bulan (bayangan lembut fisik)
vec3 ptSampleSunDir(vec2 xi) {
#ifdef PT_SUN_SOFT_SHADOWS
    bool isSun = dot(shadowDirWorld, sunDirWorld) > 0.0;
    float radius = 0.00465 * (isSun ? SUN_RADIUS_MULT : MOON_RADIUS_MULT);
    float cosT = mix(1.0, cos(radius), xi.x);
    float sinT = sqrt(max(1.0 - cosT * cosT, 0.0));
    float phi  = 6.28318530718 * xi.y;
    vec3 up = abs(shadowDirWorld.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 t  = normalize(cross(up, shadowDirWorld));
    vec3 bt = cross(shadowDirWorld, t);
    return normalize(t * (sinT * cos(phi)) + bt * (sinT * sin(phi)) + shadowDirWorld * cosT);
#else
    return shadowDirWorld;
#endif
}

//================================================================================================//
// Light sampling lampu emisif (NEE + RIS)
//================================================================================================//

struct PTLightSample {
    vec3  position;
    vec3  normal;
    vec3  Le;       // radiansi emisi (linear Rec.2020)
    float areaPdf;  // pdf ukuran-area, termasuk probabilitas memilih lampu
};

// Cari indeks pertama dengan CDF > x (binary search)
uint ptSelectLight(float x, uint count) {
    uint lo = 0u, hi = count - 1u;
    while (lo < hi) {
        uint mid = (lo + hi) >> 1u;
        if (diLightCDF[mid] > x) hi = mid; else lo = mid + 1u;
    }
    return lo;
}

PTLightSample ptSampleLightPoint(uint id, vec2 xi, float totalPower) {
    DILight L = diLights[id];
    bool quad = L.meta.z == 1u;

    vec2 b = xi;
    if (!quad && b.x + b.y > 1.0) b = 1.0 - b; // segitiga: lipat ke dalam

    vec3 e1 = L.e1.xyz;
    vec3 e2 = L.e2.xyz;

    PTLightSample s;
    s.position = L.p0.xyz + e1 * b.x + e2 * b.y;
    s.normal   = normalize(cross(e1, e2));

    uint texIndex = L.data.w & TRACE_TEXTURE_INDEX_MASK;
    bool atlas = texIndex == TRACE_TEXTURE_INDEX_ATLAS;
    vec2 uv0 = atlas ? unpackUnorm2x16(L.data.x) : unpackHalf2x16(L.data.x);
    vec2 uv1 = atlas ? unpackUnorm2x16(L.data.y) : unpackHalf2x16(L.data.y);
    vec2 uv2 = atlas ? unpackUnorm2x16(L.data.z) : unpackHalf2x16(L.data.z);

    vec2 uv = quad ? uv0 + (uv1 - uv0) * b.x + (uv2 - uv1) * b.y
                   : uv0 + (uv1 - uv0) * b.x + (uv2 - uv0) * b.y;
    if (atlas) {
        vec2 uv3 = quad ? uv0 + uv2 - uv1 : uv2;
        vec2 uvMin = min(min(uv0, uv1), min(uv2, uv3));
        vec2 uvMax = max(max(uv0, uv1), max(uv2, uv3));
        vec2 halfTexel = 0.5 / vec2(max(textureSize(traceBlockAtlas, 0), ivec2(1)));
        vec2 inset = min(halfTexel, (uvMax - uvMin) * 0.5);
        uv = clamp(uv, uvMin + inset, uvMax - inset);
    }

    TraceSurfaceSample surf = sampleTracePrimitiveSurface(texIndex, uv, L.data.w);
    float emission = clamp(unpackTracePrimitiveEmission(L.data.w) + surf.labEmission, 0.0, 1.0)
                   * emissionAreaGain(L.meta.y);

    // Konsisten dengan jalur BSDF: hanya texel opak yang memancarkan cahaya
    s.Le = surf.albedo.a >= TRACE_TRANSPARENT_ALPHA
         ? ptToRec2020(surf.albedo.rgb) * emission * PT_EMISSION_STRENGTH
         : vec3(0.0);

    float selectPdf = diLightProxy[id].w / totalPower;
    s.areaPdf = selectPdf / max(L.p0.w, 1e-8);
    return s;
}

// Hasil: faktor radiansi pantul SEBELUM albedo, yaitu (1/pi) * integral(Le * cos * V)
vec3 ptEmissiveNEE(vec3 origin, vec3 N, ivec2 pixel, int s, int v) {
    uint count = min(diLightCount, diLightCapacity);
    if (count == 0u) return vec3(0.0);
    float totalPower = diLightCDF[count - 1u];
    if (!(totalPower > 0.0)) return vec3(0.0);

    vec3 result = vec3(0.0);

    for (int ds = 0; ds < PT_DI_SAMPLES; ++ds) {
        // Resampled Importance Sampling (weighted reservoir, 1 slot)
        float wSum = 0.0;
        float chosenPhat = 0.0;
        vec3  chosenPos = vec3(0.0);
        vec3  chosenF   = vec3(0.0);

        for (int c = 0; c < PT_DI_CANDIDATES; ++c) {
            int k = 16 + (ds * PT_DI_CANDIDATES + c) * 2;
            vec2 r0 = ptRandomPair(pixel, frameCounter, ptDim(s, v, k));
            vec2 r1 = ptRandomPair(pixel, frameCounter, ptDim(s, v, k + 1));

            uint id = ptSelectLight(r0.x * totalPower, count);
            PTLightSample ls = ptSampleLightPoint(id, r1, totalPower);

            vec3 d = ls.position - origin;
            float dist2 = dot(d, d);
            if (dist2 < 1e-6) continue;
            vec3 wi = d * inversesqrt(dist2);

            float cosS = dot(N, wi);
            float cosL = abs(dot(ls.normal, wi));
            if (cosS <= 0.0 || cosL <= 0.0) continue;

            vec3  F    = ls.Le * (cosS * cosL / dist2) * PT_INV_PI; // tanpa bayangan, ukuran area
            float phat = luminance3(F);
            if (phat <= 0.0) continue;

            float w = phat / ls.areaPdf;
            wSum += w;
            if (r0.y * wSum < w) {
                chosenPhat = phat;
                chosenPos  = ls.position;
                chosenF    = F;
            }
        }

        if (chosenPhat <= 0.0) continue;

        float W = wSum / (float(PT_DI_CANDIDATES) * chosenPhat);

        // Shadow ray nyata ke titik lampu terpilih
        vec3 d = chosenPos - origin;
        float dist = length(d);
        TriHit blocker = traceTriangleWorld(origin, d / dist, max(dist - PT_SHADOW_EPS, 1e-4));
        if (!blocker.hit) result += chosenF * blocker.transmittance * W;
    }

    return result / float(PT_DI_SAMPLES);
}

//================================================================================================//
// Direct lighting di satu vertex path (sebelum albedo)
//================================================================================================//

vec3 ptVertexDirect(vec3 P, vec3 N, vec3 Ng, bool withSun, float skyAccess,
                    ivec2 pixel, int s, int v) {
    vec3 L = vec3(0.0);
    vec3 origin = P + Ng * PT_RAY_BIAS;

    #if defined DIMENSION_OVERWORLD && defined PT_SUN_NEE
        // skyAccess > 0 mencegah matahari bocor ke gua di luar jangkauan volume
        if (withSun && skyAccess > 1e-4) {
            vec3 sunDir = ptSampleSunDir(ptRandomPair(pixel, frameCounter, ptDim(s, v, 2)));
            float NdotL = dot(N, sunDir);
            if (NdotL > 0.0 && dot(Ng, sunDir) > 0.0) {
                TriHit sh = traceTriangleWorld(origin, sunDir, 1e4);
                if (!sh.hit) {
                    L += global.directIlluminance * PT_INV_PI * NdotL
                       * sh.transmittance * ptCloudShadow(P);
                }
            }
        }
    #endif

    #ifdef PT_EMISSIVE_NEE
        L += ptEmissiveNEE(origin, N, pixel, s, v);
    #endif

    L += getPointLightIllumination(P, N) * PT_POINT_LIGHT_STRENGTH;
    return L;
}

//================================================================================================//
// Integrator utama
//================================================================================================//

// Output = radiansi rata-rata berbobot kosinus (E/pi), albedo diterapkan di CombineLighting
vec4 CalculatePathTracedGI(ivec2 pixel, vec3 worldPos, vec3 geoNormal,
                           vec3 worldNormal, float skylight) {
    vec3 originGrid = worldPos + fract(cameraPosition);

    // Di luar volume voxel: fallback skylight SH milik Rev
    if (!traceVoxelInside(traceVoxelHalf + ivec3(floor(originGrid)))) {
        vec3 e = ConvolvedReconstructSH3(global.skySH, worldNormal) * cube(skylight);
        return vec4(e, 1.0);
    }

    // Guard normal map ekstrem
    if (dot(worldNormal, geoNormal) <= 0.0) worldNormal = geoNormal;

    vec3  sum = vec3(0.0);
    float escaped = 0.0;

    for (int s = 0; s < PT_SPP; ++s) {
        // Vertex 0 (permukaan pixel): lampu emisif + point light.
        // Matahari langsung di vertex 0 sudah dihitung CombineLighting (PCSS).
        sum += ptVertexDirect(originGrid, worldNormal, geoNormal, false, skylight, pixel, s, 0);

        vec3  throughput = vec3(1.0);
        vec3  pos = originGrid + geoNormal * PT_RAY_BIAS;
        vec3  n   = worldNormal;
        vec3  ng  = geoNormal;
        float lastSky = skylight;

        for (int b = 0; b < PT_BOUNCES; ++b) {
            vec3 dir = sampleCosineHemisphereDirection(
                ptRandomPair(pixel, frameCounter, ptDim(s, b, 0)), n);
            if (dot(dir, ng) <= 0.0) break;

            TriHit h = traceTriangleWorld(pos, dir, 1e4);
            throughput *= h.transmittance;

            if (!h.hit) {
                if (h.exitedVolume) {
                    // Keluar dari ATAS volume = langit terbuka; dari samping = pakai skylight vanilla
                    float exitY = pos.y + dir.y * h.t;
                    float gate  = exitY >= float(traceVoxelHalf.y) - 0.01 ? 1.0 : cube(lastSky);
                    sum += throughput * ptSkyRadiance(dir) * gate;
                    if (b == 0) escaped += 1.0;
                }
                break;
            }

            vec3 albedo = ptToRec2020(h.color);

            // Emisi yang terkena ray BSDF. Lampu yang sudah di-sample NEE dilewati
            // agar energinya tidak dihitung dua kali.
            bool neeCovers = false;
            #ifdef PT_EMISSIVE_NEE
                neeCovers = h.diLight != DI_INVALID;
            #endif
            if (!neeCovers) sum += throughput * albedo * h.emission * PT_EMISSION_STRENGTH;

            // Direct lighting di titik hit (matahari, lampu emisif, point light)
            sum += throughput * albedo
                 * ptVertexDirect(h.position, h.normal, h.normal, true, h.skyAccess, pixel, s, b + 1);

            throughput *= albedo;
            pos = h.position + h.normal * PT_RAY_BIAS;
            n = h.normal;
            ng = h.normal;
            lastSky = h.skyAccess;

            // Russian roulette (unbiased)
            if (b >= PT_RR_START) {
                float p = clamp(maxOf(throughput), 0.05, 0.98);
                if (ptRandomPair(pixel, frameCounter, ptDim(s, b, 1)).x > p) break;
                throughput /= p;
            }
        }
    }

    vec3 irradiance = sum / float(PT_SPP);

    #if PT_FIREFLY_CLAMP > 0
        irradiance = min(irradiance, vec3(PT_FIREFLY_CLAMP));
    #endif

    #ifdef PT_KEEP_MIN_AMBIENT
        #if defined DIMENSION_OVERWORLD
            irradiance += max(MINIMUM_AMBIENT_BRIGHTNESS, 5e-3 * nightVision);
        #elif defined DIMENSION_NETHER
            irradiance += (netherColorCustom + 0.5) * (1.0 + nightVision);
        #endif
    #endif

    return vec4(irradiance, escaped / float(PT_SPP));
}

#endif
