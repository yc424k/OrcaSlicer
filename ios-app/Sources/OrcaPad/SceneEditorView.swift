import SwiftUI
import SceneKit

/// Decoded scene object row from the bridge.
struct SceneObject: Identifiable {
    let index: Int
    let name: String
    var positionX: Double
    var positionY: Double
    var rotationZ: Double
    var scale: Double
    let sizeX: Double
    let sizeY: Double
    let sizeZ: Double

    var id: Int { index }

    init?(dictionary: [String: Any]) {
        guard let index = dictionary["index"] as? Int else { return nil }
        self.index = index
        name = dictionary["name"] as? String ?? "object"
        positionX = dictionary["positionX"] as? Double ?? 0
        positionY = dictionary["positionY"] as? Double ?? 0
        rotationZ = dictionary["rotationZ"] as? Double ?? 0
        scale = dictionary["scale"] as? Double ?? 1
        sizeX = dictionary["sizeX"] as? Double ?? 0
        sizeY = dictionary["sizeY"] as? Double ?? 0
        sizeZ = dictionary["sizeZ"] as? Double ?? 0
    }
}

/// SceneKit viewport for the model scene: bed plane plus the objects' meshes,
/// with the selected object highlighted.
struct SceneKitModelView: UIViewRepresentable {
    let objects: [SceneObject]
    let selected: Int
    let bedSize: CGSize
    let revision: Int

    // Bed coordinates run from the origin corner to (width, depth).
    private var bedW: CGFloat { bedSize.width > 0 ? bedSize.width : 256 }
    private var bedD: CGFloat { bedSize.height > 0 ? bedSize.height : 256 }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .systemBackground

        let center = SCNVector3(bedW / 2, bedD / 2, 0)
        let camera = SCNCamera()
        camera.zFar = 2000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(center.x + 170, center.y - 170, 150)
        cameraNode.look(at: SCNVector3(center.x, center.y, 10), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        view.scene?.rootNode.addChildNode(cameraNode)

        rebuild(in: view)
        context.coordinator.lastRevision = revision
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if context.coordinator.lastRevision != revision {
            context.coordinator.lastRevision = revision
            rebuild(in: view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastRevision = -1
    }

    private func rebuild(in view: SCNView) {
        view.scene?.rootNode.childNode(withName: "objects", recursively: false)?.removeFromParentNode()
        let root = SCNNode()
        root.name = "objects"

        // Bed plane matching the selected printer's printable area.
        let bed = SCNNode(geometry: SCNPlane(width: bedW, height: bedD))
        bed.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGray5
        bed.position = SCNVector3(bedW / 2, bedD / 2, -0.1)
        root.addChildNode(bed)

        for object in objects {
            guard let mesh = OrcaSlicerCore.sceneMesh(at: object.index),
                  let vertexData = mesh["vertices"], let indexData = mesh["indices"] else { continue }

            let vertexCount = vertexData.count / (3 * MemoryLayout<Float>.size)
            let source = SCNGeometrySource(
                data: vertexData, semantic: .vertex, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                dataStride: 3 * MemoryLayout<Float>.size
            )
            let element = SCNGeometryElement(
                data: indexData, primitiveType: .triangles,
                primitiveCount: indexData.count / (3 * MemoryLayout<UInt32>.size),
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = object.index == selected ? UIColor.systemOrange : UIColor.systemGray2
            material.isDoubleSided = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(object.positionX, object.positionY, 0)
            node.eulerAngles = SCNVector3(0, 0, object.rotationZ * .pi / 180)
            node.scale = SCNVector3(object.scale, object.scale, object.scale)
            root.addChildNode(node)
        }
        view.scene?.rootNode.addChildNode(root)
    }
}
