import AppKit
import Combine
import SceneKit
import simd

@MainActor
final class CatSceneController: ObservableObject {
    let scene = SCNScene()
    let camera = SCNNode()
    let avatar = SCNNode()
    let skeleton = SCNNode()
    @Published private(set) var pose: CatPose?
    @Published private(set) var reaction: PetReaction?
    let package: CompanionPackage?
    var poses: [CatPose] { package?.poses ?? [] }
    @Published var showSkeleton = false { didSet { skeletonDisplay.isHidden = !showSkeleton } }
    @Published var headPitch: Float = 0
    @Published var headYaw: Float = 0
    @Published var headTilt: Float = 0
    @Published var pawLift: Float = 0
    @Published var tailSwing: Float = 0
    @Published var mouthPreview: Float = 0
    @Published private(set) var loadError: String?
    private(set) var joints: [String: SCNNode] = [:]
    private(set) var meshes: [String: SCNNode] = [:]
    private let skeletonDisplay = SCNNode()
    private var boneLines: [(SCNNode, SCNNode, SCNNode)] = []
    private var timer: Timer?
    private var time: Float = 0
    private var tailMoodElapsed: Float = 0
    private var mouth = LipFrame.silence
    private var smoothedMouth = LipFrame.silence
    private var currentExpression = "bright"
    private var cursorTarget = SIMD2<Float>.zero
    private var cursorGaze = SIMD2<Float>.zero
    private var isTouching = false
    private var reactionRemaining: Float = 0
    private var reactionElapsed: Float = 0
    private var reactionStrength: Float = 0
    private var reactionPose: CatPose?
    private(set) var mouthRig: CatMouthRig?
    private(set) var faceRig: CatFaceRig?

    init(package: CompanionPackage? = nil, animate: Bool = true) {
        self.package = package
        pose = package?.defaultPose
        currentExpression = package?.defaultPose.expression ?? "bright"
        scene.background.contents = NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.88, alpha: 1)
        scene.rootNode.addChildNode(avatar)
        avatar.name = "CatAvatar"
        avatar.addChildNode(skeleton)
        skeleton.name = "CatSkeleton"
        configureStage()
        if let package {
            do { try loadCat(url: package.modelURL) } catch { loadError = error.localizedDescription }
        }
        guard animate else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateFrame() }
        }
    }

    deinit { timer?.invalidate() }

    private func configureStage() {
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 36
        camera.camera?.projectionDirection = .vertical
        camera.camera?.zNear = 0.001
        camera.camera?.zFar = 10
        camera.position = SCNVector3(0.02, 0.145, 0.72)
        camera.look(at: SCNVector3(-0.01, 0.135, 0))
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 600
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 450
        key.eulerAngles = SCNVector3(-0.5, -0.5, 0)
        key.position = SCNVector3(-0.25, 0.50, 0.40)
        scene.rootNode.addChildNode(key)
        let floor = SCNNode(geometry: SCNCylinder(radius: 0.19, height: 0.005))
        floor.position = SCNVector3(-0.015, -0.004, 0)
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.89, green: 0.83, blue: 0.73, alpha: 1)
        floor.geometry?.firstMaterial?.roughness.contents = 1
        scene.rootNode.addChildNode(floor)
    }

    private func loadCat(url: URL) throws {
        // Import exactly one character/head. Its facial features are 3D parts
        // on the same head bone, never another illustrated facial surface.
        let imported = try SCNScene(url: url, options: [.checkConsistency: true])
        var parts: [String: SCNNode] = [:]
        var counts: [String: Int] = [:]
        imported.rootNode.enumerateChildNodes { node, _ in
            guard let name = node.name, RigJoint.meshJoints[name] != nil, node.geometry != nil else { return }
            counts[name, default: 0] += 1
            parts[name] = node
        }
        guard parts.count == 9, counts.values.allSatisfy({ $0 == 1 }), let headGeometry = parts["Head"]?.geometry,
              let surface = HeadSurface(geometry: headGeometry) else {
            throw modelError("The character must contain one head and the nine named cat parts.")
        }
        for node in parts.values {
            for material in node.geometry?.materials ?? [] {
                material.lightingModel = .constant
                material.emission.contents = NSColor.black
                material.diffuse.intensity = 1
            }
        }
        let faceMaterials = headGeometry.materials.map { original -> SCNMaterial in
            let material = original.copy() as! SCNMaterial
            material.name = "UnifiedFace"
            material.lightingModel = .lambert
            surface.clearPaintedFace(on: material)
            return material
        }
        createSkeleton()
        for (name, original) in parts {
            guard var geometry = original.geometry?.copy() as? SCNGeometry,
                  let jointName = RigJoint.meshJoints[name], let joint = joints[jointName] else { continue }
            if name == "Tail" { geometry = CatTailGeometry.make() }
            if name == "Head", let headBone = joints["head"] {
                geometry = surface.unifiedHeadGeometry(from: geometry)
                geometry.materials = faceMaterials
                let face = CatFaceRig(surface: surface)
                face.root.simdPosition = -RigJoint.skeleton.first { $0.name == "head" }!.rest
                headBone.addChildNode(face.root)
                let rig = CatMouthRig(surface: surface)
                face.root.addChildNode(rig.root)
                faceRig = face
                mouthRig = rig
                face.setExpression(currentExpression)
            }
            let mesh = SCNNode(geometry: geometry)
            mesh.name = name
            avatar.addChildNode(mesh)
            // Body parts use rigid bindings; the curled tail blends four bones.
            let count = geometry.sources(for: .vertex).first?.vectorCount ?? 0
            let weights = [Float](repeating: 1, count: count)
            let indices = [UInt16](repeating: 0, count: count)
            let weightSource = SCNGeometrySource(data: weights.withUnsafeBytes { Data($0) }, semantic: .boneWeights, vectorCount: count,
                usesFloatComponents: true, componentsPerVector: 1, bytesPerComponent: 4, dataOffset: 0, dataStride: 4)
            let indexSource = SCNGeometrySource(data: indices.withUnsafeBytes { Data($0) }, semantic: .boneIndices, vectorCount: count,
                usesFloatComponents: false, componentsPerVector: 1, bytesPerComponent: 2, dataOffset: 0, dataStride: 2)
            let bones = name == "Tail" ? CatTailGeometry.boneNames.compactMap { joints[$0] } : [joint]
            let tailSources = name == "Tail" ? CatTailGeometry.skinSources() : nil
            let skinner = SCNSkinner(baseGeometry: geometry, bones: bones,
                boneInverseBindTransforms: bones.map { NSValue(scnMatrix4: SCNMatrix4(simd_inverse($0.simdWorldTransform))) },
                boneWeights: tailSources?.weights ?? weightSource, boneIndices: tailSources?.indices ?? indexSource)
            skinner.skeleton = skeleton
            mesh.skinner = skinner
            meshes[name] = mesh
        }
        createSkeletonDisplay()
    }

    private func modelError(_ message: String) -> NSError {
        NSError(domain: "CatCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func createSkeleton() {
        for definition in RigJoint.skeleton {
            let node = SCNNode()
            node.name = definition.name
            let parent = definition.parent.flatMap { joints[$0] } ?? skeleton
            parent.addChildNode(node)
            let parentRest = RigJoint.skeleton.first { $0.name == definition.parent }?.rest ?? .zero
            node.simdPosition = definition.rest - parentRest
            joints[definition.name] = node
        }
    }

    private func createSkeletonDisplay() {
        avatar.addChildNode(skeletonDisplay)
        skeletonDisplay.isHidden = true
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemTeal
        material.emission.contents = NSColor.systemTeal
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        for definition in RigJoint.skeleton {
            guard let joint = joints[definition.name] else { continue }
            let marker = SCNNode(geometry: SCNSphere(radius: 0.003))
            marker.geometry?.materials = [material]
            marker.renderingOrder = 100
            marker.isHidden = !showSkeleton
            joint.addChildNode(marker)
            if let parentName = definition.parent, let parent = joints[parentName] {
                let line = SCNNode(geometry: SCNCylinder(radius: 0.0009, height: 0.01))
                line.geometry?.materials = [material]
                line.renderingOrder = 100
                skeletonDisplay.addChildNode(line)
                boneLines.append((line, parent, joint))
            }
            // Keep markers tied to the visibility of the overlay without hiding actual bones.
            marker.name = "jointMarker"
        }
    }

    func setPose(_ value: CatPose) {
        guard poses.contains(value) else { return }
        clearReaction()
        if value != pose { tailMoodElapsed = 0 }
        pose = value
        headPitch = 0; headYaw = 0; headTilt = 0; pawLift = 0; tailSwing = 0; mouthPreview = 0
    }

    func setLipFrame(_ value: LipFrame) { mouth = value }

    func followCursor(_ direction: SIMD2<Float>?) {
        guard let direction, direction.x.isFinite, direction.y.isFinite else { cursorTarget = .zero; return }
        cursorTarget = simd_clamp(direction, SIMD2(repeating: -1), SIMD2(repeating: 1))
    }

    func setTouching(_ touching: Bool) { isTouching = touching }

    func react(_ value: PetReaction) {
        guard pose != nil, loadError == nil else { return }
        if case .swipe(let direction) = value {
            guard direction.x.isFinite, direction.y.isFinite, simd_length(direction) > 0 else { return }
        }
        if reaction != value {
            reactionElapsed = 0
            tailMoodElapsed = 0
            reaction = value
            reactionPose = value.poseIDs.compactMap { id in poses.first { $0.id == id } }.first
                ?? poses.first { value.preferredExpression != nil && $0.expression == value.preferredExpression }
        }
        reactionRemaining = value.duration
    }

    private func clearReaction() {
        if reaction != nil { tailMoodElapsed = 0 }
        reaction = nil; reactionPose = nil; reactionRemaining = 0; isTouching = false
    }

    func clearInteraction() {
        clearReaction()
        cursorTarget = .zero
    }

    func resetCamera() {
        camera.position = SCNVector3(0.02, 0.145, 0.72)
        camera.look(at: SCNVector3(-0.01, 0.135, 0))
    }

    func updateFrame() {
        guard let selectedPose = pose, loadError == nil else { return }
        time += 1 / 60
        tailMoodElapsed += 1 / 60
        if let reaction {
            reactionElapsed += 1 / 60
            if !(isTouching && reaction.sustainsWhileHeld) { reactionRemaining -= 1 / 60 }
            if reactionRemaining <= 0 { clearReaction() }
        }
        let pose = reactionPose ?? selectedPose
        cursorGaze += (cursorTarget - cursorGaze) * 0.10
        reactionStrength += ((reaction == nil ? 0 : 1) - reactionStrength) * 0.14
        var reactionHead = SIMD3<Float>.zero
        var reactionBody = SIMD3<Float>.zero
        var reactionPaw: Float = 0
        var hop: Float = 0
        var sideways: Float = 0
        var squish: Float = 0
        switch reaction {
        case .touch:
            squish = 0.025 * reactionStrength
            reactionHead.x = 0.045 * reactionStrength
        case .tap:
            hop = max(0, sin(reactionElapsed * 10)) * exp(-reactionElapsed * 2) * 0.007
            reactionPaw = 0.20 * reactionStrength
        case .petting, .longPress:
            squish = 0.015 * reactionStrength
            reactionHead.z = sin(reactionElapsed * 3) * 0.08 * reactionStrength
        case .swipe(let direction):
            let direction = simd_normalize(direction)
            let settle = exp(-reactionElapsed * 3) * reactionStrength
            reactionBody = SIMD3(-direction.y * 0.08, 0, -direction.x * 0.10) * settle
            reactionPaw = 0.35 * reactionStrength
            sideways = direction.x * sin(reactionElapsed * 8) * 0.005 * settle
            hop = max(0, direction.y) * max(0, sin(reactionElapsed * 8)) * 0.005 * settle
        case nil: break
        }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        avatar.simdScale = SIMD3(1 + squish * 0.5, 1 - squish, 1 + squish * 0.5)
        avatar.simdPosition.x = sideways
        avatar.simdPosition.y = pose.breathingAmplitude * sin(time * pose.breathingFrequency)
            + pose.bounceAmplitude * (1 + sin(time * pose.bounceFrequency)) + hop
        var targets = Dictionary(uniqueKeysWithValues: ["body", "head", "leftArm", "rightArm", "leftPaw", "rightPaw", "leftEar", "rightEar"].map { ($0, SIMD3<Float>.zero) })
        targets.merge(pose.jointAngles.mapValues { SIMD3<Float>($0[0], $0[1], $0[2]) }) { _, imported in imported }
        for wave in pose.jointWaves {
            var target = targets[wave.joint] ?? .zero
            target[wave.axis] += wave.amplitude * sin(time * wave.frequency)
            targets[wave.joint] = target
        }
        targets["head", default: .zero] += SIMD3(headPitch - cursorGaze.y * 0.16, headYaw + cursorGaze.x * 0.25, headTilt) + reactionHead
        targets["body", default: .zero] += reactionBody
        targets["rightArm", default: .zero].z -= pawLift + reactionPaw
        for (name, target) in targets {
            guard let joint = joints[name] else { continue }
            let rate: Float = name == "body" ? 0.07 : name == "rightPaw" ? 0.15 : 0.10
            joint.simdEulerAngles += (target - joint.simdEulerAngles) * rate
        }
        // Keep the hip/base completely fixed. Staggered distal rotations bend
        // the weighted tube; they never rotate the whole tail away from the body.
        let tailTargets = CatTailMotion.targets(motion: pose.tail, time: time, moodElapsed: tailMoodElapsed, manualSwing: tailSwing)
        for (index, name) in CatTailGeometry.boneNames.dropFirst().enumerated() {
            guard let joint = joints[name] else { continue }
            joint.simdEulerAngles += (tailTargets[index] - joint.simdEulerAngles) * 0.075
        }
        if currentExpression != pose.expression {
            currentExpression = pose.expression
            faceRig?.setExpression(currentExpression)
        }
        faceRig?.animate(time: time, gaze: cursorGaze)
        let targetMouth = mouthPreview > 0 ? LipFrame(open: mouthPreview, round: 0, closed: 1 - mouthPreview) : mouth
        smoothedMouth = smoothedMouth.blended(toward: targetMouth, amount: targetMouth.open > smoothedMouth.open ? 0.55 : 0.28)
        mouthRig?.apply(smoothedMouth)
        joints["jaw"]?.simdPosition.y = RigJoint.skeleton.last!.rest.y - 0.145 - 0.005 * smoothedMouth.open
        for (_, joint) in joints {
            joint.childNode(withName: "jointMarker", recursively: false)?.isHidden = !showSkeleton
        }
        for (line, parent, child) in boneLines {
            let a = avatar.convertPosition(SCNVector3Zero, from: parent)
            let b = avatar.convertPosition(SCNVector3Zero, from: child)
            let start = SIMD3<Float>(a), end = SIMD3<Float>(b)
            let delta = end - start
            let length = simd_length(delta)
            line.simdPosition = (start + end) * 0.5
            (line.geometry as? SCNCylinder)?.height = CGFloat(length)
            if length > 0.00001 { line.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: delta / length) }
        }
        SCNTransaction.commit()
    }
}
