import SwiftUI
import SceneKit

/// Decoded toolpath buffers from the bridge.
struct ToolpathData: Identifiable {
    let id = UUID()
    let positions: [SIMD3<Float>]
    let types: [UInt8]
    let roles: [UInt8]
    let widths: [Float]   // extrusion width in mm (0 for travels)
    let heights: [Float]  // extrusion height in mm (0 for travels)
    let layerZs: [Float]  // sorted unique z of extrude endpoints

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
        widths = dictionary["widths"].map { data in
            data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } ?? []
        heights = dictionary["heights"].map { data in
            data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } ?? []

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

    /// Highest layer at or below `z` — buckets a segment into its layer.
    func layer(forZ z: Float) -> Int {
        var low = 0, high = layerZs.count - 1, best = 0
        while low <= high {
            let mid = (low + high) / 2
            if layerZs[mid] <= z + 0.001 {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}

/// SceneKit viewport for G-code toolpaths. Extrusions are solid boxes using
/// the real extrusion width/height from the slicer (like the desktop preview)
/// rather than hairlines, and each layer is its own node so the layer slider
/// only toggles visibility instead of rebuilding the geometry.
struct SceneKitToolpathView: UIViewRepresentable {
    let toolpaths: ToolpathData
    let maxLayer: Int
    let showTravels: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .orcaViewport

        let camera = SCNCamera()
        camera.zFar = 2000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(120, -120, 120)
        cameraNode.look(at: SCNVector3(0, 0, 10), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        view.scene?.rootNode.addChildNode(cameraNode)

        rebuild(in: view, coordinator: context.coordinator)
        applyVisibility(coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let key = "\(toolpaths.id)-\(showTravels)"
        if context.coordinator.builtKey != key {
            context.coordinator.builtKey = key
            rebuild(in: view, coordinator: context.coordinator)
        }
        applyVisibility(coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var builtKey = ""
        var layerNodes: [SCNNode] = []
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

    private func applyVisibility(coordinator: Coordinator) {
        for (index, node) in coordinator.layerNodes.enumerated() {
            node.isHidden = index > maxLayer
        }
    }

    private func rebuild(in view: SCNView, coordinator: Coordinator) {
        view.scene?.rootNode.childNode(withName: "toolpaths", recursively: false)?.removeFromParentNode()
        let root = SCNNode()
        root.name = "toolpaths"
        coordinator.layerNodes = []

        let positions = toolpaths.positions
        guard positions.count > 1 else {
            view.scene?.rootNode.addChildNode(root)
            return
        }

        // Center on the printed area's XY midpoint for nicer orbiting.
        var minXY = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxXY = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for i in 0..<positions.count where toolpaths.types[i] == ToolpathData.extrudeType {
            minXY = min(minXY, SIMD2(positions[i].x, positions[i].y))
            maxXY = max(maxXY, SIMD2(positions[i].x, positions[i].y))
        }
        let center = SIMD3<Float>((minXY.x + maxXY.x) / 2, (minXY.y + maxXY.y) / 2, 0)

        let layerCount = toolpaths.layerCount
        var verts = [[SIMD3<Float>]](repeating: [], count: layerCount)
        var colors = [[SIMD4<Float>]](repeating: [], count: layerCount)
        var indices = [[Int32]](repeating: [], count: layerCount)

        func addQuad(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>,
                     color: SIMD4<Float>, layer: Int) {
            let base = Int32(verts[layer].count)
            verts[layer].append(contentsOf: [p0 - center, p1 - center, p2 - center, p3 - center])
            colors[layer].append(contentsOf: [color, color, color, color])
            indices[layer].append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        let travelColor = SIMD4<Float>(0.2, 0.8, 0.3, 1)

        for i in 1..<positions.count {
            let type = toolpaths.types[i]
            let isExtrude = type == ToolpathData.extrudeType
            let isTravel = type == ToolpathData.travelType
            guard isExtrude || (showTravels && isTravel) else { continue }

            let a = positions[i - 1]
            let b = positions[i]

            // Direction in the XY plane; z-only moves have no visible body.
            var dir = SIMD3<Float>(b.x - a.x, b.y - a.y, 0)
            let length = simd_length(dir)
            guard length > 1e-5 else { continue }
            dir /= length

            // Real extrusion cross-section; travels stay deliberately thin.
            let width = isExtrude ? max(i < toolpaths.widths.count ? toolpaths.widths[i] : 0, 0.2) : 0.16
            let height = isExtrude ? max(i < toolpaths.heights.count ? toolpaths.heights[i] : 0, 0.1) : 0.16

            let side = SIMD3<Float>(-dir.y, dir.x, 0) * (width / 2)
            let down = SIMD3<Float>(0, 0, -height)
            let layer = toolpaths.layer(forZ: b.z)
            let base = isExtrude ? Self.color(forRole: toolpaths.roles[i]) : travelColor

            let aL = a + side, aR = a - side, bL = b + side, bR = b - side
            // Top face full brightness, sides darkened so the tube reads as 3D
            // without needing normals or a light rig.
            let top = base
            let dark = SIMD4<Float>(base.x * 0.68, base.y * 0.68, base.z * 0.68, 1)
            addQuad(aL, bL, bR, aR, color: top, layer: layer)
            addQuad(aL, aL + down, bL + down, bL, color: dark, layer: layer)
            addQuad(aR, bR, bR + down, aR + down, color: dark, layer: layer)
        }

        for layer in 0..<layerCount {
            let node = SCNNode()
            node.name = "layer-\(layer)"
            if !verts[layer].isEmpty {
                node.geometry = Self.makeGeometry(vertices: verts[layer],
                                                  colors: colors[layer],
                                                  indices: indices[layer])
            }
            root.addChildNode(node)
            coordinator.layerNodes.append(node)
        }

        view.scene?.rootNode.addChildNode(root)
    }

    private static func makeGeometry(vertices: [SIMD3<Float>],
                                     colors: [SIMD4<Float>],
                                     indices: [Int32]) -> SCNGeometry {
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
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}
