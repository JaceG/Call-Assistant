# Cluely alternative: fact-check report

**Date:** 2026-10-20 · **Machine:** macOS 27.0.1 + iPhone · **Follows:** `~/Codebases/cluelly-alternative-handoff.md`

How to read the labels:
- **Seen:** observed directly in the GitHub API, the code, or Apple's documentation.
- **Claimed:** a README, docs or a third party says so.
- **Guess:** inference.

✔ marks facts I re-checked myself on GitHub after the research agents reported them. Nothing was cloned, installed or run.

---

## 1. The handoff's named repos vs reality

| Named in handoff | Exists? | What it actually is | Usable? |
|---|---|---|---|
| `Natively-AI-assistant/natively-cluely-ai-assistant` | Yes ✔ | Electron/TypeScript Cluely clone. 3,034★, pushed 2026-10-20 ✔. Has a LAN "Phone Mirror" web page served over WebSocket ✔. | As a test bench and design reference only. **The license blocks client work** (see below). |
| `Thairu-dev/StealthIt` | Yes ✔ | Python/PySide6, **Windows-only** ✔. Uses `WDA_EXCLUDEFROMCAPTURE` and WASAPI loopback. 16★. | No. It doesn't run on a Mac. |
| `P-r-e-m-i-u-m/interview-copilot-overlay` | Yes ✔ | 3★, one commit ✔. About 70 lines of Python that serve static files and forward requests to NVIDIA's cloud API. No WebSocket, no retrieval. | No. It isn't a context router. |
| `open-webui` as the "native iOS frontend" | Yes | A Python web app (156k★). On iPhone it's a Safari Progressive Web App. **Not a native iOS app.** | Only as a document chat backend, not as the phone client. |

**Natively's license history** (seen ✔, from the git history of `LICENSE`):
- 2026-01-27: Apache-2.0
- 2026-02-04: AGPL-3.0
- 2026-06-24: "Natively Personal Use Source License v1.0", source-available and not open source.
  - Its definition of "Commercial Use" includes "consulting" and "client work" ✔.
  - The license says versions released before 2026-06-01 "may remain governed by their previous license terms".
  - Its "Pro" features (custom context, reference-file upload) live in a private submodule (seen).

---

## 2. Candidates against your requirements

Key: ✅ meets · 🟡 partly · ❌ misses · ? unknown

| # | Requirement | Natively | cue | cheating-daddy | OpenOats | Ghostbar |
|---|---|---|---|---|---|---|
| | Language / license | Electron / personal-use only | Electron / GPL-3.0 | Electron / GPL-3.0 | **Swift / MIT** | Swift / no license file |
| | Stars, last push (✔) | 3,034, 2026-10-20 | 1,456, 2026-10-19 | 5,631, 2026-07-23 | 2,610, 2026-10-13 | 110, 2026-07-31 |
| 1 | Native desktop + mobile | 🟡 phone is a web page | 🟡 desktop only | 🟡 desktop only | 🟡 desktop only | 🟡 desktop only |
| 2 | Desktop stealth | 🟡 same Apple flag* | 🟡 same flag* | 🟡 same flag* | 🟡 same flag* ✔ | 🟡 same flag* |
| 3 | Live screen + audio | ✅ | 🟡 audio is opt-in | ✅ | 🟡 audio yes ✔, screen likely no | 🟡 mic only |
| 4 | Live answers | ✅ | ✅ | ✅ | ✅ (claimed) | 🟡 |
| 5 | Pre-prompt instructions | 🟡 custom context is Pro | ✅ rules up to 2,000 characters | ✅ | ? | ❌ |
| 6 | Record calls | 🟡 transcripts only | 🟡 transcripts only | ? | ? | ❌ |
| 8 | Local, connects to phone | ✅ LAN + QR code | ❌ | ❌ | ❌ | ❌ |
| 9 | AWS / outside home network | ❌ | ❌ | ❌ | ❌ | ❌ |
| 10 | Codebases, desktop + mobile | 🟡 Pro only | ❌ | ❌ | 🟡 notes folder | ❌ |
| 11 | Swift | ❌ | ❌ | ❌ | ✅ | ✅ |
| 12 | Headless + GUI | ❌ | ❌ | ❌ | ? | ❌ |
| 13 | Mac + iPhone | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |

\* All of them hide their window with the same macOS setting (`NSWindow.sharingType = .none`, or Electron's `setContentProtection`). See section 3.

Requirement 7 (the phone app doesn't need stealth) applies to every option.

**Result: no existing repo meets requirements 9, 10 or 12.** All three research tracks reached the same answer on their own: build a native Swift app and borrow parts.

Others checked and set aside:
- **pluely:** v1+ is closed-source.
- **Open-Cluely:** no license file, focused on Windows, cloud services only, and no authentication on its WebSocket (based on a search of `server.js`).
- **Muesli:** Swift and MIT, a good second base (see section 4).
- **Parrot:** Swift, GPL-3.0.

---

## 3. Stealth on macOS: the biggest unknown

- **Apple docs (seen, fetched 2026-10-20):** `NSWindowSharingNone` is "a legacy constant that macOS no longer uses". Apple says not to use it to hide content from capture.
- **Electron issue #48258 (seen ✔):**
  - The `setContentProtection` window was visible in a macOS screen share.
  - A maintainer called ScreenCaptureKit bypassing it a deliberate Apple change.
  - The issue was closed "not planned" on 2025-10-14.
- **Apple forum thread 808016 (November 2025, seen):**
  - Apple's own ScreenCaptureKit sample leaves the window out at first, then includes it after a filter toggle.
  - QuickTime captures it immediately.
  - Apple DTS asked for a bug report (FB21115847).
- **Claimed:**
  - The cue and Natively READMEs say Meet, Teams and QuickTime still hide it. They say Zoom needs its "Advanced capture with window filtering" setting.
  - Other sources say it stopped working from macOS 15.4.
- **Chromium (seen):** it uses an undocumented call, `CGSSetWindowCaptureExcludeShape`, as a stronger alternative. Using it is fine for a self-built app, but it rules out the Mac App Store.
- **No source has tested macOS 27.**

Whether hiding works for Zoom, Teams, Meet and OBS on 27.0.1 can only be answered by testing on this Mac. **Do this test before building anything:** a small Swift test window, shared through each app, using both methods.

---

## 4. Swift building blocks (Mac)

| Piece | What | Status |
|---|---|---|
| **OpenOats** (yazinsai/OpenOats) | Swift meeting assistant | MIT ✔. Uses process-tap system audio (`AudioHardwareCreateProcessTap` in `SystemAudioCapture.swift`) ✔ and `sharingType` on its overlay ✔. Claimed: live transcript, suggestions from a notes folder, Ollama or OpenAI-compatible models. No `SCStream` in the code ✔, so no screen capture yet. **Recommended base.** |
| **Muesli** (Muesli-HQ/muesli) | Swift meeting recorder | MIT ✔, pushed 2026-10-20 ✔. Claimed: process taps with ScreenCaptureKit fallback, WhisperKit, live transcript. |
| **WhisperKit** (now `argmaxinc/argmax-oss-swift`) | On-device speech-to-text | MIT ✔, v1.1.1 (2026-10-08). `AudioStreamTranscriber` accepts any audio source (seen). Speaker labels and the streaming server are paid Pro features (claimed). |
| **ScreenCaptureKit** | Screen and audio capture | Audio capture since macOS 13; `SCRecordingOutput` (records to file) since macOS 15 (seen, Apple docs). |
| **Core Audio process taps** | System audio only | Since macOS 14.2. Needs only the narrower "System Audio Recording Only" permission (claimed). |
| **insidegui/AudioCap** | Sample code for process taps | BSD-2 |

Permission notes:
- **Screen-recording re-approval:** macOS asks for it again periodically. It was monthly in 15.0, and reports of re-approval prompts continue on 26.
- **Headless mode (guess):** bare command-line tools capture the screen but don't appear in System Settings (macOS 26.1). So ship headless mode as a flag inside a signed `.app`, not as a loose CLI.

---

## 5. iPhone client

**None of the native Swift chat apps can show text the server pushes on its own,** so none can show a live transcript:

| App | Language | License | Server-pushed text? |
|---|---|---|---|
| Enchanted | Swift | Apache-2.0 | No. Ollama only, in maintenance, and its successor is in Go. |
| OpenClient | SwiftUI | AGPL-3.0 | No. It only streams replies to messages you send. |
| Redde | Swift | FSL (source-available) | Only for one agent backend (Hermes). |
| Conduit | Flutter | GPL-3.0 | Through Open WebUI channels only. |

No open-source Cluely-style project has a native iPhone app. Natively and Open-Cluely serve web pages.

**Recommendation: a small SwiftUI app.**
- `URLSessionWebSocketTask` subscribed to the live transcript and answer stream
- a POST endpoint to ask questions
- Bonjour discovery on Wi-Fi
- a configurable secure WebSocket (`wss://`) address for use away from home
- MacPaw/OpenAI (MIT) if the phone ever calls a model directly

---

## 6. Codebase knowledge (requirement 10)

None of the packaged tools splits Swift code by its structure:
- **AnythingLLM:** plain-text splitter.
- **Open WebUI:** character and header splitters.
- **Tabby:** syntax-aware for 16 languages, no Swift. Development has slowed.
- **claude-context / code-index-mcp:** no Swift.
- **Sourcebot:** went closed-source on 2026-10-10.
- **Serena:** has a Swift adapter, but it's GPL-3.0 and can't resolve SwiftUI or UIKit types on Linux.

**Recommendation: a small custom index service.**
- **Chunking:** LlamaIndex `CodeSplitter`, whose tree-sitter language pack includes Swift.
- **Storage:** LanceDB, a single folder that's easy to sync to AWS.
- **Embeddings:** Ollama.
- **Exact lookups:** ripgrep for exact identifier searches.
- **Access:** a small HTTP API. The same service runs on the Mac and on AWS.

---

## 7. Reaching the Mac from outside home (requirement 9)

| Option | Cost | Ports | Notes |
|---|---|---|---|
| **Tailscale** | Free Personal plan (non-commercial) | None | The phone runs the Tailscale app. Private by default. |
| Cloudflare Tunnel | Free, needs a domain | None (outbound only) | Quick tunnels are for testing only. Cloudflare can see the traffic (guess). |
| AWS relay (Lightsail) | about $3.50–5/month | Port 443 on AWS only | You manage TLS, logins and updates. |

**Recommendation:** start with Tailscale. Add an AWS machine once the codebase index or an always-on relay should live there, and put that machine on the same Tailscale network.

**What "runs on AWS" can mean:** the call happens on the Mac, so audio and screen capture always run on the Mac. AWS can host the relay, the codebase index and, optionally, the AI model calls. The phone then talks to AWS, and AWS talks to the Mac.

---

## 8. Proposed architecture (draft for step 2)

```
Mac (where the call happens)
  Swift app (OpenOats base, MIT)
    process-tap audio + SCStream screen + SCRecordingOutput recording
    WhisperKit transcription
    stealth overlay (best effort, pending the macOS 27 test)
    pre-prompt / playbook per call
    --headless flag (same signed .app)
    WebSocket server with token pairing (QR code)
        │
        ├── Wi-Fi ───────────────┐
        └── Tailscale / AWS ─────┤
                                 ▼
iPhone: SwiftUI app — live transcript, answers, ask a question

Codebase index service (Python: tree-sitter + LanceDB + Ollama, HTTP API)
  runs on the Mac, and can be mirrored to AWS
```

---

## 9. Decisions open for Jace

1. **Stealth test first?** Build a small Swift test window and screen-share it in Zoom, Meet, Teams, OBS and QuickTime on 27.0.1.
2. **Base:** fork OpenOats (MIT, Swift) or start fresh, using it as a reference.
3. **AI model for live answers:** local (Ollama, free but slower) or a cloud API (faster, costs money).
4. **Project folder** for the code.
5. **Recording consent:** some US states require every party to consent. Add a consent setting before recording ships.
