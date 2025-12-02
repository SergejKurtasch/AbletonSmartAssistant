#!/bin/zsh
# Safe Swift project build in iCloud Drive
# Automatically checks and downloads files from iCloud before building

PROJECT_DIR="/Users/sergej/Library/Mobile Documents/com~apple~CloudDocs/DS_AI/python_projects/AI_assistant/ASAApp"

cd "$PROJECT_DIR" || {
    echo "❌ Failed to change to project directory: $PROJECT_DIR"
    exit 1
}

echo "🔍 Checking project file availability..."

# Function to check file availability
check_file() {
    local file="$1"
    if [ -f "$file" ]; then
        # Try to read the first byte of the file
        if head -c 1 "$file" > /dev/null 2>&1; then
            echo "✅ $file is available"
            return 0
        else
            echo "⚠️  $file exists but is not downloaded from iCloud"
            return 1
        fi
    else
        echo "❌ $file not found"
        return 1
    fi
}

# Check critical files
PACKAGE_OK=false
if check_file "Package.swift"; then
    PACKAGE_OK=true
else
    echo "📥 Attempting to download Package.swift from iCloud..."
    # Try different download methods
    brctl download "Package.swift" 2>/dev/null || \
    brctl download "./Package.swift" 2>/dev/null || \
    echo "   Use Finder for manual download"
    
    echo "⏳ Waiting for download (3 seconds)..."
    sleep 3
    
    if check_file "Package.swift"; then
        PACKAGE_OK=true
    fi
fi

# If Package.swift is still unavailable
if [ "$PACKAGE_OK" = false ]; then
    echo ""
    echo "❌ Package.swift is not available for reading"
    echo ""
    echo "📋 Manual download instructions:"
    echo "   1. Open Finder"
    echo "   2. Navigate to: $PROJECT_DIR"
    echo "   3. Right-click on Package.swift → 'Download Now'"
    echo "   4. Wait for download (cloud icon will disappear)"
    echo "   5. Run the script again"
    echo ""
    echo "⏳ Waiting 10 seconds for manual download..."
    sleep 10
    
    # Final check
    if ! check_file "Package.swift"; then
        echo "❌ Package.swift is still unavailable. Aborting."
        exit 1
    fi
fi

# Download Sources directory if needed
if [ -d "Sources" ]; then
    echo "📥 Checking Sources/..."
    # Try to read any file from Sources for verification
    if find Sources -type f -name "*.swift" -exec head -c 1 {} \; -quit > /dev/null 2>&1; then
        echo "✅ Sources/ is available"
    else
        echo "📥 Attempting to download Sources/ from iCloud..."
        brctl download "Sources/" 2>/dev/null || \
        brctl download "./Sources" 2>/dev/null || \
        echo "   Use Finder for manual download"
        sleep 2
    fi
fi

# Clear cache
echo ""
echo "🧹 Clearing build cache..."
rm -rf .build

# Build project
echo "🔨 Building project..."
swift build

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Build successful!"
    echo ""
    
    # Start LangGraph server in background
    LANGGRAPH_DIR="$(dirname "$PROJECT_DIR")/langgraph_server"
    if [ -d "$LANGGRAPH_DIR" ]; then
        echo "🚀 Starting LangGraph server..."
        cd "$LANGGRAPH_DIR" || {
            echo "⚠️  Failed to change to langgraph_server directory"
        }
        
        # Check if server is already running
        if lsof -Pi :8000 -sTCP:LISTEN -t >/dev/null 2>&1; then
            echo "✅ LangGraph server is already running on port 8000"
        else
            # Start server in background
            python -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/langgraph_server.log 2>&1 &
            LANGGRAPH_PID=$!
            echo "✅ LangGraph server started (PID: $LANGGRAPH_PID)"
            echo "   Logs: /tmp/langgraph_server.log"
            echo "   Waiting 2 seconds for server to start..."
            sleep 2
            
            # Check if server started successfully
            if ! kill -0 $LANGGRAPH_PID 2>/dev/null; then
                echo "⚠️  LangGraph server failed to start. Check /tmp/langgraph_server.log"
            else
                echo "✅ LangGraph server is ready"
            fi
        fi
        
        cd "$PROJECT_DIR" || exit 1
    else
        echo "⚠️  LangGraph server directory not found: $LANGGRAPH_DIR"
        echo "   Continuing without LangGraph server (app will use simple mode)"
    fi
    
    echo ""
    echo "🚀 Running application..."
    swift run ASAApp
    
    # Cleanup: kill LangGraph server if we started it
    if [ -n "$LANGGRAPH_PID" ] && kill -0 $LANGGRAPH_PID 2>/dev/null; then
        echo ""
        echo "🛑 Stopping LangGraph server (PID: $LANGGRAPH_PID)..."
        kill $LANGGRAPH_PID 2>/dev/null
    fi
else
    echo ""
    echo "❌ Build error"
    echo ""
    echo "💡 Try:"
    echo "   1. Make sure all files are downloaded from iCloud"
    echo "   2. Check internet connection (for downloading dependencies)"
    echo "   3. Run: cd $PROJECT_DIR && rm -rf .build && swift package clean"
    exit 1
fi


