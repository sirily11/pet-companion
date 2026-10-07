# PetPaw

A standalone macOS 27+ Apple Silicon pet companion app with separately imported characters, built with SwiftUI, SceneKit, and AVAudioEngine. Voice, interaction reactions, and conversation poses use the user's Vercel AI Gateway key. Autonomous desktop pet moods and speech use Apple's on-device Foundation Models on supported Macs. No server or Node runtime is required. Sparkle provides signed automatic app updates.

The app builds as `pet-companion.app`. Its native Icon Composer document is `CatCompanion/Resources/AppIcon.icon`, referenced directly by the app target. Xcode compiles the document into the system icon and generates icons for earlier macOS versions. The imagegen foreground and its generation prompt are saved in `Design/AppIcon/`.

## Run

Requirements: Xcode 27, an Apple Silicon Mac running macOS 27+, Git, Python 3 for dependency preparation, and XcodeGen. XcodeGen is already installed on this Mac.

```sh
xcodegen generate
open CatCompanion.xcodeproj
```

Select the **CatCompanion** scheme, **My Mac**, and run. Use **Sign to Run Locally** for local builds. Alternatively, `./scripts/run-app.sh` builds and opens the app in `build/import-app/`, separate from test builds.

After importing the Orange Kitten package, all twelve poses, joint sliders, the skeleton overlay, the orbit camera, and **Try a voice demo** work without a key.

## Import a companion

The app ships without pet models, pose presets, or personality data. Click **Import pet companion** in the toolbar or empty stage, or press **⌘I**, then choose `companions/orange-kitten.zip` or the `companions/orange-kitten/` folder. All three original models, all 12 poses and their movement definitions, and the pet’s personality and voice are in this separate package.

Imported runtime files are copied into Application Support, and all saved pets remain available across launches. You can move the source ZIP afterward. Each import adds a pet to your library and selects it, ending the previous conversation; an invalid package preserves your existing companion. Rebuild the ZIP with `./scripts/package-companion.sh` after changing the folder. See [the package format](companions/README.md) for editing and model compatibility.

Use **Pets** in the toolbar or menu bar to switch between saved companions. **Manage Pets…** (**⇧⌘P**) opens your collection in a sheet, where you can select a pet, import another, or remove a saved pet. Removal always asks for confirmation and leaves the original source ZIP or folder untouched. Switching ends the current conversation and updates any visible desktop pet. Removing the active pet selects another available companion; removing the last available pet returns to the welcome screen and hides the desktop pet. The selected companion is restored on the next launch.

## Interact with your pet

Move the pointer around the stage to make the pet follow it with their head and eyes. Click or use trackpad tap-to-click directly on the pet:

- **Quick tap:** click or tap to get the pet's attention.
- **Touch:** press gently; contact feedback stays immediate.
- **Slow stroke:** move slowly across the pet to pet them.
- **Swipe:** swipe across the pet, or use a two-finger trackpad swipe over them.
- **Long press:** hold still for 0.55 seconds to offer a cuddle.

In both the editor and desktop pet mode, Jev chooses the reaction's pose and animation using the imported pet's full personality and the latest **10 interactions**, including the current one, in chronological order. Gestures from both views and completed user/pet conversation turns share this history. The same tap can get a different response as the pet's recent experience changes. This works without starting voice chat or granting microphone access, using the decision backend selected in Settings.

Requests debounce for 120 ms: a burst records each gesture but asks for a reaction to the latest one after input settles. A continuous stroke counts once, rather than once per movement sample. Touch feedback and cursor tracking stay immediate while the model responds. Jev can choose to stay still; low-confidence decisions use the package's default pose without added movement. A missing key or failed request displays a message with access to Settings. History stays in memory across voice connections and desktop show/hide, and resets when switching/importing a pet or restarting the app.

Reactions are temporary and use available poses from the imported package. The selected pose and joint sliders remain intact, and voice lip sync continues during interactions. A model-selected cuddle can continue while held. Leaving the stage lets the gaze settle; switching away from the window cancels active contacts and pending reactions. Selecting a manual pose, hiding the desktop pet, or replacing a pet discards its pending reaction. VoiceOver actions use the same model path for tap, pet, cuddle, and play.

Drag the empty background to orbit, or hold **Option** while dragging over the pet. Scroll the background to zoom; Option-scroll keeps zoom available over the pet.

## Desktop pet

After importing a companion, click **Show on desktop** in the editor toolbar (**⇧⌘D**). Your pet appears in a separate transparent floating window, stays visible while you use other apps, and follows you across desktop Spaces. The editor keeps its own camera, pose, and joint controls. The desktop pet also stays active when you close the editor; quit PetPaw to end it.

Drag the 3D pet directly or drag their name bar to move them. **Option-drag** also works. Click to tap, hold still to cuddle, **Shift-drag** to pet them, or use a two-finger trackpad swipe to play. Small pointer movements still count as a click or hold. Empty transparent space lets clicks pass through to the app underneath. Click **sparkles** to ask Jev for a new mood using the same personality and interaction history, or **×** / **Hide desktop pet** to put them away. Importing or switching to another pet updates the visible desktop companion while keeping your saved collection.

Click **Talk** in the pet's bottom toolbar to start the selected Gemini Live or GPT Realtime model using the Gateway key saved in Settings, then speak into your microphone. The toolbar shows a soundwave responding to your voice and the pet's spoken reply, with mute/unmute and stop controls. Replies appear in the bubble above the pet, and the desktop pet follows the voice's lip sync and automatic poses. Random chatter pauses during the conversation and resumes afterward. The voice session continues if you close the editor while the desktop pet is visible; hiding the pet ends it. If a key is missing, the editor opens Settings for you.

When the voice model calls a tool, its name appears in a small circular bubble that gently moves and bobs around the pet, separately from the speech bubble. A small badge spins while calling, shows a green checkmark when done, a red error mark on failure, or a grey cross when cancelled. Each call has its own starting position; bubbles pop in and shrink and fade out six seconds after finishing. Reduce Motion keeps the bubbles still and uses simple fades and a static calling indicator. Queries, status, results, and source links are available in the editor's conversation history.

Every 25–45 seconds, Apple Foundation Models chooses a fresh emotion from the imported pet's poses and writes a matching short speech bubble using its personality. Bubbles stay above the pet for 16 seconds, with the pet toolbar below, and active petting/cuddles finish before a new mood takes over. Generation runs on this Mac, needs no Gateway key or microphone, and starts a fresh session each time. AI moods require **macOS 26+**, an Apple Intelligence-capable Mac, and Apple Intelligence enabled with its model downloaded. Earlier systems and unavailable/failed models use random imported poses and local lines. The app rechecks the model on the next moment.

## AI Settings

1. Open **Settings** using the toolbar gear or **⌘,**.
2. Paste your Vercel AI Gateway key and click **Save key**.
3. Choose **Provider**, then **Model** in the conversation panel. Each provider’s last model and the selected provider persist across launches.
4. Click **Start conversation** and grant microphone access.

The pickers lock while connecting or connected. The app fetches the public Gateway model catalog without a key and caches it for 24 hours. Cached choices remain available offline; Refresh retries discovery. Only compatible Gemini Live and GPT Realtime audio models appear. Transcription-only models and GPT-Live’s separate protocol are excluded. A removed model stays marked unavailable until you choose another.

For local reactions, choose **Local Open-Jev** in Settings, then open **Manage local model…** and download Open-Jev 2B (approximately 4.6 GB; 16 GB memory recommended). Downloads support cancellation, resuming partial files after restart, retry, checksum verification, and confirmed removal. The model stays in Application Support and is never bundled with the app. Downloading does not change the selected decision backend. Local mode needs no Gateway key and never automatically falls back to cloud. Voice and web search still use Gateway.

The local runtime ports Zefan-Cai’s trained Open-Jev 2B checkpoint to Swift/MLX. It scores declared choices with the Qwen 3.5 backbone, trained LoRA adapter and scalar head, and saved calibration temperature; it does not generate JSON. Checkpoint `0c7aa498b1627be8da4acf34c863ff0ee0a92785` and Qwen base `15852e8c16360a2fea060d615a32b45270f8a8fc` are pinned. Original unquantized weights download unchanged; the native scorer promotes arithmetic to float32 to match the explicit float32 PyTorch oracle within the 0.001 probability tolerance. This uses more runtime memory than BF16 computation. One warm runtime serves all decision callers. The current scorer uses uncached candidate batches; shared-prefix caching is disabled. Context above 4,096 tokens reports an error instead of silently discarding history.

The app stores the key as a generic password in macOS Keychain. Settings displays a masked input and saved status; it never reveals the existing key. You can replace or remove it. Saving/removing a key ends any current conversation and cancels pending reactions. Keys are not stored in source files, user defaults, or logs.

Cloud features need Gateway credits and access to their selected models. Local Open-Jev decisions run entirely on this Mac. Conversation audio, the pet's personality, and recent interaction context for reaction/pose decisions go directly to AI Gateway. No app-owned backend is involved.

- **Voice:** Gemini Live defaults to `google/gemini-3.8-live`; GPT defaults to `openai/gpt-realtime-2`. The selected model is used for both credential minting and the WebSocket connection. The app exchanges the saved key for a short-lived credential with `POST /v1/realtime/client-secrets`, then connects to Gateway's normalized realtime WebSocket using its documented subprotocols.
- **Web search:** Gemini Live can call a `web_search` function for current information and explicit lookup requests. The app uses `google/gemini-3-flash` with Google Search grounding through a separate Gateway request, using the same saved key. Gemini waits for the search result before continuing its spoken answer. The conversation panel shows when a search is running and displays clickable source links with the reply. Cancelled tool calls and disconnects cancel pending searches; search failures let the voice conversation continue with an explanation that current information could not be verified.
- **Reactions and poses:** Cloud JEV uses `typesafe-ai/jev`; Local Open-Jev uses the downloaded trained 2B checkpoint. The app calls `POST /v1/evaluate` with typed choices over imported poses and supported reaction animations (still, touch, bounce, nuzzle, cuddle, play). Each request includes the full personality and up to 10 recent interactions. The Orange Kitten package contains twelve poses: Idle, Happy, Curious, Wave, Sleepy, Surprised, Playful, Cuddle, Shy, Stretch, Thinking, and Excited. Completed user and assistant transcripts also trigger pose selection with the shared history. Low-confidence choices return to the companion's default pose. Disable **Conversation poses** to prevent conversation-driven pose requests; gestures still receive Jev reactions.
- **Audio:** mono little-endian PCM16, Gemini microphone input at 16 kHz, GPT microphone input at 24 kHz, and voice output at 24 kHz. AVAudioConverter resamples microphone input. Gemini uses its default voice activity detection; GPT uses server VAD. GPT explicitly continues after text and tool results, while Gemini continues automatically. The microphone pauses throughout each spoken reply, including gaps between streamed chunks, and resumes after the response ends, playback drains, and a short echo-decay delay passes. Manual mute remains in effect. The session omits the normalized `turnDetection` override because Gateway currently rejects it for Gemini Live.
- **Conversation:** streaming voice transcripts, text input, microphone mute/unmute, cancel/reconnect, and actionable authentication/credit/network errors. Web search tool calls appear inline with their name, query, running/completed/failed/cancelled status, and expandable results with source links.

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
- `CatCompanion/Conversation/`: Keychain and preferences, cached model discovery, shared conversation state, Gemini/GPT adapters, native DynamicProfile/Tool definitions, and cloud/local JEV clients and model downloads.
- `CatCompanion/Desktop/`: transparent desktop panel, pointer passthrough, on-device mood generation, and speech bubbles.
- `CatCompanionTests/`: native request, Settings, streaming, rig, rendering, and audio tests.
- `companions/orange-kitten/`: the importable kitten package, pose definitions, original supplied assets, and modeling source.

The earlier bridge prototype is preserved in `.development-archive/`; the app does not reference or require it.

## Validation

```sh
xcodebuild -project CatCompanion.xcodeproj -scheme CatCompanion -destination 'platform=macOS' -derivedDataPath build/import-tests CODE_SIGN_IDENTITY=- ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS='' test
```

The test command uses a test-only host without sandbox entitlements to avoid the macOS 27 XCTest connection hang; normal app builds and Release archives remain sandboxed. Test fixtures are resources of the test bundle only; the standalone app build has no pet assets. Import tests cover folder/ZIP installation, persistence, replacement, invalid models/poses, unsafe paths/links, archive corruption and size limits, and use of imported personality data. Tests mock Gateway HTTP and WebSocket transports to verify token/authentication contracts, Jev choices, audio/transcript/interruption handling, Settings persistence behavior, and error handling without network calls or charges. Character tests validate all mesh bindings, rest transforms, real SceneKit rendering, one head and one mouth across all expressions, mouth closure/opening, a fixed tail attachment under swing, bounded irregular idle motion and mood responses, PCM endianness, speech-window timing, and lip output from actual rendered audio (with the test mixer muted).

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

GitHub Actions builds and tests pushes and pull requests. Publishing a stable `vMAJOR.MINOR.PATCH` GitHub release starts **macOS Release**: archive an Apple Silicon app requiring macOS 27, sign Sparkle's nested helpers with Developer ID, create and notarize `PetCompanion.dmg`, staple the ticket, generate the update feed, verify its Ed25519 signature and metadata, upload the DMG to the release, and deploy the feed and release notes to GitHub Pages. Prereleases are excluded. The release workflow run number becomes the monotonically increasing app build number. **macOS Release** can also rebuild an existing stable release using its tag.

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


### Local model validation

`OpenJevParityTests` is an optional real-weight test. CI skips it unless the pinned model files are explicitly placed in ignored `build/openjev-reference/`. The committed JSON fixture contains prompts, exact reference token IDs, scores, and probabilities, not weights. It covers gestures, an explicit pose, Chinese conversation, and ten mixed interactions. The test requires matching selected choices and confidence fallbacks, and absolute probability error at most 0.001. It records cold load and warm P50/P95 timing.

`scripts/validation/export-openjev-reference.py` exports these fixtures with the pinned PyTorch source (`80ca8e81d08992cb2a4cbb6a0caa1355ad3e5aee`), Torch 2.9.0, Transformers 5.10.2, PEFT 0.19.1, and Accelerate 1.13.0. Use an isolated Python environment, the files listed in `OpenJevManifest.json`, and the upstream `jev/api.py`, `jev/model.py`, and `jev/metrics.py`; pass their directory with `--reference-source`, model files with `--model-directory`, and the destination with `--output`. The app itself needs no Python runtime or local server.

The native MLX dependency is prepared automatically by XcodeGen into ignored `build/native-mlx-swift-lm/`, pinned at `ecd8e88f8cbcab1c5e4ecad4958a8de6ab96d976`. `scripts/dependencies/patch-openjev-norm.py` carries a two-line Qwen 3.5 correction: RMSNorm epsilon is divided by head width when implementing summed L2 normalization. The original mean-based epsilon produced decision probability differences beyond the required tolerance. The script validates the expected source and is idempotent. It does not modify the upstream package cache. The app-owned LoRA layer matches PEFT’s float32 addition followed by a single cast.

For opt-in, paid voice-provider checks, prefix the test command with `TEST_RUNNER_GATEWAY_LIVE_SMOKE=1`. These tests use the saved Gateway key, send only a fixed hello prompt with the test companion’s public personality, receive PCM audio in memory, and request no microphone access. Normal CI skips them.
