# ASA Manual Smoke Tests

## Sidebar UI
- Launch app → onboarding modal appears and stores Ableton edition in `AppStorage`.
- Verify chat list renders seeded entries and screenshot thumbnail opens preview.
- Toggle `Auto-click Capture` → state persists across relaunch.

## Audio Loop
- Tap `Start Listening` → microphone permission alert; voice RMS triggers VAD log events.
- Speak phrase; ensure PCM chunks reach `AssistantSession.handleAudioChunk`.
- Assistant reply arrives via OpenAI streaming and plays through playback queue without clipping music.

## RAG Integration
- Run `python scripts/RAGIngest.py ...` to produce JSON indexes in `data/`.
- Ask for feature available in Lite (e.g., quantization) → assistant references `AbletonFullIndex`.
- Ask for feature missing in Lite (resampling) → assistant cites Lite restriction snippet and proposes workaround.

## Screenshot + Overlay
- With Auto mode active, click inside Ableton → 300×300 crop saved, new chat entry created, overlay pulse drawn.
- Hit `Take Screenshot` → full Ableton capture appended to transcript.

## Recovery
- Disable Auto mode → CGEvent tap stops (check log). Toggle listening off to release audio session.

