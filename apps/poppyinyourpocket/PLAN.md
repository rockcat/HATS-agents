# Poppy In Your Pocket — implementation plan

*Against [requirements.md](requirements.md). Written 25 Sep 2026.*

A one-agent Flutter app driven by the Embodiment API: the user talks, Poppy
answers with a voice and an animated VRM face, and she can use the phone's
camera to see who she is talking to.

## What already exists

Most of the hard parts are in this repo and should be reused rather than
rewritten.

| Need | Where it already is | State |
| --- | --- | --- |
| VRM rendering, visemes, blink, idle motion | `apps/flutter/avatar_view/` — three.js + `@pixiv/three-vrm` in a WebView with a Dart↔JS bridge | Works. Now a shared package. |
| Viseme → VRM mapping, rest pose | `apps/web/modules/avatar-core.js`, `apps/web/morph-lipsync.js` | Shared by the dashboard and the Flutter app already. |
| Speech with lipsync timings | Speech Service `:3050` → runner → `agent_speech` SSE event carrying `audioBase64` + `visemes` per sentence | Works, streams per sentence. |
| Speech-to-text | `speech_to_text` package, used in `chat_panel.dart` | On-device. Reuse. |
| QR pairing → API key | `qr_scan_screen.dart`, `auth_service.dart`, spec in `apps/flutter/app_spec.md` | Works. Reuse. |
| Agent roster, conversation, speech, avatar, framing | Embodiment API `:3001/api/embodiment/v1` | Complete for one-agent use. |
| Memory, Kanban, IMAP email | MCP catalogue entries `memory`, `kanban`, `email-imap` | Exist. `email-imap` offers 49 tools — use `tools.upfrontTools` to send only the handful Poppy needs. |
| Trimming a big MCP server | `tools.upfrontTools` on the agent template | Shipped. |

**Not existing, and the bulk of the work:** camera access, face recognition,
VRMA animations, and the mechanism that makes the first two possible at all.

## The central problem: the camera is not where the tools are

The requirements ask for "a new MCP developed for webcam access on phone and
browser". That cannot work as written. MCP servers are processes the **Team
Runner** spawns; the camera is on the **phone**. A server-side process has no
route to it.

What does work is inverting the call. Call these **device tools**:

```
agent calls take_photo
   → device-camera MCP server (on the runner) issues a request, id=abc123
   → runner pushes  device_request {id, tool, args}  down the existing SSE stream
   → app captures the photo
   → app POSTs  /device-results/abc123  with the image
   → MCP tool call resolves and the agent sees the result
```

This is one new idea that buys camera, face recognition, location,
notifications and anything else that lives on the handset. It is worth building
properly and once.

It needs, in the Embodiment API:

- `device_request` SSE event — `{ id, tool, arguments, expiresAt }`
- `POST /api/embodiment/v1/device-results/{id}` — `{ ok, result }` or `{ ok: false, error }`
- `GET /api/embodiment/v1/device-tools` and a way for the app to **declare what it
  can do** on connect, so the runner only offers tools the device actually has.
  A phone with no camera, or a user who declined permission, must not have
  `take_photo` in the agent's tool list at all — an agent that calls a tool that
  always fails will keep trying.

And in the runner: a `DeviceToolBridge` that holds pending calls, correlates
results, and **times out** — a phone in a pocket will not answer, and the agent
must get "no answer from the device" rather than hang. The runner already has
`SseHub` with per-client filtering and `MCPRegistry`; this sits between them.

## Face recognition, and what it must not be

Two decisions, and they pull in the same direction.

**Run it on the device.** Google ML Kit does face detection on-device on both
platforms; a small embedding model gives you the vector to match against. The
frame never leaves the phone. Compared with uploading frames to a server-side
model this is faster, works without a connection, and avoids shipping people's
faces over the network. It also satisfies "as lightweight as possible" better
than any server option.

**Do not let a face grant authority.** The requirements say the main user "has
more rights and control over the agent than other people". A face is not an
authentication factor — a photograph defeats it. Rights must follow the
**paired device and its API key**, which is already how the app authenticates.
Recognition is a convenience: it tells Poppy who she is looking at so she can
greet them and keep separate memories. It must not be what decides whether she
will read the primary user's email.

Concretely: the agent's system prompt states who the primary user is; the
runner refuses privileged actions on a request that is not carrying the primary
user's key. Face identity is context, not credentials.

**Biometric data is a real constraint, not a footnote.** Facial embeddings of
identifiable people are special-category personal data. Design accordingly:
embeddings stay in the app's local store, never sync to the runner or a
project definition, anyone who is not the primary user is asked before being
enrolled, and "forget this person" is one tap. This is cheap to do now and
expensive to retrofit.

## Decisions

**New app, shared avatar package.** `apps/flutter/avatar_view/` holds the
renderer; `apps/flutter/hats` and `apps/poppyinyourpocket` both consume it. The
avatar WebView is the most valuable and most fragile code in either app, and a
copy-paste fork would be fixed once and broken twice. *Done — see below.*

**Web is a dev convenience, not a target.** Mobile is the product. This keeps
one code path for the two hardest parts: `webview_flutter` for the avatar and
`speech_to_text` for voice, neither of which works on web. Testing happens on a
device or emulator.

## Where the runner lives, and what "local" can mean

The runner should run on the user's own machine — a desktop, a home server, a
NUC — with the phone connecting to it. That is local in the sense that matters:
your data, your hardware, no third party in the middle.

**It cannot run on the phone.** Every stdio MCP server is a child process the
runner spawns (`StdioClientTransport` with a command and args), and the Speech
Service spawns a Piper process per voice. iOS forbids spawning arbitrary
processes outright; Android would need a bundled Node runtime and still could
not `npx` a server. This is a hard block, not a difficulty.

**A local LLM is already supported, at the runner.** `ollama` and `lmstudio`
are first-class providers with base URLs (`OLLAMA_BASE_URL`,
`LM_STUDIO_BASE_URL`). Point Poppy's template at Ollama on the same machine and
nothing leaves the house. No new work — it is a template setting.

**An on-device LLM is a different product.** A 2–4B model on a handset can hold
a conversation, but it would have no MCP: no email, no kanban, no memory, no
camera. Those tools are what makes Poppy useful rather than a chatbot, and
small models call tools badly. Worth revisiting only if a narrow offline
capability is wanted for its own sake.

**So the real requirement is offline *tolerance*, not an offline runner.** Two
of the three things the app does already work with no connection: speech-to-text
is on-device, and the avatar renders locally once its model is cached. Only the
reply needs the runner. That makes the honest design:

- queue what the user said while disconnected, and send it on reconnect;
- say plainly that Poppy cannot answer right now rather than failing silently;
- cache the VRM model and the last transcript so the app opens to something.

Phase 2 should build the connection state in from the start — retrofitting it
into a happy-path conversation loop is much harder than allowing for it.

## Still to decide

1. **How the phone reaches the runner off-LAN.** Tailscale or similar is the
   least work and keeps it private; a tunnel with TLS is the alternative. This
   decides what the QR pairing URL contains.
2. **Always-listening or push-to-talk?** "Listens for command" implies a wake
   word — a dependency, a battery cost, and a microphone that is always open.
   Recommendation: push-to-talk first, wake word as a later option.

## Phases

Each phase should end somewhere demonstrable.

### 1 — Foundations
- ~~`apps/flutter/avatar_view/` — extract the WebView avatar from
  `apps/flutter/hats` into a package.~~ **Done.** `hats_avatar_view` holds the
  widget, the config and the page it runs; `apps/flutter/hats` consumes it and
  analyses clean. The HTML builder is a pure function, so the page can be
  diffed and tested without a WebView.
- `apps/poppyinyourpocket/` — Flutter skeleton, pairing by QR, secure storage
  of the key.
- A Dart `EmbodimentClient` mirroring `packages/ui-kit/embodiment-client.js`:
  roster, messages, SSE, speech, avatar URL and `appearance` framing.

**Done when:** the app pairs, picks the agent, and shows its VRM face framed
the way the runner says.

### 2 — The conversation loop
- ~~Push-to-talk → `speech_to_text`.~~ **Done.** Click to start, click to
  stop — not hold-to-talk, because a phone is held in one hand. The platform
  recogniser, so nothing leaves the device; partial results land in the text
  field as they settle, where the keyboard can fix them before Poppy sees
  anything. Not Whisper: weaker on hard audio, free and offline in exchange.
- `agent_message` over SSE into a transcript.
- ~~Speech out.~~ **Done.** Two voices behind one interface: the platform
  voice (instant, offline, mouth estimated from spelling) or Piper through
  the runner (a round trip, real phoneme timings). Chosen from the app bar,
  device by default. Neither needed a server change — speech over the
  Embodiment API is asked for, not pushed. See docs/SERVICES.md.
- Text input as the fallback path. **Done.**

- Connection state throughout: queue while offline, replay on reconnect, and
  say so rather than failing quietly.

**Done when:** you can hold a spoken conversation with a talking face, and
walking out of range degrades honestly instead of hanging. This is the demo
that proves the product.

### 3 — The device-tool bridge — **done**
- Embodiment API: `device_request` event, `PUT /devices/{id}` to declare,
  `POST /device-results/{id}` to answer, `?deviceId=` on `/events`.
- Runner: `DeviceToolBridge` — correlation, timeouts, and tools offered only
  while a device that declared them is connected.
- App: `DeviceToolHost`, with `get_device_time` as the trivial proof.

Verified against a live runner: the agent called the tool, the request went
down the event stream, the device answered, and the agent used the result.

A device tool is routed before MCP and before the built-ins, and counts as
`personal` for exposure — there are few of them and an agent that has to
discover the camera will not think to look.

### 4 — Camera *(take_photo done; record_clip not started)*
- `take_photo` as a device tool, captured at ~720p rather than downscaled
  afterwards. Both: shown inline to the model *and* written to
  `outputs/device/`, so Poppy can refer back to a photo once the thread has
  moved on.
- Permission handling: the tool is declared only when there is a camera and
  permission is granted, and re-declared the moment it is. The app bar shows
  which, and asks when tapped.
- Every capture is noted in the transcript. A camera that fires with no trace
  costs the app the benefit of the doubt, whatever the reason.
- An oversized or unsupported image is dropped at the runner with a sentence
  the agent can read: Anthropic rejects one over 5MB and fails the whole
  request with it, which would cost the answer as well as the picture.

**Still to do:** `record_clip`. No model takes video inline, so a clip would
be saved to the project and described by path — a different shape from a
photo, not just a longer one.

**Done when:** "what am I holding?" works. It does.

### 5 — Face recognition and people *(server side done; device side not started)*

**Done.** The register, the matching and the tools:

- `server/src/people/` — a per-project register of who the team knows, so
  learning Paul once is enough for every agent. What each agent *knows* about
  him stays in its own memory graph; this is only face → name.
- Four tools: `identify_person`, `remember_person`, `forget_person`,
  `list_people`. Offered only when a model is configured.
- Consent is enforced, not recorded. Refusing stores nothing at all, so there
  is nothing to leak and nothing to forget later. Forgetting really deletes.
- Four outcomes, not two. `unsure` is distinct from `unknown`: a match needs
  both enough similarity *and* a margin over the runner-up, because calling
  Rhoda "Paul" is confidently wrong in front of everybody, where asking is
  merely awkward.
- Capability exchange (`server/src/device/capabilities.ts`) settles where
  embedding happens. Vectors from two models cannot be compared, so the runner
  names the canonical model and a device may embed only if it runs that exact
  one.

**Not done.** The part that turns a picture into a vector:

- **On the phone** — ML Kit for detection (not Haar: better on angles and poor
  light, and its tracking id means recognising once per arrival rather than per
  frame), plus a MobileFaceNet `.tflite` through `tflite_flutter` to embed.
  Poppy then declares `faceEmbedding` in its capabilities and sends vectors
  instead of photographs. This is the path worth building.
- **On the runner** — the fallback for clients that cannot. The ONNX plumbing
  is written but `onnxruntime-node` is not a dependency: it unpacks to about
  300MB for a feature most runs never touch, so it loads dynamically if
  installed. Image decoding is deliberately left throwing a clear explanation
  rather than half-written, because the crop, channel order and normalisation
  must match how the model was trained and guessing produces vectors that look
  fine and match nobody.
- Primary user at first-run setup. The store supports one; nothing asks yet.

**Done when:** Poppy greets you by name, asks a stranger for theirs, and
forgets anyone on request. The conversation works end to end against the
store; what is missing is the eyes.

### 6 — Expression and animation
- Convert a starter set of Mixamo FBX clips to `.vrma` as a **development-time**
  script under `scripts/`, with the output committed — not a runtime dependency.
- Load and blend them with `@pixiv/three-vrm-animation` in the avatar package.
- The agent needs to say how it feels for this to mean anything. Add an optional
  `expression` to the `agent_speech` event — the agent tags its reply, the app
  picks a clip, and neutral is the default when it says nothing. Inferring mood
  from text instead would be guesswork twice over.

**Done when:** Poppy's body language matches what she is saying often enough to
be worth it.

### 7 — First run and the agent profile
- Base profile chosen from the Agent Library on first use; deploy it into a
  personal project via the Project Server.
- VRM chosen from a library, with upload.
- Trim `email-imap` to the tools Poppy actually needs via `upfrontTools`, rather
  than paying for 49 schemas on every request.

## What I would build first

Phases 1 and 2. They are the smallest thing that is recognisably the product,
they need no new API surface, and they will teach us more about the shape of
the rest than any amount of further planning.

Phase 3 is the one to think hardest about before writing it, because everything
physical depends on it and it is the piece with no precedent in the codebase.
