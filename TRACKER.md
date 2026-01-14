# Physical Visual Tester (PVT) - Project Tracker

## Project Overview
PVT is an offline, hardware-based testing tool where an Android device acts as a physical agent. It reads the target screen via camera (OCR/Vision) and controls the target device via Bluetooth HID (Mouse/Keyboard emulation).

## Tech Stack
- **Framework:** Flutter (Frontend/Logic)
- **Native:** Kotlin (Android Bluetooth HID)
- **Computer Vision:** `google_mlkit_text_recognition` (OCR), `opencv_dart` (Homography/Perspective Transform)
- **State Management:** `flutter_bloc`

## Roadmap & Status

### Guiding Principle (Optimization)
Ship in **vertical slices** that de-risk hardware constraints early:
1) Can this phone be a Bluetooth HID peripheral reliably?
2) Can we capture frames + run OCR at usable latency?
3) Can we map camera → screen well enough to click the right thing?
4) Only then invest in a full script runner + UI polish.

### Milestone 0: Feasibility Spikes (1–2 days)
Goal: Kill the biggest unknowns before building architecture.
- [~] **HID Spike:** Minimal Android app code to register `BluetoothHidDevice`, advertise, pair, and send a single key (e.g., type `abc`) to a PC.
- [x] **Vision Spike:** Minimal Flutter screen that opens camera preview and runs ML Kit OCR on a single frame (manual capture button).
- [ ] **Device/OS Matrix:** Confirm which Android devices/OS versions support peripheral mode + required Bluetooth features (document “known good”).
- [ ] **Acceptance:** You can (a) type text into a PC text field and (b) detect a known word from camera with a bounding box.

### Milestone 0.5: Context & Decision Engine Spike (Local, Offline)
Goal: Prove we can recognize dialogs/errors and choose safe next actions based on context.
- [x] **Define `UIState` JSON:** OCR blocks (text, bbox, confidence), screen/camera metadata, and derived flags (e.g., `has_modal_candidate`).
- [x] **Dialog Heuristics (Baseline):** Detect modal-ish regions and common buttons (OK/Cancel/Close/Retry) from OCR + geometry.
- [x] **Local LLM (Ollama):** Given goal + current `UIState` + recent actions, output a *restricted* next action as JSON.
- [ ] **LLM Guardrails (Vital):** Keep it fast/reliable on CPU-only hardware.
    - [ ] Call LLM **only on events** (step start, dialog detected, repeated failure), never per-frame.
    - [ ] Keep prompts short: current step + current OCR blocks + last 3–5 actions + a few derived flags.
    - [ ] Force **strict JSON-only** responses matching an allow-listed schema; reject and retry once if invalid.
    - [ ] Cap output tokens (`num_predict` ~ 64–200) and set low temperature for determinism.
    - [ ] Always log the decision + minimal rationale (“why”) for debugging.
- [ ] **Safety Rails:** Allow-list actions, max retries, “no destructive clicks” mode, and require evidence capture on failures.
- [ ] **Acceptance:** When an error dialog appears (“Error”, “Failed”, “Retry”), the system chooses an appropriate response (e.g., click “OK”/“Retry” or abort) and logs the rationale.

#### Next Session Checklist (Jan 2026)
- [x] Wire the Vision spike output (`UIState`) into the Decision spike (so the LLM reasons over real OCR, not the sample).
- [x] **Finish HID Spike:** implement Android `BluetoothHidDevice` registration + advertise/pair + send a test key sequence to Windows.
- [x] **Add a small “HID Spike” UI page:** connect/disconnect + send `abc` + basic status.
- [x] **Connection Robustness:** Successfully diagnosed and fixed connection state/recovery issues (verified on Pixel 9 Pro + Windows 11).
- Document a “known good” Android device/OS + Windows pairing flow.

#### HID Spike Notes (Current)
- Flutter UI exists under the “HID Spike” page.
- Android implementation registers a basic BLE HID keyboard and advertises the HID service UUID.
- [x] **Done:** Confirmed Windows pairs, and `sendKeyText` works reliably with auto-recovery logic.
- [x] **Done:** Implement Mouse support (Move, Click, Long Press).

#### HID Spike Completion Notes (Jan 14 2026)
- **Status:** **COMPLETE**.
- **Capabilities:**
  - Keyboard: Send text, Return/Enter.
  - Mouse: Move (relative), Click (Left/Right), Long Press (Drag/Context).
  - Robustness: Auto-recovers stale connections.
- **Usage:** Pair once. If app is restarted/killed, just open app and start typing/moving. No re-pairing needed unless Report Descriptor changes.
- **Next Phase:** Phase 2 (Vision/Calibration).

### Milestone (Later): Memory / RAG (Optional)
Goal: Improve consistency and reduce prompt size by retrieving relevant prior cases.
- [ ] **RAG Store (Qdrant or Alternative):** Store known dialog playbooks and past `UIState` → action → outcome.
- [ ] **Retriever:** Embed + retrieve top-K relevant memories for the current `UIState`.
- [ ] **Grounded Decisions:** Feed retrieved items into Ollama and log which memories were used.
- [ ] **Acceptance:** Dialog handling accuracy improves vs. Ollama-only baseline on a small regression set.

### Phase 1: Bluetooth HID ("The Hands") - Core Priority
Goal: Phone acts as a **reliable** BT keyboard/mouse.
- [x] **Define HID Contract (Flutter):** `connect()`, `disconnect()`, `sendKey(text)`, `sendMouseMove(dx, dy)`, `sendClick(button)`.
- [x] **Scaffold Native Channel:** MethodChannel + strongly typed Dart wrapper + error mapping.
- [x] **Implement Android HID Core:** Kotlin `BluetoothHidDevice` registration, callbacks, and connection state.
- [x] **Advertising + Pairing UX:** BLE advertising, discoverability, and a simple status UI (paired? connected?).
- [x] **Input Commands (Incremental):**
    - [x] Keyboard first (lowest friction)
    - [x] Mouse move + click next
    - [x] Mouse Long Press
- [x] **Robustness:** Reconnect strategy, timeouts, clear logs, and “Reset HID” action. (Fixed "Paired but not inputting" bug).
- [x] **Acceptance:** On Windows/macOS, you can type text and move/click the cursor repeatedly (10+ minutes) without re-pairing. **(Verified Jan 14 2026: Pixel 9 Pro + Windows 11)**.

### Phase 2: Calibration & Vision ("The Eyes")
Goal: Map camera pixels to screen coordinates accurately.
- [ ] **Install Vision Deps:** Add `google_mlkit_text_recognition`, `camera`, and `opencv_dart`.
- [ ] **Frame Pipeline:** Establish a stable flow (camera → image conversion → OCR), with throttling (e.g., 2–5 FPS OCR).
- [ ] **Calibration UI:** Manual select 4 corners + show live “mapped crosshair” preview.
- [ ] **Homography Logic:** `cv.findHomography` + `cv.perspectiveTransform` Camera (x,y) → Screen (x,y).
- [ ] **OCR Implementation:** Detect text + bounding boxes + confidence; expose a “tap box to select target” debug mode.
- [ ] **Acceptance:** For a static screen, clicking the center of a detected word lands within ±10–20 px (after calibration).

#### Alternative Vision Strategy: Digital Direct (Proposed Jan 2026)
User request: Instead of camera OCR (subject to glare, perspective, blur), standardise on "Digital Input" via Screen Share or HDMI Capture.
**Option A: HDMI Capture Card (USB OTG)**
- **Hardware:** Laptop HDMI Out -> USB Capture Card -> Android USB-C.
- **Software:** App treats input as a standard USB Camera (`Android UVC`).
- **Pros:** Perfect pixel fidelity, 0 latency, 100% "Physical" (no software on target), simplifies "Homography" to simple scaling.
- **Cons:** Requires small hardware dongle (~$15).

**Option B: Screen Stream (Software)**
- **Setup:** Target runs a streamer (VNC/WebRTC/WhatsApp). Android views stream.
- **Process:** PVT App analyzes incoming frames from network or uses `MediaProjection` to capture the viewer app.
- **Pros:** Wireless.
- **Cons:** Requires software on target (breaks "Black Box" testing), potential latency/compression artifacts.

**Decision:** Investigation pending. The "HDMI Capture" route aligns best with the "Physical Agent" philosophy while solving the "Camera Quality" headache.


### Phase 3: Test Runner Engine ("The Brain")
Goal: Parse markdown scripts and execute the "Find -> Click" loop.
- [ ] **Script Format v0.1 (First):** Define the canonical Markdown format, defaults, and edge cases (see spec below).
- [ ] **Validator (Pre-Run):** Validate script version + required fields + unknown commands/options; show friendly errors.
- [ ] **Context Model:** Build `UIState` from OCR and maintain `RunContext` (step index, last actions, last OCR snapshots).
- [ ] **Recovery/Dialogs:** Implement a recovery layer that can interrupt a step when a modal/error is detected.
    - [ ] deterministic handlers from script (recommended)
    - [ ] optional LLM-based handler when no rule matches (Ollama)
- [ ] **Script Parser:** Parse Markdown tasks into typed commands.
- [ ] **Execution Loop (State Machine):**
    1. Get next command
    2. Acquire frame → OCR
    3. Match target text → pick best candidate
    4. Transform coordinates
    5. Send HID action
    6. Confirm result (Assert) or fail with screenshot
- [ ] **Assertion:** Assert by OCR presence/absence, with retry windows.
- [ ] **Reporting:** Write `result.md` + save “evidence” frames for failures.
- [ ] **Decision Logging:** Persist the chosen match/action plus “why” (for debugging and improving heuristics/prompts).
- [ ] **Acceptance:** A 3-step script can run end-to-end and produce a deterministic pass/fail report.

#### Script Format v0.1 (Markdown)
Goal: A human-writable test file that is easy to parse deterministically.

**File convention**
- Extension: `.pvt.md` (recommended)
- Encoding: UTF-8

**Header (YAML frontmatter, required)**
```yaml
---
format: pvt-script
version: 0.1
name: "Login happy path"
agent:
    mode: deterministic  # deterministic|assist|auto
    goal: "Sign in and verify welcome text"
    allow:
        - CLICK
        - TYPE
        - WAIT
        - WAIT_FOR
        - ASSERT_SEE
        - ASSERT_NOT_SEE
defaults:
    ocr:
        language: en
        case_sensitive: false
        normalize_whitespace: true
    match:
        strategy: contains   # contains|exact|regex
        pick: best           # best|first|topmost
    timeouts:
        step_ms: 8000
        assert_ms: 8000
    delays:
        post_click_ms: 250
        post_type_ms: 150
---
```

**Steps (Markdown task list, required)**
Each executable step is a task item starting with `- [ ]`.
Non-task lines are ignored (can be used for headings/notes).

**Commands (initial set)**
- `CLICK "<target>"` — Find text by OCR, click its center (after homography)
- `TYPE "<text>"` — Type literal text via HID (supports `${var}` interpolation)
- `WAIT <ms>` — Sleep
- `WAIT_FOR "<target>" [timeout=<ms>]` — Wait until target is visible
- `ASSERT_SEE "<target>" [timeout=<ms>]`
- `ASSERT_NOT_SEE "<target>" [timeout=<ms>]`

**Optional: Recovery rules (recommended for dialogs/errors)**
These are evaluated whenever a modal/error is detected (before continuing the main step list).

Syntax (task item):
- `ON_DIALOG "<pattern>" DO <COMMAND>`

Notes:
- `<pattern>` uses the same match logic as other steps (contains/exact/regex)
- `DO` command should be a safe, single action (usually `CLICK` or `WAIT`)

Example:
```markdown
## Recovery
- [ ] ON_DIALOG "Error" DO CLICK "OK"
- [ ] ON_DIALOG "Update available" DO CLICK "Later"
- [ ] ON_DIALOG "Retry" DO CLICK "Retry"
```

**Command options (key=value, optional)**
- `match=contains|exact|regex` (overrides defaults.match.strategy)
- `pick=best|first|topmost` (tie-breaker when multiple OCR hits)
- `timeout=<ms>` (per-step override)
- `offset=dx,dy` (pixel offset applied after coordinate transform)
- `evidence=true|false` (force capture on step)

**Text normalization (v0.1 default behavior)**
- If `normalize_whitespace=true`: trim + collapse consecutive whitespace to single spaces
- If `case_sensitive=false`: compare case-insensitively
- `contains`: normalized OCR text contains normalized target
- `exact`: normalized OCR text equals normalized target
- `regex`: apply regex to normalized OCR text

**Picking a target (when multiple matches)**
- `best`: highest OCR confidence, tie-break by largest bounding box area
- `first`: first match in OCR iteration order
- `topmost`: smallest Y coordinate (tie-break smallest X)

**Example script**
```markdown
---
format: pvt-script
version: 0.1
name: "Login happy path"
defaults:
    timeouts:
        step_ms: 8000
---

# Login
- [ ] CLICK "Username"
- [ ] TYPE "dan@example.com"
- [ ] CLICK "Password"
- [ ] TYPE "${PASSWORD}"
- [ ] CLICK "Sign in" match=contains
- [ ] ASSERT_SEE "Welcome" timeout=12000
```

**Reporting expectations (v0.1)**
- Each step produces: status (pass/fail), timestamp, and optional evidence frame path
- Failures include: last OCR text snapshot (top N entries) + chosen match details

### Phase 4: Polish & UI
- [ ] **Feedback Overlay:** Draw green boxes around detected text on the camera preview.
- [ ] **Script Editor:** Simple internal editor to paste/load scripts.
- [ ] **Settings:** Configurable click delays, sensitivity, and calibration tuning.

### Cross-Cutting (Do Along the Way)
- [ ] **Permissions/Entitlements Checklist:** Camera, Bluetooth, location (if required), and runtime permission flows.
- [ ] **Logging & Diagnostics:** On-screen log view + export logs to file for field debugging.
- [ ] **Mock Mode:** A “fake HID” implementation so you can develop the runner/vision without a paired PC.
- [ ] **Performance Budget:** Track OCR latency and hit rate; throttle and cache results to avoid jank.
