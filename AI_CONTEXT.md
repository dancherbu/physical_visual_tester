# AI Agent Context File

## Project Identity
- **Name:** Physical Visual Tester (PVT)
- **Location:** `c:\Users\danbo\Documents\My Projects\physical_visual_tester`
- **Primary Goal:** Create an offline, hardware-based testing tool where an Android device acts as a physical agent to test external systems (Laptops, PCs, etc.).

## Core Capabilities
- **The Hands**: Bluetooth HID (Keyboard/Mouse) for interacting with the target PC. ✅ **Functional**
- **The Eyes**: 
  - **Camera**: High-Res Capture + OCR (ML Kit). ✅ **Functional**
  - **Brains**: Local LLM (Ollama) + Vector Memory (Qdrant). ✅ **Connected**
- **The Brain ("Teacher" Mode)**: 
  - **Workflow**: Watch User -> Capture State -> Ask Vision AI "What is this?" -> Save Memory.
  - **Status**: 🚧 **Ready for Testing** (Waiting for `llava` model).

## Core Documentation
- **[TRACKER.md](./TRACKER.md)**: The Master Plan. **READ THIS FIRST**.
- **[Vision Spike](./lib/spikes/vision/vision_spike_page.dart)**: Main UI for Camera/OCR/Teacher.
- **[Logic](./lib/spikes/brain/)**: `TeacherService`, `OllamaClient`, `QdrantService`.

## Current Focus
Validating the "Teacher" loop: Can we point at a screen, click a button, and have the AI correctly identify/remember the action? State (as of Jan 2026)
- **HID Layer:** Complete (Keyboard & Mouse implemented).
- **Vision Layer:** 🚧 BROKEN / Debugging. Transitioning to "Teacher" model (RAG+Ollama).

## Workflow Rules
- **Safety:** Verify commands before running.
- **Context:** Check `TRACKER.md` for the latest "Next Steps".
