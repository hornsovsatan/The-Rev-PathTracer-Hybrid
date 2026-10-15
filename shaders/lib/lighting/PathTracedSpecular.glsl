#if !defined INCLUDE_LIB_LIGHTING_PT_SPECULAR
#define INCLUDE_LIB_LIGHTING_PT_SPECULAR

#include "/lib/lighting/SSR.glsl"
#include "/lib/lighting/PathTracedGI.glsl"

// Ray pantul tidak mengenai apa pun: langit (Overworld) / kabut (Nether)
vec3 ptSpecularMiss(vec3 worldPos, vec3 dir, float gate, float dither) {
#if defined DIMENSION_NETHER
    return RaymarchNetherFog(worldPos, worldPos + dir * lodRenderDist, dither, 16)[0];
#else
    if (isEyeInWater != 0) return vec3(0.0);
    return textureBicubic(skyEnvMapTex, saturate(ProjectCubemap(dir, 96.0))).rgb * gate;
#endif
}

vec4 CalculatePathTracedReflections(Material material, vec3 worldNormal, vec3 geoNormal,
                                    vec3 worldDir, vec3 viewPos, float skylight, float dither) {
    ivec2 pixel     = ivec2(gl_FragCoord.xy);
    vec3 worldPos   = transMAD(gbufferModelViewInverse, viewPos);
    vec3 originGrid = worldPos + fract(cameraPosition);

    // Di luar volume voxel -> SSR asli Rev
    if (!traceVoxelInside(traceVoxelHalf + ivec3(floor(originGrid))))
        return CalculateSpecularReflections(material, worldNormal, worldDir, viewPos, skylight, dither);

    if (dot(worldNormal, geoNormal) <= 0.0) worldNormal = geoNormal;

    mat3 tbn    = BuildOrthonormalBasis(worldNormal);
    vec3 origin = originGrid + geoNormal * PT_RAY_BIAS;

    int samples = PT_SPECULAR_SAMPLES;
    #ifdef ROUGH_REFLECTIONS
        if (material.mirrorMask) samples = 1;
    #else
        samples = 1;
    #endif

    vec3  sum = vec3(0.0);
    float distSum = 0.0;

    for (int i = 0; i < samples; ++i) {
        vec3 halfway = worldNormal;
        #ifdef ROUGH_REFLECTIONS
        if (!material.mirrorMask) {
            vec2 xi = i == 0 ? SampleStbnVec2(pixel, frameCounter + 3)
                             : ptRandomPair(pixel, frameCounter, ptDim(i, 0, 40));
            halfway = tbn * SampleVisibleGGX(-worldDir * tbn, material.roughness, xi);
        }
        #endif
        vec3 dir = reflect(worldDir, halfway);
        if (dot(worldNormal, dir) < EPS || dot(geoNormal, dir) <= 0.0) continue;

        TriHit h = traceTriangleWorld(origin, dir, 1e4);

        vec3 Ls = vec3(0.0); float wS = 0.0, dS = 1e30;
        bool ssHit = false;
        #ifdef PT_SCREEN_FALLBACK
            ssHit = ptScreenTrace(origin, dir, dither, Ls, wS, dS);
        #endif

        vec3 L; float dist;
        bool entityInFront = h.hit && ssHit && wS > 0.5 && dS < h.t - 0.5;

        if (h.hit && !entityInFront) {
            dist = h.t;
            if (!ptScreenRadiance(h.position, h.normal, L)) {
                vec3 albedo = ptToRec2020(h.color);
                vec3 E = ptVertexDirect(h.position, h.normal, h.normal, true, h.skyAccess, pixel, i, 1)
                       + ConvolvedReconstructSH3(global.skySH, h.normal) * cube(h.skyAccess);
                #ifdef PT_KEEP_MIN_AMBIENT
                    E += ptMinAmbient();
                #endif
                L = albedo * E + albedo * h.rawEmission * PT_EMISSION_STRENGTH;
            }
            L *= h.transmittance;
        } else if (entityInFront) {
            L = Ls;
            dist = dS;
        } else {
            float exitY = origin.y + dir.y * h.t;
            bool  top   = h.exitedVolume && exitY >= float(traceVoxelHalf.y) - 0.01;
            float gate  = top ? 1.0 : smoothstep(0.3, 0.7, skylight);
            L    = ptSpecularMiss(worldPos, dir, gate, dither) * h.transmittance;
            dist = FP16_MAX;
            if (ssHit) { L = mix(L, Ls, wS); dist = dS; }
        }

        sum     += L;
        distSum += min(dist, FP16_MAX);
    }

    float inv = 1.0 / float(samples);
    return vec4(sum * inv, distSum * inv);
}

#endif
