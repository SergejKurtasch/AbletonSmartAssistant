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

### 4. Start LangGraph server (optional, for step-by-step mode)

The LangGraph server provides advanced step-by-step guidance for complex Ableton tasks. It's optional - the app will fall back to simple mode if the server is not running.

**Start the server:**
```bash
# Make sure you're in the project root
cd langgraph_server
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

Or use the provided script:
```bash
chmod +x langgraph_server/run.sh
./langgraph_server/run.sh
```

The server will be available at `http://localhost:8000`. The Swift app will automatically connect to it when processing Ableton-related queries.

**Note:** The server requires the same data files as the Swift app (`data/live12-manual-chunks-with-embeddings.json` and `data/Ableton-versions-diff-chunks-with-embeddings.json`). Make sure you've generated them in step 3.

### 4a. Visualize workflow architecture with LangGraph Studio

LangGraph Studio provides a visual interface to explore, debug, and test your LangGraph workflow.

**Quick start:**
```bash
# Install dependencies (if not already done)
pip install -r requirements.txt

# Start LangGraph Studio
./start-langgraph-studio.sh

# Or manually:
langgraph dev
```

Studio will open at `http://localhost:8123` where you can:
- **Visualize the entire workflow** - see all nodes, edges, and conditional routes
- **Test the workflow** - run it with sample data and see execution flow
- **Debug issues** - track state changes at each step
- **Explore architecture** - understand the flow from intent detection to step-by-step guidance

For detailed setup instructions, see `docs/LANGGRAPH_STUDIO_SETUP.md`.

### 5. Run the app

**Via Swift Package Manager:**
```bash
cd ASAApp
swift build
swift run ASAApp
```

**Via Xcode:**
1. Open `ASAApp/Package.swift` in Xcode
2. Press Run (⌘R)

### 6. macOS permissions

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
├── langgraph_server/         # Python LangGraph server
│   ├── main.py               # FastAPI application
│   ├── workflow.py           # LangGraph workflow definition
│   ├── nodes.py              # Workflow nodes
│   ├── state.py              # State management
│   ├── rag.py                # RAG search (Python)
│   └── config.py             # Configuration
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
- **Step-by-step guidance** via LangGraph agent (optional, requires Python server)

## Testing

See `docs/SMOKE_TESTS.md` for the manual checklist that covers the core scenarios.

## Troubleshooting

If you're experiencing issues with the chat or LangGraph server, see `docs/TROUBLESHOOTING.md` for common problems and solutions.

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

