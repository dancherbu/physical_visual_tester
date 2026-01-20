# Physical Visual Tester (PVT) - Robot Tester Roadmap

## Project Identity
- **Goal:** Create an Autonomous AI Robot Tester that "sees" a screen, "thinks" via local LLM (Ollama), and "acts" via Bluetooth HID.
- **Core Philosophy:** **AI First**. The software is not a tool for a human; it is a Robot that asks for help only when confused.
- **Hardware:** Android Phone (Eyes/Hands/Brain) + Target PC (Subject).

## Architecture

### 1. The Body (Android)
- **Eyes:** Camera / HDMI Input (Mock Mode for now).
- **Hands:** Bluetooth HID (Mouse/Keyboard).
- **Nervous System:** Flutter App (Coordinator).

### 2. The Mind (Local AI)
- **Cortex:** Ollama (LLM/Vision Model).
    - *Role:* Scene Understanding, Decision Making, Goal Planning.
- **Memory:** Qdrant (Vector Database).
    - *Role:* Storing "Skills" (e.g., "This icon is Settings", "Clicking here helps with Login").

## operational Workflow: The "Robot Loop"
The Robot runs a continuous loop:
1.  **Observe:** Capture Screen -> OCR & Vision Analysis.
2.  **Recall:** Query Qdrant for known UI elements/contexts in the current view.
3.  **Decide:**
    -   *Known Context:* Execute next step towards Goal.
    -   *Unknown Context:* **STOP** & Invoke "Teach Chat".
4.  **Act:** Send HID Command (Click/Type) -> Wait -> Verify Result.

## Roadmap & Tracker

### Phase 1: The Pivot (Refactoring for Robot Control)
**Goal:** Invert control from "Human using Tool" to "Robot asking Human".
- [x] **Refactor Infrastructure:**
    - [x] Create `RobotService`: The main loop orchestrator.
    - [x] Create `RobotTesterPage`: A clean UI focused on the Robot's view and status logs.
- [x] **Teach Flow (Chat Overlay):**
    - [x] Design a specific UI execution interruption where the Robot presents what it sees and asks "What is this? What should I do?".
    - [x] Implement teaching flow: Save Explanation + Action to Qdrant.
- [x] **The Loop Implementation:**
    - [x] Implement the `Observe -> Recall -> Decide -> Act` state machine.
    - [x] **Visual Memory Feedback:** Elements colored Green (Known) or Red (Unknown) based on Qdrant memory.
    - [x] Implement the "Unknown Item" trigger (Low confidence or no memory match).

### Phase 1.5: Conversational Robot (Chat & RAG)
**Goal:** Teach the Robot via natural conversation instead of rigid forms.
- [x] **Chat Interface:**
    - [x] Replace "Teach Dialog" with a maximizable Chat Overlay.
    - [x] Supports Image previews (Robot says "What is this?" + shows Crop).
- [x] **Conversational Memory:**
    - [x] Robot learns "Facts" (e.g., "The Submit button logs you in") alongside Actions.
    - [x] **RAG:** User can ask "What does the submit button do?", Robot builds answer from Qdrant.
- [x] **Advanced Reasoning (Prerequisites):**
    - [x] Memory Schema: Add `prerequisites` field (Zero or Many).
    - [x] Robot checks prerequisites before acting (e.g., "Need to select item before clicking Buy").

### Phase 1.6: Training Sessions (Watch & Learn)
**Goal:** Robot learns by observing the User performing a task over time.
- [x] **Recording Session:**
    - [x] Create Named Training Sessions (e.g., "How to Login").
    - [x] Robot records screen changes (Transitions) while user operates the target.
- [x] **Smart Analysis & Hypothesis:**
    - [x] Compare Frames (OCR Diff) to detect "Typing" or "Navigating".
    - [x] Identify Context (URLs, Headers) as Prerequisites.
    - [x] Generate **Hypothesis**: "User typed 'danboakye' into 'Username' on 'famame.app'".
- [x] **Verification Chat:**
    - [x] Robot asks: "I assumed [Hypothesis]. Is this correct?"
    - [x] User confirms ("Yes") or Corrects ("No, I did X").
    - [x] Save confirmed steps to Qdrant Memory.
- [x] **Session Management:**
    - [x] Store raw session path.
    - [x] Option to clear/archive session data after learning.

### Phase 1.7: Event-Driven & Background Curiosity
**Goal:** Optimize recording and utilize idle time for deep learning.
- [x] **Event-Driven Recording:**
    - [x] Only record key events: Page/URL Change, Time/Date Change, Mouse Click (L/R), Mouse Relocate (Start->End), Typing (Full Value).
    - [x] Ignore noise (mouse path, minor pixel shifts).
- [x] **Idle Mode (Background Analysis):**
    - [x] Detect User Inactivity (No events for X seconds).
    - [x] **Deep Page Analysis:** AI analyzes static screen content in background.
    - [x] **Proactive Q&A:** Robot opens chat: "I see 'PowerPoint'. What is its purpose?" (Skip known facts).
    - [x] Store answers immediately to Qdrant.
- [x] **Memory Optimization:**
    - [x] Re-index/Optimize Qdrant embeddings during long idle periods for faster recall.

### Phase 2: Autonomous Task Execution
**Goal:** Robot explores and learns consequences, then executes user plans.
- [x] **Document-Driven Tasks:**
    - [x] User uploads "Task List" (e.g., text/PDF).
    - [x] Robot parses tasks: "1. Open Chrome. 2. Go to Google..."
    - [x] Robot executes sequentially using learned actions.
    - [ ] **Completion Summary:** Report success/fail for each step.
- [ ] **Curiosity Mode (Exploration):**
    - [ ] (Future) Robot clicks unknown buttons in safe environment to learn.

### Phase 2.2: Windows Desktop Companion (Exploration)
**Goal:** Provide a Windows desktop UI that can see real screens, use mock screens, and share the same chat-based teaching/learning loop.
- [ ] **App Shell & UI Parity:**
    - [x] Create Windows desktop app shell with Robot view, status logs, and chat overlay.
    - [ ] Support image/crop previews in chat ("What is this?") just like mobile.
    - [ ] Highlight target element in desktop preview when teaching (parity with mobile overlay).
- [ ] **Screen Sources:**
    - [x] Live screen capture from Windows desktop.
    - [x] Mock screen source (reuse existing mock assets).
- [ ] **Robot Loop Integration:**
    - [x] Wire to existing Observe -> Recall -> Decide -> Act loop.
    - [x] Teach/confirm flow writes to Qdrant same as mobile.
    - [x] Desktop chat clarification -> `analyzeUserClarification` -> Qdrant learn (parity with mobile).
- [ ] **Task Execution:**
    - [x] Load task lists and analyze using existing plan logic.
    - [x] Review/clarify unknown tasks before load (parity with mobile failure review loop).
    - [ ] Execute task lists end-to-end on desktop.
    - [ ] Chat command: "Do task X" with summary responses.
- [ ] **Local Services Connectivity:**
    - [x] Direct Windows networking to Ollama/Qdrant (Docker) with health checks.
    - [ ] Config for endpoints per environment.

#### Session Updates (Jan 18, 2026) - Late
- [x] Desktop shell + UI wiring created.
- [x] Windows screen capture + Tesseract OCR integrated.
- [x] Mock screen loader supports assets and local image files.
- [x] Task list load/analyze added on desktop.
- [x] Task analysis CLI added with normalization + rerank options.
- [x] Context-aware task verification (target visibility) added for desktop and mobile.
- [x] Ollama step normalization + rerank added to verification pipeline.
- [x] Windows build succeeds; Android release build succeeds (R8 disabled).
- [x] Addressed desktop Feedback: Connection status, select text, reactive buttons.

### Phase 3: Hardware Reality
**Goal:** Move from Mocks to Real HDMI Input.
- [ ] **HDMI Capture Integration:**
    - [ ] Integrate USB Capture Card.
    - [ ] Solve "Screen Glare" / Moiré issues if continuing with Camera.

### Phase 2.5: Reliability & Intelligence (Jan 2026)
**Goal:** Bridge the gap between PVT's vision-based approach and traditional automation frameworks (Selenium). Focus on reliability, determinism, and intelligent execution.

**Context:** Unlike Selenium (which uses DOM/Accessibility APIs for exact element access), PVT works with pixels/OCR. This is more universal but introduces ambiguity and timing issues. The following features address these gaps.

- [x] **1. Sequence Memory (Task Chains):**
    - [x] Extend Qdrant memory schema to include `sequence_id` and `step_order` fields.
    - [x] When learning a multi-step task (e.g., "Login"), store each step with a link to the next.
    - [x] Implement `RobotService.executeSequence(sequenceId)` to replay a learned chain.
    - [x] Allow user to name and save sequences from recorded Training Sessions.
    - [x] UI: Show "Saved Sequences" in Brain Stats or Task Menu.

- [x] **2. Action Verification:**
    - [x] After executing any action (click, type), re-capture screen and compare to previous.
    - [x] Verify expected change occurred (e.g., dialog closed, new text appeared).
    - [x] If no change detected after timeout, retry action or ask user for help.
    - [x] Add `verifyAction(expectedChange)` helper to `RobotService`.

- [x] **3. Smart Waits & Synchronization:**
    - [x] Implement `waitForTextAppears(text, timeout)` – poll OCR until target text is visible.
    - [x] Implement `waitForScreenChange(timeout)` – wait until any OCR diff is detected.
    - [x] Use these in task execution loops instead of fixed `Future.delayed()`.
    - [x] Add visual feedback in logs: "Waiting for 'Submit'..."

- [x] **4. Region Grouping (Spatial Context):**
    - [x] Cluster OCR blocks into logical "regions" (e.g., by bounding box proximity).
    - [x] Store region context in memory: "This 'OK' button is inside 'Confirm Delete' dialog."
    - [x] During recall, prefer matches that share spatial context with current view.
    - [x] Helps disambiguate multiple elements with the same text.

- [ ] **5. Recording Mode (Watch & Learn - Enhanced):**
    - [ ] User performs a task; robot records screen + HID events.
    - [ ] At end, robot summarizes: "I saw you click X, then type Y, then click Z."
    - [ ] User confirms or corrects; robot saves as named Sequence.
    - [ ] (Builds on Phase 1.6 but outputs a replayable Sequence, not isolated memories.)

## Current Priorities (Jan 2026)
1.  - [x] **Rewrite Key Components:** Logic moved from `VisionSpikePage` to `RobotTester`; Legacy OCR loop (`EyeActionsLogView`) disabled.
2.  - [x] **Implement Teach Chat:** Ensure user can effectively unblock the robot.
3.  **Memory Injection:** Verify Ollama/Qdrant are correctly saving/retrieving instructions.
4.  - [x] **Desktop Companion Exploration:** Define scope for Windows desktop app and start shell + screen capture.
5.  - [x] **Desktop E2E Testing:** Run full end-to-end tests for the Windows desktop app (live screen, mock screens, task analysis, chat).

#### Session Updates (Jan 20, 2026)
- **Learnings**:
    - **Desktop OCR:** Standard `tesseract` output lacks bounding boxes needed for Hybrid Vision. Switched to `tsv` output parsing to enable spatial context on Desktop.
    - **Idle Vision:** "Red Boxes not turning Green" on Mobile was due to network disconnection/timeouts. Reduced Ollama timeouts (300s -> 12s) to fail fast and show errors.
    - **Brain Health:** Implemented "Force Init & Heal" to fix "0 Vectors" corruption in Qdrant caused by schemaless collection creation.
- **Completed**:
    - [x] **Brain Statistics:** Ported `BrainStatsPage` to Desktop (View Menu) for parity.
    - [x] **Hybird Vision:** Enabled Hybrid Idle Vision by default on Desktop.
    - [x] **Connectivity:** Desktop app now defaults to `localhost` automatically.
    - [x] **UI Polish:** Hidden task list by default on Desktop; Added "Brain Statistics" to View menu.
    - [x] **Desktop OCR Fix:** Implemented TSV parsing for Tesseract to generate proper `OcrBlock`s with bounding boxes.

