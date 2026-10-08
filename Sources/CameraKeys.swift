import simd

// The bundle's camera keys from a camera's column-major simd matrices: m[c][r] is column c, row r.
enum CameraKeys {
    static func intrinsics(_ k: simd_float3x3) -> Intrinsics {
        Intrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]))
    }

    // `transform` is world-from-camera. pose.r is its rotation row-major; pose.c is its translation.
    static func pose(_ transform: simd_float4x4) -> (rotation: [Double], center: [Double]) {
        let t = transform
        var rotation: [Double] = []
        for row in 0..<3 {
            for col in 0..<3 {
                rotation.append(Double(t[col][row]))
            }
        }
        let center = [Double(t[3][0]), Double(t[3][1]), Double(t[3][2])]
        return (rotation, center)
    }
}
