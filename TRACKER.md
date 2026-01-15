# Physical Visual Tester (PVT) - Project Tracker

## Project Overview
PVT is an offline, hardware-based testing tool where an Android device acts as a physical agent. It reads the target screen via camera (OCR/Vision) and controls the target device via Bluetooth HID (Mouse/Keyboard emulation).

## Tech Stack
- **Framework:** Flutter (Frontend/Logic)
- **Native:** Kotlin (Android Bluetooth HID)
- **Computer Vision:** `google_mlkit_text_recognition` (OCR), `opencv_dart` (Homography/Perspective Transform)
- **AI/Memory:** Ollama (Local LLM), Qdrant (Vector Database/Memory)
- **State Management:** `flutter_bloc`

## Current Status (Jan 2026)
- **"The Hands" (HID):** ✅ **COMPLETE**. Can pair, type, move mouse, click.
- **"The Eyes" (Vision):** ⚠️ **HARDWARE LIMITATION**. Camera OCR is functional but fragile on screens. **Waiting for HDMI Capture Card** for pixel-perfect vision.
- **"The Brain" (Teacher):** ✅ **READY**. Can auto-discover UI elements and save them to Memory.
- **"The Brain" (Student):** ⏳ **PAUSED**. Design is complete, but implementation waits for reliable vision.

## Roadmap

### Phase 1: Bluetooth HID ("The Hands") - ✅ COMPLETE
Goal: Phone acts as a **reliable** BT keyboard/mouse.
- [x] **HID Spike:** Minimal Android app code to register `BluetoothHidDevice`, advertise, pair, and send keys.
- [x] **Mouse Support:** Move (relative), Click (Left/Right), Long Press (Drag/Context).
- [x] **Robustness:** Auto-recovers stale connections. Verified on Pixel 9 Pro + Windows 11.
- [x] **Acceptance:** Can type text and operate mouse reliably.

### Phase 2: Vision Recovery & Basic Awareness ("The Eyes") - ⏳ FROZEN
**Critical Issue:** Camera pointing at a screen causes moiré patterns and glare.
Goal: Replace Camera with HDMI In for perfect digital signal.

- [x] **Debug Vision Pipeline:** (Legacy Camera approach)
    - [x] Fixed Low-Res YUV issues.
    - [x] Validated High-Res JPEG capture.
- [x] **Homography/Calibration:**
    - [x] Implemented 4-point transform.
    - [x] Added Calibration UI.
- [ ] **HDMI Capture Integration (Hardware Pending):**
    - [ ] Acquire USB-C HDMI Capture Card.
    - [ ] Update Android manifest for USB Camera/UVC support.
    - [ ] Replace `camera` package with `libuvc` or similar UVC library.

### Phase 3: The "Teacher" Mode (Learning)
Goal: "Teach" the agent how to use applications by demonstration + Memory (RAG).

- [x] **Memory Infrastructure:**
    - [x] Integration with **Ollama** (Client + Embeddings + Vision).
    - [x] Integration with **Qdrant** (Service + Storage).
    - [x] **Data Model:** Updated `UIState` to include `toLLMDescription()` and `embedding`.
- [x] **Learning Workflow ("Watch & Learn"):**
    - [x] **Action 1:** Vision AI labels UI elements (Auto-Label).
    - [x] **Action 2:** "Scan Scene" finds all buttons and saves them to Qdrant (Auto-Discovery).
    - [x] **Persistence:** Memories successfully saved to Qdrant.

### Phase 4: The "Student" Mode (Execution)
Goal: Execute tasks by recalling memories or reasoning. **(Next Up)**

- [ ] **Goal Parsing:**
    - [ ] Simple Regex/Keyword matcher (e.g., "Click [TEXT]").
    - [ ] Semantic matcher (Embed user instruction -> Find closest Memory).
- [ ] **Recall Logic:**
    - [ ] Query Qdrant with current screen Context + Goal Vector.
    - [ ] Filter results by score threshold.
- [ ] **Execution Engine:**
    - [ ] Retrieve `(x, y)` from best memory.
    - [ ] **Re-Calibration:** Locate the anchor feature (text) in the *current* view to adjust `(x, y)` offset.
    - [ ] Send HID Click.

### Phase 5: The "Final Product" (Script Runner)
Goal: Execute written test steps from a MD document.

- [ ] **Script Reader:** Parse `test_*.md` files.
- [ ] **Test Runner UI:** Show current step, status (Pass/Fail), and logs.
- [ ] **Reporting:** Generate a run report.

## Backlog / Technical Tasks
- [ ] **Optimized OCR w/ Cropping:** Don't OCR the whole frame, just the active window.
- [ ] **Visual Debugger:** A web UI to see what the agent sees in real-time.

