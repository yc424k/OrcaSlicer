import SwiftUI
import SceneKit

/// Decoded toolpath buffers from the bridge.
struct ToolpathData: Identifiable {
    let id = UUID()
    let positions: [SIMD3<Float>]
    let types: [UInt8]
    let roles: [UInt8]
    let layerZs: [Float] // sorted unique z of extrude endpoints

    static let travelType: UInt8 = 8
    static let extrudeType: UInt8 = 10

    init?(dictionary: [String: Data]) {
        guard let posData = dictionary["positions"],
              let typeData = dictionary["types"],
              let roleData = dictionary["roles"], !typeData.isEmpty else { return nil }
        positions = posData.withUnsafeBytes { raw -> [SIMD3<Float>] in
            let floats = raw.bindMemory(to: Float.self)
            return (0..<floats.count / 3).map {
                SIMD3(floats[$0 * 3], floats[$0 * 3 + 1], floats[$0 * 3 + 2])
            }
        }
        types = [UInt8](typeData)
        roles = [UInt8](roleData)

        var zs = Set<Float>()
        for i in 0..<types.count where types[i] == Self.extrudeType {
            zs.insert((positions[i].z * 100).rounded() / 100)
        }
        layerZs = zs.sorted()
        if layerZs.isEmpty { return nil }
    }

    var layerCount: Int { layerZs.count }

    func layerIndex(for fraction: Double) -> Int {
        max(0, min(layerZs.count - 1, Int(fraction * Double(layerZs.count)) - (fraction == 1.0 ? 1 : 0)))
    }

    func zForLayerFraction(_ fraction: Double) -> Float {
        layerZs[layerIndex(for: fraction)] + 0.001
    }
}

/// SceneKit viewport for G-code toolpaths: extrusion moves as line segments
/// colored by extrusion role, clipped to a maximum layer z.
struct SceneKitToolpathView: UIViewRepresentable {
    let toolpaths: ToolpathData
    let maxZ: Float
    let showTravels: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .systemBackground

        let camera = SCNCamera()
        camera.zFar = 2000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(120, -120, 120)
        cameraNode.look(at: SCNVector3(0, 0, 10), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        view.scene?.rootNode.addChildNode(cameraNode)

        rebuild(in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        rebuild(in: view)
    }

    private func rebuild(in view: SCNView) {
        view.scene?.rootNode.childNode(withName: "toolpaths", recursively: false)?.removeFromParentNode()
        let node = Self.buildToolpathNode(toolpaths: toolpaths, maxZ: maxZ, showTravels: showTravels)
        node.name = "toolpaths"
        view.scene?.rootNode.addChildNode(node)
    }

    // Extrusion-role palette (subset of the desktop colors).
    private static func color(forRole role: UInt8) -> SIMD4<Float> {
        switch role {
        case 1: return SIMD4(1.00, 0.90, 0.30, 1) // perimeter
        case 2: return SIMD4(1.00, 0.49, 0.22, 1) // external perimeter
        case 3: return SIMD4(0.69, 0.19, 0.16, 1) // overhang perimeter
        case 4: return SIMD4(0.69, 0.31, 0.16, 1) // internal infill
        case 5, 6: return SIMD4(0.59, 0.33, 0.80, 1) // solid/top infill
        case 10, 11: return SIMD4(0.30, 0.50, 0.73, 1) // support
        default: return SIMD4(0.60, 0.60, 0.60, 1)
        }
    }

    private static func buildToolpathNode(toolpaths: ToolpathData, maxZ: Float, showTravels: Bool) -> SCNNode {
        var vertices: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        var indices: [Int32] = []

        let travelColor = SIMD4<Float>(0.2, 0.8, 0.3, 1)

        for i in 1..<toolpaths.positions.count {
            let type = toolpaths.types[i]
            let isExtrude = type == ToolpathData.extrudeType
            let isTravel = type == ToolpathData.travelType
            guard isExtrude || (showTravels && isTravel) else { continue }

            let a = toolpaths.positions[i - 1]
            let b = toolpaths.positions[i]
            guard a.z <= maxZ, b.z <= maxZ else { continue }

            let color = isExtrude ? color(forRole: toolpaths.roles[i]) : travelColor
            indices.append(Int32(vertices.count))
            vertices.append(a)
            colors.append(color)
            indices.append(Int32(vertices.count))
            vertices.append(b)
            colors.append(color)
        }

        guard !vertices.isEmpty else { return SCNNode() }

        // Center on the bed XY midpoint for nicer orbiting.
        var minV = vertices[0], maxV = vertices[0]
        for v in vertices { minV = min(minV, v); maxV = max(maxV, v) }
        let center = SIMD3<Float>((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, 0)
        for i in 0..<vertices.count { vertices[i] -= center }

        let vertexSource = SCNGeometrySource(
            data: vertices.withUnsafeBytes { Data($0) },
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let colorSource = SCNGeometrySource(
            data: colors.withUnsafeBytes { Data($0) },
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let element = SCNGeometryElement(
            data: indices.withUnsafeBytes { Data($0) },
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}
