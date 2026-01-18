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
    -   *Unknown Context:* **STOP** & Invoke "Teach Dialog".
4.  **Act:** Send HID Command (Click/Type) -> Wait -> Verify Result.

## Roadmap & Tracker

### Phase 1: The Pivot (Refactoring for Robot Control)
**Goal:** Invert control from "Human using Tool" to "Robot asking Human".
- [x] **Refactor Infrastructure:**
    - [x] Create `RobotService`: The main loop orchestrator.
    - [x] Create `RobotTesterPage`: A clean UI focused on the Robot's view and status logs.
- [x] **The "Teach" Dialog:**
    - [x] Design a specific UI execution interruption where the Robot presents what it sees and asks "What is this? What should I do?".
    - [x] Implement "Teaching" flow: Save Explanation + Action to Qdrant.
- [x] **The Loop Implementation:**
    - [x] Implement the `Observe -> Recall -> Act` state machine.
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
    - [x] **Completion Summary:** Report success/fail for each step.
- [ ] **Curiosity Mode (Exploration):**
    - [ ] (Future) Robot clicks unknown buttons in safe environment to learn.

### Phase 2.2: Windows Desktop Companion (Exploration)
**Goal:** Provide a Windows desktop UI that can see real screens, use mock screens, and share the same chat-based teaching/learning loop.
- [ ] **App Shell & UI Parity:**
    - [ ] Create Windows desktop app shell with Robot view, status logs, and chat overlay.
    - [ ] Support image previews in chat ("What is this?") just like mobile.
- [ ] **Screen Sources:**
    - [ ] Live screen capture from Windows desktop.
    - [ ] Mock screen source (reuse existing mock assets).
- [ ] **Robot Loop Integration:**
    - [ ] Wire to existing Observe -> Recall -> Act loop.
    - [ ] Teach/confirm flow writes to Qdrant same as mobile.
- [ ] **Task Execution:**
    - [ ] Load task lists and execute using existing plan logic.
    - [ ] Chat command: "Do task X" with summary responses.
- [ ] **Local Services Connectivity:**
    - [ ] Direct Windows networking to Ollama/Qdrant (Docker) with health checks.
    - [ ] Config for endpoints per environment.

### Phase 3: Hardware Reality
**Goal:** Move from Mocks to Real HDMI Input.
- [ ] **HDMI Capture Integration:**
    - [ ] Integrate USB Capture Card.
    - [ ] Solve "Screen Glare" / Moiré issues if continuing with Camera.

## Current Priorities (Jan 2026)
1.  - [x] **Rewrite Key Components:** Logic moved from `VisionSpikePage` to `RobotTester`; Legacy OCR loop (`EyeActionsLogView`) disabled.
2.  **Implement Teach Dialog:** Ensure user can effectively unblock the robot.
3.  **Memory Injection:** Verify Ollama/Qdrant are correctly saving/retrieving instructions.
4.  **Desktop Companion Exploration:** Define scope for Windows desktop app and start shell + screen capture.
