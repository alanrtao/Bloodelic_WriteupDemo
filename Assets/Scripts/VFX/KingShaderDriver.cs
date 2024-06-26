// Modified based on https://github.com/GarrettGunnell/Shell-Texturing/blob/main/Assets/SimpleShell.cs

using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using System;
using System.Linq;
using Cinemachine;
using Unity.Collections;

/* Burst jobs */
using Unity.Burst;
using Unity.Jobs;
using Unity.Mathematics;
using static Unity.Mathematics.math;
using UnityEngine.Jobs;

#pragma warning disable CS3009

public class KingShaderDriver : MonoBehaviour
{
#region References
    [Header("References")]

    [SerializeField] private Transform bodyMesh;
    [SerializeField] private Material shellMaterialPrototype;
#endregion

    [SerializeField]
    private bool shellsCastShadows = false;

#region Shell Renderer Static Parameters
    [Header("Shell Renderer Static Parameters")]

    [SerializeField, Tooltip("Update stylization parameters per frame; DO NOT SET IN SHIPPED GAME!")]
    private bool updateStatics = true;

    // TODO: SaveDuringPlay doesn't actually work???? :/

    // These variables and what they do are explained on the shader code side of things
    // You can see below (line 70) which shader uniforms match up with these variables
    [SerializeField, SaveDuringPlay, Range(1, 256)]
    private int shellCount = 16;

    [SerializeField, SaveDuringPlay, Range(0.0f, 1.0f)]
    private float shellLength = 0.15f;

    [SerializeField, SaveDuringPlay, Range(1, 50)]
    private float spikeDensity;

    [SerializeField, SaveDuringPlay, Range(0.0f, 0.5f), Tooltip("Higher value = skinnier spike base")]
    private float spikeCutoffMin;

    [SerializeField, SaveDuringPlay, Range(0.0f, 1.0f), Tooltip("Higher value = skinnier spike tip")]
    private float spikeCutoffMax;

    [SerializeField, SaveDuringPlay, Range(0.0f, 3.0f), Tooltip("Higher value = puffier spikes")]
    private float spikeShapeStylizationFactor;
    
    [SerializeField, SaveDuringPlay, Range(0.0f, 3.0f), Tooltip("Higher value = bendable spikes")]
    private float spikeDroopStylizationFactor;

    [SerializeField, SaveDuringPlay, Range(0.0f, 1.0f), Tooltip("Higher value = smoother lighting on spikes")]
    private float spikeShadowSmoothnessFactor;

    [SerializeField, SaveDuringPlay]
    private Texture2D spikeHeightMap;

    // [SerializeField, SaveDuringPlay, Range(0.01f, 3.0f)]
    // private float distanceAttenuation = 1.0f;

    //[SerializeField, SaveDuringPlay, Range(0.0f, 10.0f)]
    //private float thickness = 1.0f;

    [SerializeField, SaveDuringPlay, Range(0.0f, 0.1f)]
    private float shellDroop = 1.0f;

    [SerializeField, SaveDuringPlay, Range(0.0f, 100.0f)]
    private float shellSpecularSharpness;

    [SerializeField, SaveDuringPlay, Range(0.0f, 50.0f)]
    private float shellSpecularAmount;

    [SerializeField, SaveDuringPlay, Range(0.1f, 20.0f)]
    private float eyeGlow;
    
    [SerializeField, SaveDuringPlay]
    private Color bodyColor;

    [SerializeField, SaveDuringPlay]
    private Color spikeTipColor;

    [SerializeField, SaveDuringPlay, Range(0.1f, 10.0f)]
    private float animationSpeed;

    #endregion

#region Shell Renderer Dynamic Parameters
    [Header("Shell Renderer Dynamic Parameters")]

    private float animationTime = 0.0f;

    public bool viewShells = true;
#endregion

#region Shell Animation Parameters

    [Header("Shell Animation Parameters")] [SerializeField, SaveDuringPlay]
    private int animationNormalizedLayerCount = 10;
    private int shellCountPerNormalizedLayer => shellCount / animationNormalizedLayerCount;
    
    [SerializeField, SaveDuringPlay, Range(0.1f, 100.0f)]
    private float positionResponsiveness;

    [SerializeField, SaveDuringPlay, Range(0.1f, 100.0f)]
    private float rotationResponsiveness;
    
    private TransformAccessArray shellTransformAccesses; // NativeArray that optimizes Transform object access, see animation job definition below
    #endregion

    private Material shellMaterial;
    private Transform[] shellTransforms;
    private MeshRenderer[] shellRenderers;
    private JobHandle currentAnimationJob;
    private JobHandle currentBufferSyncJob;

    NativeArray<int> animationIndices;
    NativeArray<float3> shellPositions;
    NativeArray<quaternion> shellRotations;

    void OnEnable() {
        shellMaterial = new Material(shellMaterialPrototype);
        shellTransforms = new Transform[shellCount];
        shellRenderers = new MeshRenderer[shellCount];

        if (shellsCastShadows) {
            bodyMesh.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        } else {
            bodyMesh.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.ShadowsOnly;
        }
        
        for (int i = 0; i < shellCount; ++i) {
            GameObject currShell = new("__shell_temp_obj_" + i.ToString(), typeof(MeshFilter), typeof(MeshRenderer));
            shellTransforms[i] = currShell.transform;

            currShell.transform.position = bodyMesh.position;
            currShell.transform.rotation = bodyMesh.rotation;
            currShell.GetComponent<MeshFilter>().mesh = bodyMesh.GetComponent<MeshFilter>().mesh;

            MeshRenderer currRend = currShell.GetComponent<MeshRenderer>();
            currRend.material = shellMaterial;

            if (shellsCastShadows) {
                currRend.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.On;
            } else {            
                currRend.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            }

            shellRenderers[i] = currRend;
        }

        shellTransformAccesses = new TransformAccessArray(shellTransforms);

        // memory management taken from https://catlikecoding.com/unity/tutorials/basics/jobs/
        shellPositions = new NativeArray<float3>(shellCount, Allocator.Persistent);
        shellRotations = new NativeArray<quaternion>(shellCount, Allocator.Persistent);
        animationIndices = new NativeArray<int>(shellCount, Allocator.Persistent);

        for (int i = 0; i < shellCount; ++i)
        {
            int excess = i % shellCountPerNormalizedLayer;
            if (excess == 0)
            {
                animationIndices[i] = max(0, i - shellCountPerNormalizedLayer);
            }
            else
            {
                animationIndices[i] = i - excess; // guaranteed >= 0
            }
        }
        
        // Debug.Log(string.Join(", ", animationIndices));

        UpdateStaticParameters();
    }

    void FixedUpdate() { // AT: optionally use Update instead
        if (updateStatics) { 
            UpdateStaticParameters();
        }
        UpdateDynamicParameters(Time.fixedDeltaTime);

        SyncAnimationBufferJob fetchTransforms = new()
        {
            anchorPos = bodyMesh.transform.position,
            anchorRotation = bodyMesh.transform.rotation,
            Count = shellCount,
            lastPosition = shellPositions,
            lastRotation = shellRotations,
        };

        ShellAnimationJob anim = new()
        {
            prevIndices = animationIndices,
            lastPosition = shellPositions,
            lastRotation = shellRotations,
            positionLerpFactor = Mathf.Clamp01(positionResponsiveness * Time.fixedDeltaTime),
            rotationLerpFactor = Mathf.Clamp01(rotationResponsiveness * Time.fixedDeltaTime),
            scale = bodyMesh.transform.localScale,
        };

        currentBufferSyncJob = fetchTransforms.Schedule(shellTransformAccesses);
        currentAnimationJob = anim.Schedule(shellTransformAccesses, currentBufferSyncJob);
        currentAnimationJob.Complete();
    }

    void OnDisable() {
        shellTransformAccesses.Dispose();
        animationIndices.Dispose();
        shellPositions.Dispose();
        shellRotations.Dispose();

        // AT: technically not needed as shells are not saved

        //for (int i = 0; i < shellTransforms.Length; ++i)
        //{
        //    Destroy(shellRenderers[i].gameObject);
        //}
        //shellTransforms = null;
        //shellRenderers = null;
    }

    void UpdateStaticParameters()
    {
        ForEachShellDo((Transform shellTransform, MeshRenderer shellRenderer, int idx) =>
        {
            shellRenderer.material
                .SetIntParam(ShaderIDs.ShellCount, shellCount)
                .SetIntParam(ShaderIDs.ShellIndex, idx)
                .SetFloatParam(ShaderIDs.ShellLength, shellLength)
                //.SetFloatParam("_Density", density)
                // .SetFloatParam("_Thickness", thickness)
                // .SetFloatParam("_Attenuation", occlusionAttenuation)
                // .SetFloatParam("_ShellDistanceAttenuation", distanceAttenuation)
                .SetFloatParam(ShaderIDs.ShellDroop, shellDroop)
                //.SetFloatParam("_OcclusionBias", occlusionBias)
                //.SetFloatParam("_NoiseMin", noiseMin)
                //.SetFloatParam("_NoiseMax", noiseMax)
                .SetFloatParam(ShaderIDs.SpikeDensity, spikeDensity)
                .SetFloatParam(ShaderIDs.SpikeCutoffMin, spikeCutoffMin)
                .SetFloatParam(ShaderIDs.SpikeCutoffMax, spikeCutoffMax)
                .SetFloatParam(ShaderIDs.SpikeShapeStylizationFactor, spikeShapeStylizationFactor)
                .SetFloatParam(ShaderIDs.SpikeDroopStylizationFactor, spikeDroopStylizationFactor)
                .SetFloatParam(ShaderIDs.ShellSpecularSharpness, shellSpecularSharpness)
                .SetFloatParam(ShaderIDs.ShellSpecularAmount, shellSpecularAmount)
                .SetFloatParam(ShaderIDs.SpikeShadowSmoothnessFactor, spikeShadowSmoothnessFactor)
                .SetFloatParam(ShaderIDs.EyeGlow, eyeGlow)
                .SetVectorParam(ShaderIDs.SpikeTipColor, spikeTipColor)
                .SetVectorParam(ShaderIDs.BodyColor, bodyColor)
                .SetTextureParam(ShaderIDs.SpikeHeightMap, spikeHeightMap);
        });
    }

    void UpdateDynamicParameters(float deltaTime)
    {
        animationTime += (Mathf.Sin(Time.time) + 2) / 3 * deltaTime * animationSpeed;

        if (animationTime > Mathf.PI * 2)
        {
            animationTime = 0;
        }

        ForEachShellDo((Transform shellTransform, MeshRenderer shellRenderer, int idx) =>
        {
            shellRenderer.material
                .SetFloatParam(ShaderIDs.AnimationTime, animationTime);

            shellRenderer.enabled = viewShells;
        });
    }

    [BurstCompile(FloatPrecision.Standard, FloatMode.Fast)]
    struct ShellAnimationJob : IJobParallelForTransform // https://realerichu.medium.com/improve-performance-with-c-job-system-and-burst-compiler-in-unity-eecd2a69dbc8
    {
        [ReadOnly] public NativeArray<int> prevIndices;
        [ReadOnly] public NativeArray<float3> lastPosition;
        [ReadOnly] public NativeArray<quaternion> lastRotation;
        [ReadOnly] public float positionLerpFactor;
        [ReadOnly] public float rotationLerpFactor;
        [ReadOnly] public float3 scale;
        
        public void Execute(int index, TransformAccess transform)
        {
            transform.SetPositionAndRotation(
                lerp(lastPosition[index], lastPosition[prevIndices[index]], positionLerpFactor),
                slerp(lastRotation[index], lastRotation[prevIndices[index]], rotationLerpFactor)
            );
            transform.localScale = scale;
        }
    }
    
    [BurstCompile(FloatPrecision.Medium, FloatMode.Fast)]
    struct SyncAnimationBufferJob : IJobParallelForTransform
    {
        [ReadOnly] public float3 anchorPos;
        [ReadOnly] public quaternion anchorRotation;
        [ReadOnly] public int Count;
        [WriteOnly, NativeDisableParallelForRestriction] public NativeArray<float3> lastPosition;
        [WriteOnly, NativeDisableParallelForRestriction] public NativeArray<quaternion> lastRotation;

        public void Execute(int index, TransformAccess transform)
        {
            int Idx = (index + 1) % Count;

            if (Idx == 0)
            {
                lastPosition[Idx] = anchorPos;
                lastRotation[Idx] = anchorRotation;
            }
            else
            {
                lastPosition[Idx] = transform.position;
                lastRotation[Idx] = transform.rotation;
            }
        }
    }

    void ForEachShellDo(Action<Transform, MeshRenderer, int> func)
    {
        for (int i = 0; i < shellCount; ++i)
            func(shellTransforms[i], shellRenderers[i], i);
    }

    // pattern taken from https://github.com/keijiro/DepthInverseProjection/blob/6b6d72d8178dbecdc29b037a175b95ea364bdbaa/Assets/InverseProjection/InverseProjection.cs
    static internal class ShaderIDs {
        internal static readonly int AnimationTime = Shader.PropertyToID("_AnimationTime");
        internal static readonly int ShellCount = Shader.PropertyToID("_ShellCount");
        internal static readonly int ShellIndex = Shader.PropertyToID("_ShellIndex");
        internal static readonly int ShellLength = Shader.PropertyToID("_ShellLength");
        internal static readonly int ShellDroop = Shader.PropertyToID("_ShellDroop");
        internal static readonly int SpikeDensity = Shader.PropertyToID("_SpikeDensity");
        internal static readonly int SpikeCutoffMin = Shader.PropertyToID("_SpikeCutoffMin");
        internal static readonly int SpikeCutoffMax = Shader.PropertyToID("_SpikeCutoffMax");
        internal static readonly int SpikeShapeStylizationFactor = Shader.PropertyToID("_SpikeShapeStylizationFactor");
        internal static readonly int SpikeDroopStylizationFactor = Shader.PropertyToID("_SpikeDroopStylizationFactor");
        internal static readonly int ShellSpecularSharpness = Shader.PropertyToID("_ShellSpecularSharpness");
        internal static readonly int ShellSpecularAmount = Shader.PropertyToID("_ShellSpecularAmount");
        internal static readonly int SpikeShadowSmoothnessFactor = Shader.PropertyToID("_SpikeShadowSmoothnessFactor");
        internal static readonly int EyeGlow = Shader.PropertyToID("_EyeGlow");
        internal static readonly int SpikeTipColor = Shader.PropertyToID("_SpikeTipColor");
        internal static readonly int BodyColor = Shader.PropertyToID("_BodyColor");
        internal static readonly int SpikeHeightMap = Shader.PropertyToID("_SpikeHeightMap");
    }
}
