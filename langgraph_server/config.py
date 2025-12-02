"""Configuration for LangGraph server"""
import os
from pathlib import Path
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Project root (parent of langgraph_server)
PROJECT_ROOT = Path(__file__).parent.parent

# Data directory
DATA_DIR = PROJECT_ROOT / "data"

# Paths to embedding files
LIVE12_MANUAL_EMBEDDINGS = DATA_DIR / "live12-manual-chunks-with-embeddings.json"
ABLETON_VERSIONS_EMBEDDINGS = DATA_DIR / "Ableton-versions-diff-chunks-with-embeddings.json"

# OpenAI API key
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")

# Server configuration
SERVER_HOST = os.getenv("LANGGRAPH_SERVER_HOST", "0.0.0.0")
SERVER_PORT = int(os.getenv("LANGGRAPH_SERVER_PORT", "8000"))

# Model configuration
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o")
VISION_MODEL = os.getenv("VISION_MODEL", "gpt-4o")

# RAG configuration
RAG_TOP_K = int(os.getenv("RAG_TOP_K", "5"))
VERSION_CHECK_TOP_K = int(os.getenv("VERSION_CHECK_TOP_K", "2"))

