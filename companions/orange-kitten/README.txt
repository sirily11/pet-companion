Orange Kitten — importable companion package, version 1

Import this folder or ../orange-kitten.zip using “Import pet companion” in
pet-companion. The app stores its own copy and restores it on the next launch.

Runtime files:
- companion.json: package identity, supported rig, model paths, and default pose.
- personality.json: personality instructions, description, and speaking voice.
- poses.json: all 12 poses, labels, facial expressions, AI selection criteria,
  joint angles, joint oscillations, breathing, bouncing, and tail motion.
- cat-*-v2.usdz: all three supplied self-contained 3D models.

The app uses the happy model with a single unified 3D facial rig. Alternate
sleepy/surprised original sculptures are preserved in the package. Models are
not switched or stacked when selecting a pose.

Build a runtime-only ZIP with ./scripts/package-companion.sh from the project.
Original artwork, previews, and editable modeling sources stay in this folder;
they are omitted from the runtime ZIP and installed companion copy.

Reference-shaped painted kitten, revision 2

The revised sculpt follows the supplied kitten's asymmetrical head and ears,
broad cream cheeks, tiny paws, squat seated body, and thick curled tail. Its
softly painted orange/cream markings and facial expressions are baked around
the curved, closed surfaces.

Main model: cat-happy-v2.usdz
Other expressions: cat-sleepy-v2.usdz and cat-surprised-v2.usdz
These are static seated sculptures with painted facial details, without an
animation rig. Side and rear shapes and markings are inferred from the single
supplied illustration. The models have nine separate closed mesh parts and
203,104 triangles each. They use Y-up and meter units, approximately 26 cm tall.

actual-model-views-and-expressions.png contains renders of the actual USDZs:
top row = front, three-quarter, side;
bottom row = back, sleepy, surprised.
Individual full-size renders are in previews/.

Validation: all three final packages passed Apple's usdchecker --arkit --strict.
Every part was checked for a closed surface and consistent outward winding.
The preview sheet was rendered directly from the final exported USDZ files.

Editable meshes: source/cat-*-v2.usda and source/cat-*-v2.usdc.
Materials: source/textures/*-skin.png.
Reference artwork and edit prompts are also preserved in source/.
The artwork was created/edited with the built-in image generation tool.

To rebuild on macOS, run source/bake_sculpt.py with Python, NumPy, and Pillow.
It bakes the skin maps and exports/checks the models with Apple's USD tools.
source/sculpt_cat.py is the geometry helper; render_previews.py and
render_sheet.py render the actual exported models.
