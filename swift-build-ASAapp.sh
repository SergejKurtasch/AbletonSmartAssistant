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

# Build project in release mode
echo "🔨 Building project (release mode)..."
swift build -c release

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Build successful!"
    echo ""
    
    # Create .app bundle
    echo "📦 Creating .app bundle..."
    APP_NAME="ASAApp.app"
    APP_PATH="$PROJECT_DIR/$APP_NAME"
    BINARY_PATH="$PROJECT_DIR/.build/release/ASAApp"
    CONTENTS_PATH="$APP_PATH/Contents"
    MACOS_PATH="$CONTENTS_PATH/MacOS"
    RESOURCES_PATH="$CONTENTS_PATH/Resources"
    
    # Remove existing .app if it exists
    if [ -d "$APP_PATH" ]; then
        rm -rf "$APP_PATH"
    fi
    
    # Create directory structure
    mkdir -p "$MACOS_PATH"
    mkdir -p "$RESOURCES_PATH"
    
    # Copy binary
    cp "$BINARY_PATH" "$MACOS_PATH/ASAApp"
    chmod +x "$MACOS_PATH/ASAApp"
    
    # Create Info.plist
    cat > "$CONTENTS_PATH/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ASAApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.asaapp.ASAApp</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ASAApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>ASAApp needs access to your microphone to transcribe voice input and communicate with the AI assistant.</string>
    <key>NSCameraUsageDescription</key>
    <string>ASAApp needs access to your camera for screenshot functionality.</string>
</dict>
</plist>
EOF
    
    # Copy entitlements if they exist
    if [ -f "$PROJECT_DIR/Config/ASAApp.entitlements" ]; then
        cp "$PROJECT_DIR/Config/ASAApp.entitlements" "$RESOURCES_PATH/"
        echo "✅ Copied entitlements"
        
        # Sign the app with entitlements (ad-hoc signing for development)
        echo "🔐 Signing application with entitlements..."
        codesign --force --deep --sign - --entitlements "$RESOURCES_PATH/ASAApp.entitlements" "$APP_PATH"
        if [ $? -eq 0 ]; then
            echo "✅ Application signed successfully"
        else
            echo "⚠️  Code signing failed, but app may still work"
        fi
    else
        echo "⚠️  Entitlements file not found, skipping code signing"
    fi
    
    echo "✅ .app bundle created: $APP_PATH"
    echo ""
    echo "🚀 Running application..."
    open "$APP_PATH"
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


