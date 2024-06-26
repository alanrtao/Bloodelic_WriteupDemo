using System.Collections;
using System.Collections.Generic;
using UnityEngine;

#pragma warning disable CS3001
#pragma warning disable CS3002

public static class MaterialExtensions
{
    /* Decorator wrappers for native parameter-setting methods */

    public static Material SetIntParam(this Material m, string name, int value)
    {
        m.SetInteger(name, value);
        return m;
    }

    public static Material SetFloatParam(this Material m, string name, float value)
    {
        m.SetFloat(name, value);
        return m;
    }

    public static Material SetColorParam(this Material m, string name, Color value)
    {
        m.SetColor(name, value);
        return m;
    }

    public static Material SetVectorParam(this Material m, string name, Vector4 value)
    {
        m.SetVector(name, value);
        return m;
    }

    public static Material SetTextureParam(this Material m, string name, Texture value)
    {
        m.SetTexture(name, value);
        return m;
    }

    public static Material SetIntParam(this Material m, int id, int value)
    {
        m.SetInteger(id, value);
        return m;
    }

    public static Material SetFloatParam(this Material m, int id, float value)
    {
        m.SetFloat(id, value);
        return m;
    }

    public static Material SetColorParam(this Material m, int id, Color value)
    {
        m.SetColor(id, value);
        return m;
    }

    public static Material SetVectorParam(this Material m, int id, Vector4 value)
    {
        m.SetVector(id, value);
        return m;
    }

    public static Material SetTextureParam(this Material m, int id, Texture value)
    {
        m.SetTexture(id, value);
        return m;
    }
}