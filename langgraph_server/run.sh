#!/bin/bash
# Script to run LangGraph server
# Run from project root

cd "$(dirname "$0")/.."
cd langgraph_server
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload

