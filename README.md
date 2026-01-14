# Physical Visual Tester (PVT)

PVT is an offline, hardware-based testing tool where an Android device acts as a physical agent:
- Reads the target screen via camera (OCR/Vision)
- Controls the target device via Bluetooth HID (mouse/keyboard emulation)

Project status and roadmap live in [TRACKER.md](TRACKER.md).

## Getting Started

### Prereqs
- Flutter SDK installed (`flutter doctor` should be clean)
- Android Studio + Android SDK (for Android builds)
- Docker Desktop (for running the local “brain” services)

### Run the Flutter app
- `flutter pub get`
- `flutter run`

### Local “Brain” (Ollama)
This repo includes an optional Docker Compose file to run local AI services.

- Start Ollama only:
	- `docker compose -f docker-compose.ai.yml up -d`
- Start Ollama + Qdrant (optional / later):
	- `docker compose -f docker-compose.ai.yml --profile rag up -d`

Defaults:
- Ollama: `http://localhost:11434`
- Qdrant: `http://localhost:6333` (only if enabled)

Pull a small CPU-friendly model (recommended baseline):
- `docker exec ollama ollama pull llama3.2:1b`

Quick benchmark:
- `pwsh -NoProfile -File tools/ollama_benchmark.ps1 -Model llama3.2:1b -NumPredict 128 -Runs 3`

### Notes
- If you already have an `ollama` container from another project, you can reuse it as long as it exposes `11434`.
- If ports conflict, set `OLLAMA_HOST_PORT` / `QDRANT_HOST_PORT` before running compose.
