// AT: Modified based on https://github.com/GarrettGunnell/Shell-Texturing/blob/main/Assets/Shell.shader, 
// basically only taking half of their vertex shader for blowing up the mesh.
// Noise is swapped out from their hash function to Voronoi noise for added stylization / animation

Shader "Custom/King"
{
	SubShader
    {
        Tags { "RenderType"="Opaque" "PerformanceChecks"="False" }
        LOD 100

		Pass {
			Cull Off

			Name "FORWARD"

			Tags {
				"LightMode" = "ForwardBase"
			}

			CGPROGRAM
			
			#pragma vertex vp
			#pragma fragment fp

			#pragma multi_compile_fwdbase // see https://docs.unity3d.com/Manual/SL-MultipleProgramVariants.html
            #pragma multi_compile_fog

			#include "UnityPBSLighting.cginc"
            #include "AutoLight.cginc"

			#include "../Helpers/Voronoi.cginc"
			#include "../Helpers/Hash.cginc"
			#include "../Helpers/Matrix.cginc"

			struct VertexData {
				float4 vertex : POSITION;
				float3 normal : NORMAL;
				float3 tangent : TANGENT;
				float2 uv : TEXCOORD0;
			};

			/* All v2f buffers are linearly interpolated, meaning normalization is lost in the process! */
			struct VertexOutputForwardBase {
				float4 pos : SV_POSITION;
				float3 uvh : TEXCOORD0; // uv | shellHeight
				float4 worldPos : TEXCOORD1; // world pos | light x

				/* Note directions are *linearly* interpolated meaning they lose magnitude in the fragment shader*/
				float4 worldTangent : TEXCOORD2; // world pos | light y
				float4 worldNormal : TEXCOORD3; // world pos | light z

				/* Unity lighting, see built-in shaders for 2022.3.14, specifically VertexOutputForwardBase in UnityStandardCore.cginc */
				float4 ambientOrLightmapUV : TEXCOORD4;    // SH or Lightmap UV
				float4 eyeVec : TEXCOORD5;    // eyeVec.xyz | fogCoord
				UNITY_LIGHTING_COORDS(6, 7)   // Lighting channel + shadow channel
				// Warn: starting here the tex coord count is over the SM2.0 limit of 0~7
			};

            int _ShellIndex;
			int _ShellCount;
			float _ShellLength; /* In world space */
			float _ShellDroop;
			sampler2D _SpikeHeightMap;
			float3 _BodyColor;
			float _EyeGlow;
			float3 _SpikeTipColor;
			float _SpikeDensity;
			float _SpikeCutoffMin;
			float _SpikeCutoffMax;
			float _ShellSpecularSharpness;
			float _ShellSpecularAmount;
			float _SpikeShapeStylizationFactor;
			float _SpikeDroopStylizationFactor;
			float _SpikeShadowSmoothnessFactor;
			float _AnimationTime;

			//https://docs.unity3d.com/Manual/SL-VertexProgramInputs.html
			VertexOutputForwardBase vp(VertexData v) {
				VertexOutputForwardBase i;
   				UNITY_INITIALIZE_OUTPUT(VertexOutputForwardBase, i);
				
                i.uvh.xy = v.uv;

				float4 maxShellHeight = tex2Dlod(_SpikeHeightMap, float4(v.uv, 0, 0));
				float spikeT = (float)_ShellIndex / (float)_ShellCount;
				float shellHeight = spikeT * maxShellHeight.r + 0.025; // add small bias for clipping issue
				i.uvh.z = shellHeight;

				v.vertex.xyz += v.normal.xyz * _ShellLength * shellHeight - (pow(_SpikeDroopStylizationFactor, spikeT) - 1) / (_SpikeDroopStylizationFactor - 1) * mul(unity_WorldToObject, float3(0, _ShellDroop, 0));
				i.worldPos.xyz = mul(unity_ObjectToWorld, v.vertex);

				i.worldTangent.xyz = normalize(UnityObjectToWorldDir(v.tangent));
				i.worldNormal.xyz = normalize(UnityObjectToWorldNormal(v.normal));

				// lightDir is always _WorldSpaceLightPos0.xyz for base pass!
				// float3 lightDir = _WorldSpaceLightPos0.xyz - i.worldPos.xyz * _WorldSpaceLightPos0.w;
				// #ifndef USING_DIRECTIONAL_LIGHT
				// 	lightDir = normalize(lightDir);
				// #endif
				// i.worldPos.w = lightDir.x;
				// i.worldTangent.w = lightDir.y;
				// i.worldNormal.w = lightDir.z;

                i.pos = UnityObjectToClipPos(v.vertex);

				/* Unity lighting, see built-in shaders for 2022.3.14, specifically vertForwardBase in UnityStandardCore.cginc */
				i.eyeVec.xyz = normalize(i.worldPos.xyz - _WorldSpaceCameraPos);

				// ...orig: needed for shadow
    			UNITY_TRANSFER_LIGHTING(i, v.uv);

				// inlined from VertexGIForward in UnityStandardCore.cginc, sets up global illumination based on project setting
				i.ambientOrLightmapUV = 0;
				i.ambientOrLightmapUV.rgb = ShadeSHPerVertex(i.worldNormal, i.ambientOrLightmapUV.rgb);
				
				UNITY_TRANSFER_FOG_COMBINED_WITH_EYE_VEC(i, i.pos);

				return i;
			}

			// for debug purposes only! to preview the entire mesh instead of rendering spikes via discarding
			// #define __KING_NODISCARD

			// patch shadow depth write bug by just not having body color being affected by shadowing
			// #define __KING_NO_SHADOW_ON_BODY
			float4 fp(VertexOutputForwardBase i) : SV_TARGET {

				// re-sample max height per-pixel and ditch surpassing ones
				float4 maxHeight = tex2D(_SpikeHeightMap, i.uvh.xy);
				// float4 bodyColor = tex2D(_BodyColor, i.uvh.xy);
				if (i.uvh.z > maxHeight.r) {

					if (_ShellIndex == 0) return float4(_EyeGlow, 0, 0, 0);
					
					discard;
				};

				float3 worldNormal = normalize(i.worldNormal.xyz);
				float3 worldTangent = normalize(i.worldTangent.xyz);
				// We assume that normal and tangent vectors still make sense after interpolation, and we *force* bitangent to be perpendicular to those two
				float3 worldBitangent = cross(i.worldNormal.xyz, i.worldTangent.xyz);

				// Technically we could be more precise and do worldTangent = cross(worldNormal, worldBitangent) * eitherNegativeOrPositive
				// this would make sure the normal vector is also exactly orthogonal to the normal, which could also be lost during interpolation
				// I'm skipping it cuz it doesn't feel that necessary :/
				float3x3 worldToTangentFrame = inverse(worldTangent, worldNormal, worldBitangent);

				float spikeT = (float)_ShellIndex / (float)_ShellCount;
	
			    float2 spikeUv2 = i.uvh.xy; // spikeUv.xy;
				
				float voronoi_squaredDistToCenter; // use squared distance to reduce some mult operations, since we don't actually need the accurate distance
				float voronoi_distToEdge; // this is computed via dot product so it's whatever
				float voronoi_cellIdx; // 0 ~ 1 random number based on the cell index's hash

				voronoiNoise(
					/* in params */
					spikeUv2, _SpikeDensity, _AnimationTime,
					
					/* out params */
					voronoi_squaredDistToCenter, voronoi_distToEdge, voronoi_cellIdx
				);
				
				// bool shouldNotDiscard = voronoi_distToEdge > lerp(_SpikeCutoffMin, _SpikeCutoffMax, spikeT);

				bool shouldNotDiscard = voronoi_distToEdge > lerp(_SpikeCutoffMin, _SpikeCutoffMax, pow(spikeT, _SpikeShapeStylizationFactor));

				/* */

				// This section is about finding the normal direction *out* of the fictional spike, which locally is just the radial direction
				// of the Voronoi cell the pixel is in.
			
				// Note that the two distances we already obtained from the noise function *natually* aligns with the spike's radial direction,
				// as in their gradients either point directly into or against the radial.

				// Unfortunately it's impossible to get the gradient directly, we could only get partial derivatives w.r.t. screen space X and Y

				// dist to edge increases inward, so the gradient points inward
				float2 spikeGradientScreenspace_Square = normalize(float2(ddx(voronoi_distToEdge), ddy(voronoi_distToEdge)));

				// dist to center increases outwards, so the negative gradient points inward
				float2 spikeGradientScreenspace_Round = -normalize(float2(ddx(voronoi_squaredDistToCenter), ddy(voronoi_squaredDistToCenter)));
				
				// the square gradient is more sharp as the distance is relative to each edge instead of the center point, and vice versa for round gradient
				// for stylistic control we mix these two for a toon-shading effect
				float2 spikeGradientScreenspace = lerp(spikeGradientScreenspace_Square, spikeGradientScreenspace_Round, _SpikeShadowSmoothnessFactor);

				// Use the view-to-world projection to get the gradient back to world space, only direction matters so no normalization is performed
				// - Technically we should go from 2D screen space to view space first but the axis align anyway so it's whatever :]
				// - Note that this does *not* give us the actual world vector we want, just the projection of that vector *within* world space that is
				//   parallel to the screen projection plane in world space
				float4 spikeGradientWorld = mul(UNITY_MATRIX_I_V, float4(spikeGradientScreenspace, 0, 0));

				// Use the world-to-tangent projection, similarly no normalization; also note this is 3x3
				float3 spikeGradientTangent = mul(worldToTangentFrame, spikeGradientWorld.xyz);
				
				// We want the gradient to be completely *along* the surface, so we clip out the component of the projected gradient along the normal
				// This "clipping" could be done by going *back* to world space but just ignoring the normal axis
				float3 spikeGradientWorld_Clipped = spikeGradientTangent.x * worldTangent + spikeGradientTangent.z * worldBitangent;

				// Finally we do actually want this to be a normal vector, so normalize it
				float3 spikeNormal = -normalize(spikeGradientWorld_Clipped); // <-- idk why but negation is needed, probably some handed-ness issue with Unity spaces...
				// Normal smoothing
				spikeNormal = normalize(lerp(spikeNormal, worldNormal, spikeT)); // account for upward angle of spike
				if (!shouldNotDiscard) discard;

				/* */

				/* Unity Lighting Section, see fragForwardBaseInternal in UnityStandardCore.cginc */

				// inlined from MainLight in UnityStandardCore.cginc, sets up a light object to be used later on (see FragmentGI)
				UnityLight mainLight;
				mainLight.color = _LightColor0.rgb;
    			mainLight.dir = _WorldSpaceLightPos0.xyz;
				
				/* Blinn Phong helpers */

				float3 unlit = lerp(_BodyColor.xyz, _SpikeTipColor, spikeT * spikeT * spikeT);

				float3 lightToObj = normalize(-mainLight.dir);
				float rawNDotL = -dot(lightToObj, spikeNormal);

				float3 worldCamForward = unity_CameraToWorld._m02_m12_m22;
				float3 halfway = normalize(lightToObj + worldCamForward);
				float specularT = max(-dot(spikeNormal, halfway), 0);
				float specularAmount = _ShellSpecularAmount * pow(specularT, _ShellSpecularSharpness);
				
				float nDotL = saturate(rawNDotL);

				// the sample forwardBase pass hands the GI stuff to Unity BRDF, which requires a bunch of extra parameters
				// here we just "pretend" to compute direct and indirect lighting to skip those unnecessary fluff

				// direct lighting is just Blinn Phong
				
				UNITY_LIGHT_ATTENUATION(atten, i, i.worldPos.xyz); // applies shadow attenuation
				float3 direct = nDotL 
					#ifndef __KING_NO_SHADOW_ON_BODY
					* atten
					#endif
					* (unlit);
				direct += specularAmount;
				direct *= mainLight.color;

				// inlined from UnityGI_Base in UnityGlobalIllumination.cginc as well as BRDF3_Indirect from UnityStandardBRDF.cginc
				float3 indirect = ShadeSHPerPixel(spikeNormal, i.ambientOrLightmapUV.rgb, i.worldPos.xyz) * unlit;
    			
				// depth-testing for fog, from fragForwardBaseInternal in UnityStandardCore.cginc. I'm not gonna bother testing this
				float3 color = direct + indirect;
				UNITY_EXTRACT_FOG_FROM_EYE_VEC(i);
				UNITY_APPLY_FOG(_unity_fogCoord, color.rgb);

				return float4(color, 1);
			}

			ENDCG
		}

		/** This shader is basically the same as the base pass, but with minor lighting differences. The good practice is to abstract
		    shared functions, but the #include's are acting weirdly so I will just be repeating code line by line.
		*/

		Pass {
			Cull Off

            Name "FORWARD_DELTA"
			Tags {
				"LightMode" = "ForwardAdd"
			}
			
            Blend One One // https://catlikecoding.com/unity/tutorials/rendering/part-5/

			Fog { Color (0,0,0,0) } // in additive pass fog should be black
            ZWrite Off

			CGPROGRAM
			
			#pragma vertex vp
			#pragma fragment fp

			#pragma multi_compile_fwdadd // see https://docs.unity3d.com/Manual/SL-MultipleProgramVariants.html
            #pragma multi_compile_fog

			#include "UnityPBSLighting.cginc"
            #include "AutoLight.cginc"

			#include "../Helpers/Voronoi.cginc"
			#include "../Helpers/Hash.cginc"
			#include "../Helpers/Matrix.cginc"

			struct VertexData {
				float4 vertex : POSITION;
				float3 normal : NORMAL;
				float3 tangent : TANGENT;
				float2 uv : TEXCOORD0;
			};

			/* All v2f buffers are linearly interpolated, meaning normalization is lost in the process! */
			struct VertexOutputForwardAdd {
				float4 pos : SV_POSITION;
				float3 uvh : TEXCOORD0; // uv | shellHeight
				float4 worldPos : TEXCOORD1; // world pos | light dir x

				/* Note directions are *linearly* interpolated meaning they lose magnitude in the fragment shader*/
				float4 worldTangent : TEXCOORD2; // world tangent | light dir y
				float4 worldNormal : TEXCOORD3; // world tangent | light dir z

				/* Unity lighting, see built-in shaders for 2022.3.14, specifically VertexOutputForwardBase in UnityStandardCore.cginc */
				float4 ambientOrLightmapUV : TEXCOORD4;    // SH or Lightmap UV
				float4 eyeVec : TEXCOORD5;    // eyeVec.xyz | fogCoord
				UNITY_LIGHTING_COORDS(6, 7)   // Lighting channel + shadow channel
				// Warn: starting here the tex coord count is over the SM2.0 limit of 0~7
			};

            int _ShellIndex;
			int _ShellCount;
			float _ShellLength; /* In world space */
			float _ShellDroop;
			sampler2D _SpikeHeightMap;
			float3 _BodyColor;
			float _EyeGlow;
			float3 _SpikeTipColor;
			float _SpikeDensity;
			float _SpikeCutoffMin;
			float _SpikeCutoffMax;
			float _ShellSpecularSharpness;
			float _ShellSpecularAmount;
			float _SpikeShapeStylizationFactor;
			float _SpikeDroopStylizationFactor;
			float _SpikeShadowSmoothnessFactor;
			float _AnimationTime;
			
			// from UnityStandardCore.cginc
			float3 NormalizePerPixelNormal (float3 n)
			{
				#if (SHADER_TARGET < 30) || UNITY_STANDARD_SIMPLE
					return n;
				#else
					return normalize((float3)n); // takes float to avoid overflow
				#endif
			}

			//https://docs.unity3d.com/Manual/SL-VertexProgramInputs.html
			VertexOutputForwardAdd vp(VertexData v) {
				VertexOutputForwardAdd i;
   				UNITY_INITIALIZE_OUTPUT(VertexOutputForwardAdd, i);
				
                i.uvh.xy = v.uv;

				float4 maxShellHeight = tex2Dlod(_SpikeHeightMap, float4(v.uv, 0, 0));
				float spikeT = (float)_ShellIndex / (float)_ShellCount;
				float shellHeight = spikeT * maxShellHeight.r + 0.025; // add small bias for clipping issue
				i.uvh.z = shellHeight;

				v.vertex.xyz += v.normal.xyz * _ShellLength * shellHeight - (pow(_SpikeDroopStylizationFactor, spikeT) - 1) / (_SpikeDroopStylizationFactor - 1) * mul(unity_WorldToObject, float3(0, _ShellDroop, 0));
				i.worldPos.xyz = mul(unity_ObjectToWorld, v.vertex);

				i.worldTangent.xyz = normalize(UnityObjectToWorldDir(v.tangent));
				i.worldNormal.xyz = normalize(UnityObjectToWorldNormal(v.normal));

				// see vertForwardAdd from UnityStandardCore.cginc
				float3 lightDir = _WorldSpaceLightPos0.xyz - i.worldPos.xyz * _WorldSpaceLightPos0.w;
				#ifndef USING_DIRECTIONAL_LIGHT
					lightDir = normalize(lightDir);
				#endif
				i.worldPos.w = lightDir.x;
				i.worldTangent.w = lightDir.y;
				i.worldNormal.w = lightDir.z;

                i.pos = UnityObjectToClipPos(v.vertex);

				/* Unity lighting, see built-in shaders for 2022.3.14, specifically vertForwardBase in UnityStandardCore.cginc */
				i.eyeVec.xyz = normalize(i.worldPos.xyz - _WorldSpaceCameraPos);

				// ...orig: needed for shadow
    			UNITY_TRANSFER_LIGHTING(i, v.uv);

				return i;
			}

			// for debug purposes only! to preview the entire mesh instead of rendering spikes via discarding
			// #define __KING_NODISCARD

			// patch shadow depth write bug by just not having body color being affected by shadowing
			// #define __KING_NO_SHADOW_ON_BODY
			float4 fp(VertexOutputForwardAdd i) : SV_TARGET {
				// re-sample max height per-pixel and ditch surpassing ones
				float4 maxHeight = tex2D(_SpikeHeightMap, i.uvh.xy);
				// float4 bodyColor = tex2D(_BodyColor, i.uvh.xy);
				if (i.uvh.z > maxHeight.r) {

					if (_ShellIndex == 0) return float4(_EyeGlow, 0, 0, 0);
					
					discard;
				};

				float3 worldNormal = normalize(i.worldNormal.xyz);
				float3 worldTangent = normalize(i.worldTangent.xyz);
				// We assume that normal and tangent vectors still make sense after interpolation, and we *force* bitangent to be perpendicular to those two
				float3 worldBitangent = cross(i.worldNormal.xyz, i.worldTangent.xyz);

				// Technically we could be more precise and do worldTangent = cross(worldNormal, worldBitangent) * eitherNegativeOrPositive
				// this would make sure the normal vector is also exactly orthogonal to the normal, which could also be lost during interpolation
				// I'm skipping it cuz it doesn't feel that necessary :/
				float3x3 worldToTangentFrame = inverse(worldTangent, worldNormal, worldBitangent);

				float spikeT = (float)_ShellIndex / (float)_ShellCount;

				// From old spike masking code...
				// float4 spikeUv = _SpikeUv.Sample(point_clamp_sampler, i.uv);
				// if (spikeUv.z > 0.1) discard;

				float2 spikeUv2 = i.uvh.xy; // spikeUv.xy;

				// float spikeDensity = 20;
				// float2 spikeCenter = floor(spikeUv2 * spikeDensity) + 0.5;
				// float2 spikeDistance = spikeUv2 * spikeDensity - spikeCenter;

				float voronoi_squaredDistToCenter; // use squared distance to reduce some mult operations, since we don't actually need the accurate distance
				float voronoi_distToEdge; // this is computed via dot product so it's whatever
				float voronoi_cellIdx; // 0 ~ 1 random number based on the cell index's hash

				voronoiNoise(
					/* in params */
					spikeUv2, _SpikeDensity, _AnimationTime,
					
					/* out params */
					voronoi_squaredDistToCenter, voronoi_distToEdge, voronoi_cellIdx
				);

				// bool shouldNotDiscard = voronoi_distToEdge > lerp(_SpikeCutoffMin, _SpikeCutoffMax, spikeT);

				bool shouldNotDiscard = voronoi_distToEdge > lerp(_SpikeCutoffMin, _SpikeCutoffMax, pow(spikeT, _SpikeShapeStylizationFactor));

				/* */

				// This section is about finding the normal direction *out* of the fictional spike, which locally is just the radial direction
				// of the Voronoi cell the pixel is in.

				// Note that the two distances we already obtained from the noise function *natually* aligns with the spike's radial direction,
				// as in their gradients either point directly into or against the radial.

				// Unfortunately it's impossible to get the gradient directly, we could only get partial derivatives w.r.t. screen space X and Y

				// dist to edge increases inward, so the gradient points inward
				float2 spikeGradientScreenspace_Square = normalize(float2(ddx(voronoi_distToEdge), ddy(voronoi_distToEdge)));

				// dist to center increases outwards, so the negative gradient points inward
				float2 spikeGradientScreenspace_Round = -normalize(float2(ddx(voronoi_squaredDistToCenter), ddy(voronoi_squaredDistToCenter)));

				// the square gradient is more sharp as the distance is relative to each edge instead of the center point, and vice versa for round gradient
				// for stylistic control we mix these two for a toon-shading effect
				float2 spikeGradientScreenspace = lerp(spikeGradientScreenspace_Square, spikeGradientScreenspace_Round, _SpikeShadowSmoothnessFactor);

				// Use the view-to-world projection to get the gradient back to world space, only direction matters so no normalization is performed
				// - Technically we should go from 2D screen space to view space first but the axis align anyway so it's whatever :]
				// - Note that this does *not* give us the actual world vector we want, just the projection of that vector *within* world space that is
				//   parallel to the screen projection plane in world space
				float4 spikeGradientWorld = mul(UNITY_MATRIX_I_V, float4(spikeGradientScreenspace, 0, 0));

				// Use the world-to-tangent projection, similarly no normalization; also note this is 3x3
				float3 spikeGradientTangent = mul(worldToTangentFrame, spikeGradientWorld.xyz);

				// We want the gradient to be completely *along* the surface, so we clip out the component of the projected gradient along the normal
				// This "clipping" could be done by going *back* to world space but just ignoring the normal axis
				float3 spikeGradientWorld_Clipped = spikeGradientTangent.x * worldTangent + spikeGradientTangent.z * worldBitangent;

				// Finally we do actually want this to be a normal vector, so normalize it
				float3 spikeNormal = -normalize(spikeGradientWorld_Clipped); // <-- idk why but negation is needed, probably some handed-ness issue with Unity spaces...
				// Normal smoothing
				spikeNormal = normalize(lerp(spikeNormal, worldNormal, spikeT)); // account for upward angle of spike
				if (!shouldNotDiscard) discard;

				/* */

				/* Unity Lighting Section, see fragForwardBaseInternal in UnityStandardCore.cginc */

				// inlined from MainLight in UnityStandardCore.cginc, sets up a light object to be used later on (see FragmentGI)
				UnityLight mainLight;
				mainLight.color = _LightColor0.rgb;
				mainLight.dir = normalize(float3(i.worldPos.w, i.worldTangent.w, i.worldNormal.w));
				#ifndef USING_DIRECTIONAL_LIGHT
					mainLight.dir = NormalizePerPixelNormal(mainLight.dir);
				#endif

				/* Blinn Phong helpers */

				float3 unlit = lerp(_BodyColor.xyz, _SpikeTipColor, spikeT * spikeT * spikeT);

				float3 lightToObj = -mainLight.dir;
				float rawNDotL = -dot(lightToObj, spikeNormal);

				float3 worldCamForward = unity_CameraToWorld._m02_m12_m22;
				float3 halfway = normalize(lightToObj + worldCamForward);
				float specularT = max(-dot(spikeNormal, halfway), 0);
				float specularAmount = _ShellSpecularAmount * pow(specularT, _ShellSpecularSharpness);

				float nDotL = saturate(rawNDotL);

				// the sample forwardBase pass hands the GI stuff to Unity BRDF, which requires a bunch of extra parameters
				// here we just "pretend" to compute direct and indirect lighting to skip those unnecessary fluff

				// direct lighting is just Blinn Phong

				UNITY_LIGHT_ATTENUATION(atten, i, i.worldPos.xyz); // applies shadow attenuation
				float3 direct = nDotL 
					#ifndef __KING_NO_SHADOW_ON_BODY
					* atten
					#endif
					* unlit;
				direct += specularAmount;
				direct *= mainLight.color.rgb;

				// inlined from UnityGI_Base in UnityGlobalIllumination.cginc as well as BRDF3_Indirect from UnityStandardBRDF.cginc
				float3 indirect = ShadeSHPerPixel(spikeNormal, i.ambientOrLightmapUV.rgb, i.worldPos.xyz) * unlit;

				// depth-testing for fog, from fragForwardBaseInternal in UnityStandardCore.cginc. I'm not gonna bother testing this
				float3 color = direct + indirect;
				UNITY_EXTRACT_FOG_FROM_EYE_VEC(i);
				UNITY_APPLY_FOG(_unity_fogCoord, color.rgb);

				return float4(color, 1);
			}

			ENDCG
		}

		// See https://catlikecoding.com/unity/tutorials/rendering/part-7/ for more help
		//  Shadow rendering pass, taken from standard shader with as little modifications as possible to preserve compatibility
        Pass {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

			Cull Off

            CGPROGRAM
            #pragma target 3.0

            // -------------------------------------


            #pragma shader_feature_local _ _ALPHATEST_ON _ALPHABLEND_ON _ALPHAPREMULTIPLY_ON
            #pragma shader_feature_local _METALLICGLOSSMAP
            #pragma shader_feature_local_fragment _SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
            #pragma shader_feature_local _PARALLAXMAP
            #pragma multi_compile_shadowcaster
            // #pragma multi_compile_instancing
            // Uncomment the following line to enable dithering LOD crossfade. Note: there are more in the file to uncomment for other passes.
            //#pragma multi_compile _ LOD_FADE_CROSSFADE

            #pragma vertex vp
            #pragma fragment fp

            #include "UnityStandardShadow.cginc"
			
			#include "../Helpers/Voronoi.cginc"
			#include "../Helpers/Hash.cginc"
			#include "../Helpers/Matrix.cginc"

			struct VertexData {
				float4 vertex : POSITION;
				float3 normal : NORMAL;
				float2 uv : TEXCOORD0;
				float3 tangent : TANGENT;
			};
			
			struct VertexOutputShadowCaster {
				float4 pos : SV_POSITION;
				float3 uvh : TEXCOORD0; // uv | shell height
				float3 worldPos : TEXCOORD1;
				/* Note directions are *linearly* interpolated meaning they lose magnitude in the fragment shader*/
				float3 worldTangent : TEXCOORD2;
				float3 worldNormal : TEXCOORD3;
			};

			int _ShellIndex;
			int _ShellCount;
			float _ShellLength; /* In world space */
			// float _ShellDistanceAttenuation; /* This is the exponent on determining how far to push the shell outwards, which biases shells downwards or upwards towards the minimum/maximum distance covered */
			float _ShellDroop;
			sampler2D _SpikeHeightMap;
			// float _ShellHeightMapCutoff;
			// SamplerState point_clamp_sampler; /* https://docs.unity3d.com/Manual/SL-SamplerStates.html */
			// float3 _BodyColor;
			// float _EyeGlow;
			// float3 _SpikeTipColor;
			float _SpikeDensity;
			float _SpikeCutoffMin;
			float _SpikeCutoffMax;
			// float _ShellSpecularSharpness;
			// float _ShellSpecularAmount;
			float _SpikeShapeStylizationFactor;
			float _SpikeDroopStylizationFactor;
			// float _SpikeShadowSmoothnessFactor;
			float _AnimationTime;

			VertexOutputShadowCaster vp (VertexData v)
			{
				VertexOutputShadowCaster i;
				
                i.uvh.xy = v.uv;

				float4 maxShellHeight = tex2Dlod(_SpikeHeightMap, float4(v.uv, 0, 0));
				float spikeT = (float)_ShellIndex / (float)_ShellCount;
				float shellHeight = spikeT * maxShellHeight.r + 0.025; // add small bias for clipping issue
				i.uvh.z = shellHeight;

				v.vertex.xyz += v.normal.xyz * _ShellLength * shellHeight - (pow(_SpikeDroopStylizationFactor, spikeT) - 1) / (_SpikeDroopStylizationFactor - 1) * mul(unity_WorldToObject, float3(0, _ShellDroop, 0));
				
				i.worldPos.xyz = mul(unity_ObjectToWorld, v.vertex);
				i.worldNormal.xyz = normalize(UnityObjectToWorldNormal(v.normal));
				i.worldTangent.xyz = normalize(UnityObjectToWorldDir(v.tangent));

				TRANSFER_SHADOW_CASTER_NOPOS(i, i.pos)

				return i;
			}

			float4 fp(VertexOutputShadowCaster i) : SV_TARGET {
				// re-sample max height per-pixel and ditch surpassing ones
				float4 maxHeight = tex2D(_SpikeHeightMap, i.uvh.xy);
				if (i.uvh.z > maxHeight.r) {

					if (_ShellIndex == 0) SHADOW_CASTER_FRAGMENT(i); // return float4(_EyeGlow, 0, 0, 0);
					
					discard;
				};

				float3 worldNormal = normalize(i.worldNormal.xyz);
				float3 worldTangent = normalize(i.worldTangent.xyz);
				// We assume that normal and tangent vectors still make sense after interpolation, and we *force* bitangent to be perpendicular to those two
				float3 worldBitangent = cross(i.worldNormal.xyz, i.worldTangent.xyz);

				// Technically we could be more precise and do worldTangent = cross(worldNormal, worldBitangent) * eitherNegativeOrPositive
				// this would make sure the normal vector is also exactly orthogonal to the normal, which could also be lost during interpolation
				// I'm skipping it cuz it doesn't feel that necessary :/
				float3x3 worldToTangentFrame = inverse(worldTangent, worldNormal, worldBitangent);
				float3 worldCamToPos = normalize(i.worldPos.xyz - _WorldSpaceCameraPos);

				float spikeT = (float)_ShellIndex / (float)_ShellCount;
			    float2 spikeUv2 = i.uvh.xy; // spikeUv.xy;

				float voronoi_squaredDistToCenter; // use squared distance to reduce some mult operations, since we don't actually need the accurate distance
				float voronoi_distToEdge; // this is computed via dot product so it's whatever
				float voronoi_cellIdx; // 0 ~ 1 random number based on the cell index's hash

				voronoiNoise(
					/* in params */
					spikeUv2, _SpikeDensity, _AnimationTime,
					/* out params */
					voronoi_squaredDistToCenter, voronoi_distToEdge, voronoi_cellIdx
				);
				
				bool shouldNotDiscard = voronoi_distToEdge > lerp(_SpikeCutoffMin, _SpikeCutoffMax, pow(spikeT, _SpikeShapeStylizationFactor));
				if (!shouldNotDiscard) discard;

				SHADOW_CASTER_FRAGMENT(i);
			}

            ENDCG
        }
	}

    FallBack "Standard"
}