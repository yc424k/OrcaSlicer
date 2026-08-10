import SwiftUI
import SceneKit

/// Decoded toolpath buffers from the bridge.
struct ToolpathData: Identifiable {
    let id = UUID()
    let positions: [SIMD3<Float>]
    let types: [UInt8]
    let roles: [UInt8]
    let extruderIds: [UInt8]
    let widths: [Float]   // extrusion width in mm (0 for travels)
    let heights: [Float]  // extrusion height in mm (0 for travels)
    let feedrates: [Float]
    let actualFeedrates: [Float]
    let mm3PerMM: [Float]
    let fanSpeeds: [Float]
    let temperatures: [Float]
    let accelerations: [Float]
    let jerks: [Float]
    let pressureAdvances: [Float]
    let layerDurations: [Float]
    let layerZs: [Float]  // sorted unique z of extrude endpoints

    static let retractType: UInt8 = 1
    static let unretractType: UInt8 = 2
    static let seamType: UInt8 = 3
    static let travelType: UInt8 = 8
    static let wipeType: UInt8 = 9
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
        extruderIds = dictionary["extruderIds"].map { [UInt8]($0) } ?? []

        func floats(_ key: String) -> [Float] {
            dictionary[key].map { data in
                data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } ?? []
        }
        widths = floats("widths")
        heights = floats("heights")
        feedrates = floats("feedrates")
        actualFeedrates = floats("actualFeedrates")
        mm3PerMM = floats("mm3PerMM")
        fanSpeeds = floats("fanSpeeds")
        temperatures = floats("temperatures")
        accelerations = floats("accelerations")
        jerks = floats("jerks")
        pressureAdvances = floats("pressureAdvances")
        layerDurations = floats("layerDurations")

        var zs = Set<Float>()
        for i in 0..<types.count where types[i] == Self.extrudeType {
            zs.insert((positions[i].z * 100).rounded() / 100)
        }
        layerZs = zs.sorted()
        if layerZs.isEmpty { return nil }
    }

    /// The value a range colour mode reads off vertex `i`, nil when the mode
    /// does not apply to it.
    func value(at i: Int, mode: PreviewViewMode) -> Float? {
        func at(_ array: [Float]) -> Float? { i < array.count ? array[i] : nil }
        switch mode {
        case .speed: return at(feedrates)
        case .actualSpeed: return at(actualFeedrates)
        case .acceleration: return at(accelerations)
        case .jerk: return at(jerks)
        case .layerHeight: return at(heights)
        case .lineWidth: return at(widths)
        case .flow:
            guard let mm3 = at(mm3PerMM), let speed = at(feedrates) else { return nil }
            return mm3 * speed
        case .actualFlow:
            guard let mm3 = at(mm3PerMM), let speed = at(actualFeedrates) else { return nil }
            return mm3 * speed
        case .layerTime, .layerTimeLog: return at(layerDurations)
        case .fanSpeed: return at(fanSpeeds)
        case .temperature: return at(temperatures)
        case .pressureAdvance: return at(pressureAdvances)
        case .summary, .lineType, .filament: return nil
        }
    }

    /// Min/max of `mode` across extrusions, for the legend's colour scale.
    func range(for mode: PreviewViewMode) -> ClosedRange<Float>? {
        guard mode.isRange else { return nil }
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for i in 0..<types.count where types[i] == Self.extrudeType {
            guard let value = value(at: i, mode: mode), value > 0 || mode == .fanSpeed else { continue }
            low = min(low, value)
            high = max(high, value)
        }
        guard low <= high else { return nil }
        return low...high
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
    /// Legend items the user switched off.
    let hidden: Set<LegendRow.Kind>
    let mode: PreviewViewMode
    let range: ClosedRange<Float>?

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
        // Colours are baked into the vertex buffers, so a mode or visibility
        // change means a rebuild; the layer slider only flips isHidden.
        let key = "\(toolpaths.id)-\(mode.rawValue)-\(hidden.hashValue)"
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

    /// Per-extruder palette for the Filament mode, mirroring the desktop's
    /// default filament colours.
    private static let filamentColors: [SIMD3<Float>] = [
        SIMD3(0.00, 0.62, 0.55), SIMD3(0.85, 0.32, 0.24), SIMD3(0.24, 0.44, 0.78),
        SIMD3(0.92, 0.76, 0.16), SIMD3(0.55, 0.35, 0.72), SIMD3(0.36, 0.68, 0.30),
    ]

    /// Colour of the extrusion ending at vertex `i` under the current mode.
    private func extrusionColor(at i: Int) -> SIMD3<Float> {
        switch mode {
        case .filament:
            let extruder = i < toolpaths.extruderIds.count ? Int(toolpaths.extruderIds[i]) : 0
            return Self.filamentColors[extruder % Self.filamentColors.count]
        case .summary, .lineType:
            return Self.rgb(OrcaPalette.role(toolpaths.roles[i]))
        default:
            guard let range, let value = toolpaths.value(at: i, mode: mode) else {
                return SIMD3(0.6, 0.6, 0.6)
            }
            return OrcaPalette.rangeColor(value, low: range.lowerBound, high: range.upperBound,
                                          logarithmic: mode.isLogarithmic)
        }
    }

    private static func rgb(_ color: Color) -> SIMD3<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
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

        /// A small cross of two quads marking a point event (retract, seam, …).
        func addMarker(_ p: SIMD3<Float>, color: SIMD4<Float>, layer: Int, size: Float) {
            let dx = SIMD3<Float>(size, 0, 0), dy = SIMD3<Float>(0, size, 0)
            let dz = SIMD3<Float>(0, 0, size)
            addQuad(p - dx, p - dy, p + dx, p + dy, color: color, layer: layer)
            addQuad(p - dx, p - dz, p + dx, p + dz, color: color, layer: layer)
        }

        let markerTypes: Set<UInt8> = [ToolpathData.retractType,
                                       ToolpathData.unretractType,
                                       ToolpathData.seamType]

        for i in 1..<positions.count {
            let type = toolpaths.types[i]
            let isExtrude = type == ToolpathData.extrudeType

            // In the categorical modes each role is togglable; the value modes
            // colour everything, so only the option types can be switched off.
            if isExtrude {
                if hidden.contains(.role(toolpaths.roles[i])) { continue }
            } else if hidden.contains(.moveType(type)) || (!markerTypes.contains(type)
                        && type != ToolpathData.travelType && type != ToolpathData.wipeType) {
                continue
            }

            let b = positions[i]
            let layer = toolpaths.layer(forZ: b.z)

            if markerTypes.contains(type) {
                let color = Self.rgb(OrcaPalette.moveType(type))
                addMarker(b, color: SIMD4(color.x, color.y, color.z, 1),
                          layer: layer, size: 0.32)
                continue
            }

            let a = positions[i - 1]

            // Direction in the XY plane; z-only moves have no visible body.
            var dir = SIMD3<Float>(b.x - a.x, b.y - a.y, 0)
            let length = simd_length(dir)
            guard length > 1e-5 else { continue }
            dir /= length

            // Real extrusion cross-section; travels and wipes stay thin.
            let width = isExtrude ? max(i < toolpaths.widths.count ? toolpaths.widths[i] : 0, 0.2) : 0.16
            let height = isExtrude ? max(i < toolpaths.heights.count ? toolpaths.heights[i] : 0, 0.1) : 0.16

            let side = SIMD3<Float>(-dir.y, dir.x, 0) * (width / 2)
            let down = SIMD3<Float>(0, 0, -height)
            let rgb = isExtrude ? extrusionColor(at: i) : Self.rgb(OrcaPalette.moveType(type))
            let base = SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1)

            let aL = a + side, aR = a - side, bL = b + side, bR = b - side
            // Top face full brightness, sides darkened so the tube reads as 3D
            // without needing normals or a light rig.
            let dark = SIMD4<Float>(base.x * 0.68, base.y * 0.68, base.z * 0.68, 1)
            addQuad(aL, bL, bR, aR, color: base, layer: layer)
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
