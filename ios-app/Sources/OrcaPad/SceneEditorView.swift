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

/// Multi-object scene editor: SceneKit viewport plus per-object transform
/// controls (move / rotate / scale), delete, and auto-arrange.
struct SceneEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var objects: [SceneObject] = []
    @State private var selected: Int = 0
    @State private var sceneRevision = 0 // bump to rebuild the SceneKit node graph

    private var selectedObject: SceneObject? {
        objects.first { $0.index == selected }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SceneKitModelView(objects: objects, selected: selected, revision: sceneRevision)
                    .ignoresSafeArea(edges: [])

                controls
                    .padding()
                    .background(.bar)
            }
            .navigationTitle("씬 편집 (\(objects.count)개 오브젝트)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button {
                            try? OrcaSlicerCore.addTestCubeToScene()
                            reload()
                        } label: {
                            Label("큐브 추가", systemImage: "plus.square")
                        }
                        Button {
                            try? OrcaSlicerCore.arrangeScene()
                            reload()
                        } label: {
                            Label("자동 배치", systemImage: "square.grid.2x2")
                        }
                        .disabled(objects.isEmpty)
                    }
                }
            }
            .onAppear { reload() }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if objects.isEmpty {
                Text("오브젝트가 없습니다 — 큐브를 추가하거나 파일을 가져오세요")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(objects) { object in
                            Button {
                                selected = object.index
                            } label: {
                                Text("\(object.name) #\(object.index)")
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(object.index == selected ? Color.accentColor : Color(.systemGray5))
                                    .foregroundStyle(object.index == selected ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                if let object = selectedObject {
                    transformSlider(
                        "X", value: object.positionX, range: -120...120, unit: "mm"
                    ) { apply(positionX: $0) }
                    transformSlider(
                        "Y", value: object.positionY, range: -120...120, unit: "mm"
                    ) { apply(positionY: $0) }
                    transformSlider(
                        "회전", value: object.rotationZ, range: 0...360, unit: "°"
                    ) { apply(rotationZ: $0) }
                    transformSlider(
                        "크기", value: object.scale * 100, range: 10...300, unit: "%"
                    ) { apply(scale: $0 / 100) }

                    Button(role: .destructive) {
                        OrcaSlicerCore.removeSceneObject(at: object.index)
                        reload()
                    } label: {
                        Label("선택 오브젝트 삭제", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func transformSlider(
        _ title: String, value: Double, range: ClosedRange<Double>, unit: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(title).frame(width: 44, alignment: .leading)
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range
            )
            Text("\(Int(value))\(unit)")
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
    }

    private func apply(positionX: Double? = nil, positionY: Double? = nil,
                       rotationZ: Double? = nil, scale: Double? = nil) {
        guard let object = selectedObject else { return }
        OrcaSlicerCore.setSceneObject(
            at: object.index,
            positionX: positionX ?? object.positionX,
            positionY: positionY ?? object.positionY,
            rotationZ: rotationZ ?? object.rotationZ,
            scale: scale ?? object.scale
        )
        reload()
    }

    private func reload() {
        objects = OrcaSlicerCore.sceneObjects().compactMap { SceneObject(dictionary: $0) }
        if !objects.contains(where: { $0.index == selected }) {
            selected = objects.first?.index ?? 0
        }
        sceneRevision += 1
    }
}

private struct SceneKitModelView: UIViewRepresentable {
    let objects: [SceneObject]
    let selected: Int
    let revision: Int

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
        cameraNode.position = SCNVector3(160, -160, 140)
        cameraNode.look(at: SCNVector3(0, 0, 10), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        view.scene?.rootNode.addChildNode(cameraNode)

        // Bed grid for orientation.
        let bed = SCNNode(geometry: SCNPlane(width: 256, height: 256))
        bed.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGray5
        bed.position = SCNVector3(0, 0, -0.1)
        view.scene?.rootNode.addChildNode(bed)

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
