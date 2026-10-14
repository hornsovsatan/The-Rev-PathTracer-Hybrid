/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2026 HaringPro
	Apache License 2.0

--------------------------------------------------------------------------------
*/

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

out vec2 vsTexCoord;
out vec3 vsVectorData; // Minecraft position in water, vertColor in other materials

flat out uint vsIsWater;

out vec2  vTexcoord;
out vec4  vGlcolor;
out vec3  vTracePlayerPos;
out vec4  vTraceSkyLight;
out float vTraceEmission;
out vec3  vTraceBlockCenter;
flat out uint vTracePointLight;
flat out uint vTraceValid;
flat out int  vTraceQuadMarker;
flat out uint vTraceTerrain;

in vec4 at_midBlock;
uniform int renderStage;
uniform bool hasCeiling;
uniform bool hasSkylight;
uniform sampler2D gtexture;

bool ptIsTerrain() {
    return renderStage == MC_RENDER_STAGE_TERRAIN_SOLID ||
           renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED ||
           renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT ||
           renderStage == MC_RENDER_STAGE_TERRAIN_TRANSLUCENT ||
           renderStage == MC_RENDER_STAGE_TRIPWIRE;
}

//======// Attribute //===========================================================================//

in vec4 mc_Entity;
in vec4 at_tangent;

//======// Uniform //=============================================================================//

uniform vec3 cameraPosition;
uniform mat4 shadowModelViewInverse;

uniform int blockEntityId;

//======// Function //============================================================================//

#include "/lib/lighting/shadow/Common.glsl"

//======// Main //================================================================================//
void main() {
    vTraceValid = 0u; vTracePointLight = 0u; vTraceTerrain = 0u; vTraceQuadMarker = 1;
    vTexcoord = vec2(gl_TextureMatrix[0] * gl_MultiTexCoord0);
    vGlcolor  = gl_Color;
    vec3 ptPlayer = (shadowModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz
                  + fract(cameraPosition);
    vTracePlayerPos = ptPlayer;
    bool terr = ptIsTerrain();
    vTraceTerrain = terr ? 1u : 0u;
    vTraceBlockCenter = ptPlayer + (terr ? at_midBlock.xyz / 64.0 : vec3(0.0));
    vTraceEmission = terr ? clamp(at_midBlock.w / 15.0, 0.0, 1.0) : 0.0;
    int ptId = int(mc_Entity.x);
    vTracePointLight = (terr && ptId >= 32000 && ptId <= 32015) ? uint(ptId - 31999) : 0u;
    float sky = 0.0;
    if (!hasCeiling && hasSkylight) {
        float s = (gl_TextureMatrix[1] * gl_MultiTexCoord1).y;
        sky = clamp((s - 0.03125) / 0.9375, 0.0, 1.0);
    }
    vTraceSkyLight = vec4(vec3(sky), sky);
    vTraceValid = (textureLod(gtexture, vTexcoord, 0.0).a * gl_Color.a >= 0.1) ? 1u : 0u;
    vTraceQuadMarker = terr ? int(mc_Entity.y) : 1;

	if (blockEntityId == 10030) {
		gl_Position = vec4(-1.0);
		return;
	}

	#ifdef SHADOW_BACKFACE_CULLING
		if ((gl_NormalMatrix * gl_Normal).z < 0.0) {
			gl_Position = vec4(-1.0);
			return;
		}
	#endif

	vsTexCoord = vec2(gl_TextureMatrix[0] * gl_MultiTexCoord0);

	vec3 viewPos = transMAD(gl_ModelViewMatrix, gl_Vertex.xyz);

	vsIsWater = 0u;
	if (int(mc_Entity.x) == 10003) {
		vsIsWater = 1u;
		vsVectorData = transMAD(shadowModelViewInverse, viewPos) + cameraPosition;
	} else {
		vsVectorData = gl_Color.rgb;
	}

	gl_Position.xyz = DistortShadowSpace(projMAD(gl_ProjectionMatrix, viewPos));
	gl_Position.w = 1.0;
}
