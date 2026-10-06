# PetPaw

A standalone macOS 14+ pet companion app with separately imported characters, built with SwiftUI, SceneKit, and AVAudioEngine. Both AI features run directly from the app using the user's Vercel AI Gateway key. No server or Node runtime is required. Sparkle provides signed automatic app updates.

The app builds as `pet-companion.app`. Its native Icon Composer document is `CatCompanion/Resources/AppIcon.icon`, referenced directly by the app target. Xcode compiles the document into the system icon and generates icons for earlier macOS versions. The imagegen foreground and its generation prompt are saved in `Design/AppIcon/`.

## Run

Requirements: Xcode and XcodeGen. XcodeGen is already installed on this Mac.

```sh
xcodegen generate
open CatCompanion.xcodeproj
```

Select the **CatCompanion** scheme, **My Mac**, and run. Use **Sign to Run Locally** for local builds. Alternatively, `./scripts/run-app.sh` builds and opens the app in `build/import-app/`, separate from test builds.

After importing the Orange Kitten package, all twelve poses, joint sliders, the skeleton overlay, the orbit camera, and **Try a voice demo** work without a key.

## Import a companion

The app ships without pet models, pose presets, or personality data. Click **Import pet companion** in the toolbar or empty stage, or press **⌘I**, then choose `companions/orange-kitten.zip` or the `companions/orange-kitten/` folder. All three original models, all 12 poses and their movement definitions, and the pet’s personality and voice are in this separate package.

Imported runtime files are copied into Application Support and restored on launch. You can move the source ZIP afterward. Importing a new companion ends the previous conversation; an invalid package preserves your existing companion. Rebuild the ZIP with `./scripts/package-companion.sh` after changing the folder. See [the package format](companions/README.md) for editing and model compatibility.

## Interact with your pet

Move the pointer around the stage to make the pet follow it with their head and eyes. Click or use trackpad tap-to-click directly on the pet:

- **Quick tap:** a happy greeting, little hop, and raised paw.
- **Touch:** a gentle head dip and soft squish while pressed.
- **Slow stroke:** a relaxed petting reaction.
- **Swipe:** a playful pose and movement in the swipe direction. A two-finger trackpad swipe over the pet also works.
- **Long press:** hold still for 0.55 seconds to cuddle; the reaction continues until you release.

Reactions are temporary and use available poses from the imported package, with the current pose as a fallback. The selected pose and joint sliders remain intact, and voice lip sync continues during interactions. Leaving the stage lets the gaze settle; switching away from the window cancels active contacts. VoiceOver actions provide tap, pet, cuddle, and play alternatives.

Drag the empty background to orbit, or hold **Option** while dragging over the pet. Scroll the background to zoom; Option-scroll keeps zoom available over the pet.

## AI Settings

1. Open **Settings** using the toolbar gear or **⌘,**.
2. Paste your Vercel AI Gateway key and click **Save key**.
3. Click **Start conversation** and grant microphone access.

The app stores the key as a generic password in macOS Keychain. Settings displays a masked input and saved status; it never reveals the existing key. You can replace or remove it. Saving/removing a key ends any current conversation. Keys are not stored in source files, user defaults, or logs.

Your Gateway account needs credits and access to both models. Conversation audio and transcript-based pose decisions go directly to AI Gateway. No app-owned backend is involved.

- **Voice:** `google/gemini-3.8-live`. The app exchanges the saved key for a short-lived credential with `POST /v1/realtime/client-secrets`, then connects to Gateway's normalized realtime WebSocket using its documented subprotocols.
- **Web search:** Google Search grounding is enabled in the Gemini Live session using native provider tools. The cat is instructed to search for current information and explicit lookup requests. Grounded replies display clickable source links in the conversation panel. Search uses the existing Gateway connection and key.
- **Poses:** `typesafe-ai/jev`. The app calls `POST /v1/evaluate` with a typed choice question over the imported companion's poses. The Orange Kitten package contains twelve: Idle, Happy, Curious, Wave, Sleepy, Surprised, Playful, Cuddle, Shy, Stretch, Thinking, and Excited. Completed user and assistant transcripts trigger pose selection. Low-confidence choices return to the companion's default pose. Disable **Automatic poses** to prevent pose requests and retain manual control.
- **Audio:** mono little-endian PCM16, microphone at 16 kHz and voice output at 24 kHz. AVAudioConverter resamples microphone input. Gemini's default automatic voice activity detection ends turns. The microphone pauses throughout each spoken reply, including gaps between streamed chunks, and resumes after the response ends, playback drains, and a short echo-decay delay passes. Manual mute remains in effect. The session omits the normalized `turnDetection` override because Gateway currently rejects it for Gemini Live.
- **Conversation:** streaming voice transcripts, text input, microphone mute/unmute, cancel/reconnect, and actionable authentication/credit/network errors.

Ending a conversation, closing the window, or losing the connection stops the microphone and playback. Reconnecting starts a new session; the displayed transcript is not replayed. Speech input resumes between replies; speaking over the cat is unavailable while its reply plays.

## Skeleton

The supplied USDZs are static sculptures with nine separate closed meshes. The app constructs a 15-joint SceneKit skeleton and attaches actual `SCNSkinner` bindings to all nine parts. The body parts have rigid bone influences, while the new curved tail blends four bones. Inverse bind transforms preserve the meshes at rest.

```text
root
└── body
    ├── neck
    │   └── head
    │       ├── leftEar
    │       ├── rightEar
    │       └── jaw
    ├── leftArm
    │   └── leftPaw
    ├── rightArm
    │   └── rightPaw
    └── tail
        └── tailMiddle
            └── tailCurl
                └── tailTip
```

Use **Skeleton** to view the joints. The jaw is a mouth-control marker; a separate 3D mouth rig follows the head bone. The body parts remain rigid; the tail has continuous weighted bending. The original USDZs remain untouched.

The Orange Kitten's twelve presets blend body, head, and arm angles and animate the ears, tail, and breathing. Large amber eyes have two catchlights and periodic blinks; happy crescent eyes, a playful wink, pastel fur, pink cheeks, and a small rose nose give each mood its own expression. One head mesh and one facial rig are used. The illustrated face layer is neutralized. Actual 3D eyelids, brows, nose, whiskers, and lips form one integrated face. Expressions change those features on the same head; they never load or stack another illustrated head. **Joint controls** adds head pitch/yaw/tilt, paw lift, tail swing, and mouth opening. Choosing a pose resets those offsets.

## Tail

`CatTailGeometry` replaces the original rigid tail sculpture in the app with a closed, tapered tube curled beside the body. Its first ring sits inside the hip. Soft orange stripes and a cream tip match the kitten's paint.

The base bone stays fixed to the body. Three distal bones sway with staggered phases, and overlapping vertex weights keep the bend continuous. `CatTailMotion` adds mood-specific activity: idle has slow irregular sway and occasional tip flicks; happy/wave are livelier; curious includes pauses and small flicks; sleepy is almost still; surprised has a brief quiver that settles. Smooth blending transitions between moods. **Tail swing** affects those distal joints; it does not rotate the tail away from its attachment. The original USDZs are preserved.

## Lip sync

The app adds an actual 3D lip rim, dark mouth interior, pink tongue, and philtrum to the unified facial rig. `HeadSurface` blends procedural orange/cream fur and cheek color over the illustrated face layer, removing its mask-like outline. The head uses real lighting so its features and fur share the same curved surface. `CatFaceRig` adds curved 3D eyelids, brows, nose, and whiskers directly to that same head bone. The USDZ position and UV indices are resolved into one unified head vertex stream, preserving the UV seams without multi-index skinning artifacts. A stable local-position vertex channel keeps the neutral facial surface attached to the head during rotation.

`CatMouthRig` opens, closes, and rounds the lip geometry with speech. The tongue appears only when the mouth is open. Silence produces a closed smile; changing a pose does not restore the painted open mouth. **Joint controls → Mouth open** previews the rig independently of audio.

`PlaybackLipEnvelope` analyzes 10 ms speech windows. Their offsets follow the playback buffer's host timestamp and output latency, so larger AVAudioEngine buffers retain syllable movement. `LipSyncAnalyzer` estimates opening from RMS energy and rounding from zero-crossing rate; attack/release smoothing settles the lips between syllables. Live speech and the offline voice demo share this path.

This remains approximate audio-driven lip sync rather than phoneme recognition. The new 3D mouth can later be driven by a phoneme classifier without changing the supplied cat assets.

## Project files

- `project.yml`: reproducible XcodeGen app/test targets and microphone/network entitlements.
- `CatCompanion/App/`: stage, pose controls, conversation panel, and native AI Settings.
- `CatCompanion/Character/`: skeleton, skinning, presets, unified facial surface, 3D features and lips, camera, and lighting.
- `CatCompanion/Audio/`: microphone capture, conversion, streamed playback, voice demo, and lip analysis.
- `CatCompanion/Conversation/`: Keychain storage, direct Gateway HTTP/WebSocket clients, and typed Jev pose selection.
- `CatCompanionTests/`: native request, Settings, streaming, rig, rendering, and audio tests.
- `companions/orange-kitten/`: the importable kitten package, pose definitions, original supplied assets, and modeling source.

The earlier bridge prototype is preserved in `.development-archive/`; the app does not reference or require it.

## Validation

```sh
xcodebuild -project CatCompanion.xcodeproj -scheme CatCompanion -destination 'platform=macOS' -derivedDataPath build/import-tests CODE_SIGN_IDENTITY=- test
```

Test fixtures are resources of the test bundle only; the standalone app build has no pet assets. Import tests cover folder/ZIP installation, persistence, replacement, invalid models/poses, unsafe paths/links, archive corruption and size limits, and use of imported personality data. Tests mock Gateway HTTP and WebSocket transports to verify token/authentication contracts, Jev choices, audio/transcript/interruption handling, Settings persistence behavior, and error handling without network calls or charges. Character tests validate all mesh bindings, rest transforms, real SceneKit rendering, one head and one mouth across all expressions, mouth closure/opening, a fixed tail attachment under swing, bounded irregular idle motion and mood responses, PCM endianness, speech-window timing, and lip output from actual rendered audio (with the test mixer muted).

A paid-model conversation requires a valid Gateway key entered in Settings. On October 6, 2026, the native Gemini setup and a text-triggered spoken response were verified against AI Gateway, including streamed PCM audio and transcripts. Connection diagnostics use the saved key without displaying credentials or recording microphone input.

## API references

- [Gemini 3.8 Live announcement](https://vercel.com/changelog/gemini-3-8-live-models-now-available-on-ai-gateway)
- [Gateway realtime guide](https://vercel.com/docs/ai-gateway/modalities/realtime)
- [Jev model](https://vercel.com/ai-gateway/models/jev)
- [Typed decision HTTP API](https://vercel.com/docs/ai-gateway/modalities/decision)
- [Gemini Live search grounding](https://ai.google.dev/gemini-api/docs/live-api/tools#grounding_with_google_search)

## Automatic updates and releases

Sparkle 2.10.0 checks `https://update.pet.rxlab.app/appcast.xml`. Use **pet-companion → Check for Updates…** for a manual check, or **Software Update…** to change automatic checking and installation. The app enables automatic updates by default. Tests and Xcode previews do not start update checks.

The sandbox grants Sparkle's two installer communication names and enables its installer launcher service. Release builds use Hardened Runtime; the app retains its microphone, network, and import permissions. Each app embeds only the public update key. The private key stays in this Mac's Keychain under account `pet-companion` and in the repository's `SPARKLE_KEY` secret.

GitHub Actions builds and tests pushes and pull requests. Publishing a stable `vMAJOR.MINOR.PATCH` GitHub release starts **macOS Release**: archive a universal Apple Silicon/Intel app, sign Sparkle's nested helpers with Developer ID, create and notarize `PetCompanion.dmg`, staple the ticket, generate the update feed, verify its Ed25519 signature and metadata, upload the DMG to the release, and deploy the feed and release notes to GitHub Pages. Prereleases are excluded. The release workflow run number becomes the monotonically increasing app build number. **macOS Release** can also rebuild an existing stable release using its tag.

Configure these repository Actions secrets before publishing a release:

| Secret | Purpose |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64 Developer ID Application P12 certificate |
| `P12_PASSWORD` | Password for that certificate |
| `SIGNING_CERTIFICATE_NAME` | Exact Developer ID Application identity name |
| `APPLE_TEAM_ID` | Team owning the signing certificate |
| `APPLE_ID` | Apple account with access to that team |
| `APPLE_ID_PWD` | Apple app-specific password for notarization |
| `SPARKLE_KEY` | Exported private key from Sparkle's `generate_keys --account pet-companion -x` |

Enable GitHub Pages with **GitHub Actions** as its source and `update.pet.rxlab.app` as its custom domain. Cloudflare DNS uses a DNS-only CNAME from `update.pet` to `sirily11.github.io`. Enable HTTPS enforcement after GitHub issues the certificate. Run **Initialize Update Site** once before the first stable release to deploy the landing page and an empty valid feed; this workflow refuses to replace a stable release's feed. The first successfully notarized release replaces that empty feed with a signed update entry.

Publishing an update:

```sh
git push origin main
gh release create v1.0.0 --repo sirily11/pet-companion --target main --title 'pet-companion 1.0.0' --notes 'Initial macOS release with signed automatic updates.'
```

Do not upload an ad-hoc-signed or unnotarized archive as a production update. CI rejects changed archive bytes, wrong keys, mismatched versions, wrong URLs, and wrong archive lengths before deployment.

The integration follows the [Sparkle sandboxing guide](https://sparkle-project.org/documentation/sandboxing/) and [distribution documentation](https://sparkle-project.org/documentation/), adapted from `summary-chip-ios`.
