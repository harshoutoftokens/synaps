#!/bin/bash
# Synaps — Setup Script
# Run this once to set up the environment

set -e
cd "$(dirname "$0")"

echo "╔══════════════════════════════════════╗"
echo "║        Synaps — Initial Setup        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Detect OS
if [[ "$(uname)" == "Linux" ]]; then
    echo "🐧 Detected Linux (NAS mode)"
    echo ""

    # Install system dependencies for thumbnails
    echo "📦 Installing system dependencies..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq ffmpeg poppler-utils libheif-dev 2>/dev/null || {
            echo "⚠️  Some optional packages may not be available."
            echo "   ffmpeg     — required for video thumbnails"
            echo "   poppler-utils — optional for PDF thumbnails"
            echo "   libheif-dev   — optional for HEIC support"
        }
    fi
elif [[ "$(uname)" == "Darwin" ]]; then
    echo "🍎 Detected macOS (development mode)"
    echo ""

    if command -v brew &> /dev/null; then
        echo "📦 Installing system dependencies via Homebrew..."
        brew install ffmpeg poppler libheif 2>/dev/null || true
    fi
fi

# Backend setup
echo ""
echo "📦 Setting up Python backend..."
cd backend

if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    echo "❌ Python 3.10 or newer is required (found $(python3 --version 2>&1))."
    exit 1
fi

if [ ! -d "venv" ]; then
    python3 -m venv venv
    echo "  Created virtual environment"
fi

source venv/bin/activate
pip install -q -r requirements.txt
echo "✅ Backend dependencies installed"
if [ ! -f .env ]; then
    echo "  Optional settings (storage path, API token, ...): cp backend/.env.example backend/.env"
fi

cd ..

# Frontend setup
echo ""
echo "📦 Setting up Next.js frontend..."
cd frontend
if [ -f package-lock.json ]; then
    npm ci --silent
else
    npm install --silent
fi
echo "✅ Frontend dependencies installed"

# Build for production
echo ""
echo "🏗  Building frontend for production..."
npm run build
echo "✅ Production build complete"

cd ..

echo ""
echo "╔══════════════════════════════════════╗"
echo "║          Setup Complete! 🎉          ║"
echo "╠══════════════════════════════════════╣"
echo "║                                      ║"
echo "║  Development:  ./start.sh            ║"
echo "║  Production:   ./start-prod.sh       ║"
echo "║                                      ║"
echo "╚══════════════════════════════════════╝"
