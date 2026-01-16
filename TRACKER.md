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

### Phase 3.5: Visual Autonomous Learning (Sprint 35)
**Goal:** Enable the AI to "see" and "learn" from a laptop screen via HDMI input (simulated for now).

- **Core Architecture:**
    - [x] Refined `TeacherService` for visual sessions.
    - [x] Implemented `MockScreenCaptureProvider` (uses `assets/mock/laptop_screen.png`).
- **UI Implementation:**
    - [x] Enhanced `VisionSpikePage` as Teacher Mode.
    - [x] Added "Teacher Mode" entry point to Home Page AppBar.
    - [x] Added Toggle for Mock/HDMI Input.
- **Autonomous Actions:**
    - [x] Teach AI to click/type based on identified elements (Enhanced Dialog).
    - [x] **"Curious Agent"**: Implemented Active Learning (`_testAction`) where the agent clicks, observes consequences, and auto-saves the behavior.

### Phase 3.6: The Crawler & Advanced Knowledge (Current)
**Goal:** Automate the learning process completely and deepen understanding beyond just "Click X".

- [ ] **Data Structure for Instructions:**
    - [ ] Define Schema for "Student Instructions" (YAML/JSON).
    - [ ] Protocol for defining `Goal`, `Action`, and `ExpectedResult`.
- [ ] **Context/Fact Learning:**
    - [ ] Ability to teach "Facts" (e.g., "This region IS the Slide Editor").
    - [ ] Store Memory Type: `TYPE_FACT` vs `TYPE_ACTION`.
- [ ] **Autonomous Crawler:**
    - [ ] **Crawler UI:** Add `Crawl` mode to Teacher.
    - [ ] **Logic:** Loop through unvisited elements -> `Test Action` -> Record Consequence.
    - [ ] **Navigation Handling:** Handle "Back" or State Referencing to explore deeper.
- [ ] **Mock Evolution:**
    - [ ] Create complex Mock Scenario (PowerPoint: Home -> Blank Pres -> Slide Editor).

### Phase 4: The "Student" Mode (Execution)
Goal: Execute tasks by recalling memories or reasoning. **(Next Up)**

- [ ] **Planner (The Brain):**
    - [ ] Receive High-Level Goal (e.g., "Create Presentation").
    - [ ] Query Qdrant for relevant Memories (Actions + Facts).
    - [ ] Formulate a Plan (Sequence of Actions).
- [ ] **Execution Loop:**
    - [ ] Execute Step 1 -> Verify State (Vision) -> Execute Step 2.
    - [ ] Error Recovery: Re-plan if state doesn't match expectation.
- [ ] ...

