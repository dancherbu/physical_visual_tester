# AI Agent Context File

## Project Identity
- **Name:** Physical Visual Tester (PVT)
- **Location:** `c:\Users\danbo\Documents\My Projects\physical_visual_tester`
- **Primary Goal:** Create an offline, hardware-based testing tool where an Android device acts as a physical agent to test external systems (Laptops, PCs, etc.).

## Core Capabilities
1.  **"The Hands" (Inputs):** The Android device behaves as a Bluetooth HID peripheral (Keyboard/Mouse) to control the target device physically.
2.  **"The Eyes" (Vision):** The Android device captures the target's visual state.
    - *Original Plan:* Use the phone's camera + Computer Vision (OCR/Homography) to look at the physical monitor.
    - *New Proposal (Under Investigation):* Use digital screen sharing (e.g., via specialized app or HDMI capture) to view the target screen directly, bypassing the need for a physical camera lens and complex calibration.

## Key Files & Documentation
- **`TRACKER.md`:** The central source of truth for project status, roadmap, and active tasks. **Always read this first.**
- **`lib/main.dart`:** Entry point for the Flutter application.

## Current State (as of Jan 2026)
- **HID Layer:** Complete (Keyboard & Mouse implemented).
- **Vision Layer:** In planning/prototyping phase.

## Workflow Rules
- **Safety:** Verify commands before running.
- **Context:** Check `TRACKER.md` for the latest "Next Steps".
