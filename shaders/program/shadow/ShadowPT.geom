#include "/lib/Utility.glsl"

layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

// dari Shadow.vert (Rev)
in vec2 vsTexCoord[];
in vec3 vsVectorData[];
flat in uint vsIsWater[];
// ke Shadow.frag (Rev), nama asli
out vec2 texCoord;
out vec3 vectorData;
flat out uint isWater;

// varying trace
in vec2  vTexcoord[];
in vec4  vGlcolor[];
in vec3  vTracePlayerPos[];
in vec4  vTraceSkyLight[];
in float vTraceEmission[];
in vec3  vTraceBlockCenter[];
flat in uint vTracePointLight[];
flat in uint vTraceValid[];
flat in int  vTraceQuadMarker[];
flat in uint vTraceTerrain[];

uniform sampler2D gtexture;
uniform sampler2D specular;
uniform int gtextureId;
uniform vec3 cameraPosition;

#define TRACE_STAGE_TERRAIN
#include "/lib/pt/PTBuffers.glsl"
#include "/lib/pt/PTVoxelize.glsl"

void main() {
    if (vTracePointLight[0] != 0u) {
        ivec3 cell = ivec3(floor(vTracePlayerPos[0])) + traceVoxelHalf;
        uint level = vTracePointLight[0] - 1u;
        if (level > 0u && traceVoxelInside(cell)) {
            uint owner = flattenTraceVoxel(cell);
            uint old = atomicOr(emissionBlockShape[owner], 0x80000000u);
            if ((old & 0x80000000u) == 0u) {
                uint idx = atomicAdd(pointLightCount, 1u);
                if (idx < pointLightCapacity)
                    pointLights[idx] = vec4(vec3(cell - traceVoxelHalf) + 0.5, float(level) / 15.0);
            }
        }
        return;
    }
    if (vTraceTerrain[0] == 1u) writeTraceMeshTriangle();

    for (int i = 0; i < 3; ++i) {
        texCoord   = vsTexCoord[i];
        vectorData = vsVectorData[i];
        isWater    = vsIsWater[i];
        gl_Position = gl_in[i].gl_Position;
        EmitVertex();
    }
    EndPrimitive();
}
