#!/bin/bash
# Synaps — Start Script
# Starts both backend and frontend

set -e
cd "$(dirname "$0")"

echo "🧠 Starting Synaps..."
echo ""

# Start backend
echo "🔧 Starting FastAPI backend on port 8000..."
cd backend
source venv/bin/activate
python3 main.py &
BACKEND_PID=$!
cd ..

# Wait for backend to start
sleep 2

# Start frontend
echo "🎨 Starting Next.js frontend on port 3000..."
cd frontend
npm run dev &
FRONTEND_PID=$!
cd ..

echo ""
echo "╔══════════════════════════════════════╗"
echo "║         Synaps is running! 🚀       ║"
echo "╠══════════════════════════════════════╣"
echo "║                                      ║"
echo "║  Frontend: http://localhost:3000     ║"
echo "║  Backend:  http://localhost:8000     ║"
echo "║  API Docs: http://localhost:8000/docs ║"
echo "║                                      ║"
echo "║  Press Ctrl+C to stop               ║"
echo "║                                      ║"
echo "╚══════════════════════════════════════╝"

# Handle cleanup
cleanup() {
    echo ""
    echo "Stopping Synaps..."
    kill $BACKEND_PID 2>/dev/null
    kill $FRONTEND_PID 2>/dev/null
    exit 0
}

trap cleanup SIGINT SIGTERM

# Wait for both processes
wait
