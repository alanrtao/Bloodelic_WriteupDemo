#ifndef __MATRIX_CGINC
#define __MATRIX_CGINC

// column major order!
float determinant(float m00, float m01, float m10, float m11) {
    return m00 * m11 - m01 * m10;
}

float determinant(float3 m0, float3 m1, float3 m2)
{
    /* Nvidia implementation: https://developer.download.nvidia.com/cg/determinant.html */
//   return dot(A._m00_m01_m02,
//              A._m11_m12_m10 * A._m22_m20_m21
//            - A._m12_m10_m11 * A._m21_m22_m20);

  return dot(m0, float3(m1.y, m1.z, m1.x) * float3(m2.z, m2.x, m2.y) - float3(m1.z, m1.x, m1.y) * float3(m2.y, m2.z, m2.x));
}

// column major!
void inverse(float3 m0, float3 m1, float3 m2, out float3 m0_, out float3 m1_, out float3 m2_) {

    /* inv = cofactor^T / det */

    float detInv = 1.0 / determinant(m0, m1, m2);
    m0_ = float3(

        // m00=c00
        determinant(m1.y, m1.z, m2.y, m2.z),
        // m01=c10
        determinant(m0.y, m0.z, m2.y, m2.z),
        // m02=c20
        determinant(m0.y, m0.z, m1.y, m1.z)

    ) * detInv;
    m1_ = float3(

        // m10=c01
        determinant(m1.x, m1.z, m2.x, m2.z),
        // m11=c11
        determinant(m0.x, m0.z, m2.x, m2.z),
        // m12=c21
        determinant(m0.x, m0.z, m1.x, m1.z)

    ) * detInv;
    m2_ = float3(

        // m20=c02
        determinant(m1.x, m1.y, m2.x, m2.y),
        // m21=c12
        determinant(m0.x, m0.y, m2.x, m2.y),
        // m22=c22
        determinant(m0.x, m0.y, m1.x, m1.y)

    ) * detInv;
}

float3x3 inverse(float3 m0, float3 m1, float3 m2) {
    float3 m0_, m1_, m2_;
    inverse(m0, m1, m2, m0_, m1_, m2_);
    return float3x3(m0_, m1_, m2_);
}

#endif