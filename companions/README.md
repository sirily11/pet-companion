# Companion packages

Git tracks only README files and modeling scripts in this directory. Companion models, textures, previews, runtime JSON files, validation output, and ZIP packages are local assets supplied separately. Keep a complete companion folder locally to import it, run asset-dependent tests, or rebuild its ZIP.

`orange-kitten/` is the editable companion folder. `orange-kitten.zip` is its portable runtime package. Neither is a resource of the app target. Open **Import pet companion** in the app (or press **⌘I**) and select either one.

A successful import copies the runtime files into the app’s Application Support folder and activates the companion. The original folder or ZIP can then be moved or deleted. The saved companion is restored on launch. Importing another companion replaces the active one and ends its voice conversation. A failed import preserves the active companion.

## Format version 1

Each folder contains `companion.json`, the personality and pose files it references, and every model it lists. A ZIP may have those files at its root or contain one top-level companion folder. Models must be self-contained `.usdz` files. ZIPs use standard stored or deflated compression; links, traversal paths, encrypted/multipart/ZIP64 archives, and packages exceeding 512 MB are rejected.

`companion.json` names the package, its unique `id`, `formatVersion: 1`, supported `rig`, `primaryModel`, all `models`, `personality` file, `poses` file, and `defaultPose`. Paths are relative to the package folder. IDs use letters, numbers, underscores, and hyphens, with a maximum of 64 characters.

`personality.json` contains `description`, `instructions`, and `voice`. These drive the voice session and the AI pose-selection request. Gateway credentials stay in the app’s Keychain and are never part of a companion.

`poses.json` contains a list of pose definitions. Use the supplied 12 definitions as the editable example:

- `id`, `title`, and `symbol` define the pose’s identity, visible label, and SF Symbol.
- `expression` chooses a supported 3D facial expression: `bright`, `happy`, `sleepy`, `surprised`, or `wink`.
- `criteria` tells the pose-selection model when to choose that pose.
- `jointAngles` maps joint names to `[pitch, yaw, roll]` in radians. Omitted joints return to neutral. Supported pose joints are `body`, `head`, `leftEar`, `rightEar`, `leftArm`, `rightArm`, `leftPaw`, and `rightPaw`.
- `jointWaves` add sine motion with `joint`, `axis` (0, 1, or 2), `amplitude`, and `frequency` in radians per second.
- `breathingAmplitude`, `breathingFrequency`, `bounceAmplitude`, and `bounceFrequency` control body movement in meters and radians per second.
- `tail` contains `yaw`, `pitch`, and `curl` signal lists. Each signal specifies `kind` (`sine`, `noise`, `flick`, or `constant`), `amplitude`, `frequency`, `seed`, `period`, `tipScale`, `tipOffset`, `lag`, and `decay`. The supplied definitions show how to combine these signals. The engine fixes the tail’s hip attachment and bounds distal yaw.

Pose IDs and counts are read from the package. The app and AI share the imported pose choices; new pose IDs do not need an app rebuild.

## Model compatibility

Version 1 supports the `painted-cat-v1` rig used by the supplied kitten: Y-up, meters, nine named meshes (`Body`, `Head`, `LeftEar`, `RightEar`, `LeftForeleg`, `RightForeleg`, `LeftPaw`, `RightPaw`, and `Tail`) at the supplied rest coordinates. The app provides skinning, its unified facial/lip rig, and a weighted curved tail. Other skeleton layouts require an additional engine rig adapter. The primary model is the runtime surface; alternate original models travel with the package and are retained when imported.

`orange-kitten/` also preserves modeling sources and previews. Rebuild the runtime ZIP after editing with `./scripts/package-companion.sh`. The ZIP and installed copy contain runtime data only, plus the package’s README in the ZIP.
