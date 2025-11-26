# Ableton Smart Assistant (ASA)

Voice/visual assistant for Ableton Live that helps the user execute actions, delivers tips, and draws visual cues over the DAW interface.

## Quick start

### 1. Install dependencies

**Python environment:**
```bash
python -m venv venv_asa && source venv_asa/bin/activate
pip install -r requirements.txt
```

**Swift dependencies:**
Managed through Swift Package Manager (see `ASAApp/Package.swift`).

### 2. Configure API keys

1. Copy the template:
   ```bash
   cp env.example .env
   ```

2. Open `.env` and add your OpenAI API key:
   ```
   OPENAI_API_KEY=sk-your-actual-key-here
   ```

3. **How the key is loaded**
   
   The app loads the key from `.env` via `EnvLoader`. Priority order:
   1. Environment variables (if already exported)
   2. `.env` file in the current directory
   3. `.env` file in the project root
   
   **Optional:** export variables manually:
   ```bash
   source .env
   # or
   export OPENAI_API_KEY="sk-your-key-here"
   ```

### 3. Generate the RAG indices

Process the PDF docs before the first run:

```bash
# Make sure OPENAI_API_KEY is set
export OPENAI_API_KEY="sk-your-key-here"

# Or pass the key explicitly
python scripts/RAGIngest.py \
  --full-pdf "data/live12-manual-en.pdf" \
  --lite-pdf "data/Ableton-versions.pdf" \
  --out-dir "data" \
  --openai-api-key "$OPENAI_API_KEY" \
  --toc-pages 21 \
  --embedding-model "text-embedding-3-large"
```

**Parameters:**
- `--toc-pages 21` — skips the first 21 pages (table of contents)
- `--embedding-model` — embedding model to use (defaults to `text-embedding-3-large`)
- `--chunk-tokens 1000` — maximum tokens per chunk (defaults to 1000)

This command creates `AbletonFullIndex.json` and `AbletonLiteDiffIndex.json` inside `data/`.

**Highlights:**
- Structure-aware splitting by PDF headings/sections instead of fixed-size chunks
- TOC extraction feeds metadata (not indexed as content)
- Uses the OpenAI embeddings API for higher-quality search
- Each chunk carries metadata such as title, page, and chapter

### 4. Run the app

**Via Swift Package Manager:**
```bash
cd ASAApp
swift build
swift run ASAApp
```

**Via Xcode:**
1. Open `ASAApp/Package.swift` in Xcode
2. Press Run (⌘R)

### 5. macOS permissions

On first launch macOS will request:
- **Microphone** — for voice input
- **Screen Recording** — to capture Ableton screenshots
- **Accessibility** — to monitor mouse clicks

Approve every prompt in System Settings → Privacy & Security.

## Project structure

```
AI_assistant/
├── ASAApp/                    # Swift app
│   ├── Sources/ASAApp/
│   │   ├── Views/            # SwiftUI interfaces
│   │   ├── Services/         # Business logic
│   │   ├── Audio/            # AVAudioEngine + VAD
│   │   ├── RAG/              # Retrieval-Augmented Generation logic
│   │   └── Overlay/          # Overlay window
│   └── Package.swift
├── scripts/
│   └── RAGIngest.py          # PDF ingestion script
├── data/                      # PDF manuals + generated indices
├── docs/
│   └── SMOKE_TESTS.md        # Manual smoke-test checklist
├── env.example               # API key template
└── requirements.txt          # Python dependencies
```

## Key features

- **Voice input** with VAD (Voice Activity Detection)
- **Automatic screenshots** whenever the user clicks in Ableton
- **RAG system** grounded in Ableton documentation
- **Visual hints** (arrows, highlights) over the Ableton UI
- **Edition awareness** for Suite, Standard, Intro, and Lite

## Testing

See `docs/SMOKE_TESTS.md` for the manual checklist that covers the core scenarios.

## Development

### Adding new API keys

1. Add the new variable to `env.example`
2. Update the code that uses it (for example, inside `AssistantSession.swift`)
3. Make sure `.env` stays in `.gitignore`

### Debugging

Swift logs are available via Console.app or:
```bash
log stream --predicate 'subsystem == "ASAApp"'
```

## License

[Add your license here]

