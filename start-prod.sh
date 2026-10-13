#!/bin/bash
# start-prod.sh
# Production startup script if not using systemd

set -e
cd "$(dirname "$0")"

# SYNAPS_FRONTEND_DIST (environment or backend/.env): the backend serves the static web app
frontend_dist() {
    if [ -n "${SYNAPS_FRONTEND_DIST:-}" ]; then echo "$SYNAPS_FRONTEND_DIST"; return; fi
    [ -f backend/.env ] || return 0
    sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}SYNAPS_FRONTEND_DIST[[:space:]]*=[[:space:]]*//p' backend/.env \
        | tail -n 1 | tr -d "\"'"
}
FRONTEND_DIST=$(frontend_dist)
case "$FRONTEND_DIST" in
    ""|/*) ;;
    *) FRONTEND_DIST="backend/$FRONTEND_DIST" ;;  # relative paths resolve from backend/
esac

echo "🚀 Starting Synaps in Production Mode..."

# Start backend optimized for single-core/low-power
echo "🔧 Starting FastAPI backend on port 8000..."
cd backend
source venv/bin/activate
# Using 1 worker for Core2Duo to save RAM and context switching overhead
uvicorn main:app --host 0.0.0.0 --port 8000 --workers 1 &
BACKEND_PID=$!
cd ..

# Wait for backend
sleep 2

# Start optimized frontend (not needed when the backend serves the static export itself)
FRONTEND_PID=""
if [ -n "$FRONTEND_DIST" ] && [ -d "$FRONTEND_DIST" ]; then
    echo "🎨 Web app served by the backend from $FRONTEND_DIST (http://localhost:8000)"
else
    echo "🎨 Starting Next.js frontend on port 3000..."
    cd frontend
    npm run start &
    FRONTEND_PID=$!
    cd ..
fi

echo "✅ Synaps is running in PRODUCTION mode."
echo "Press Ctrl+C to stop."

# Handle cleanup
cleanup() {
    echo ""
    echo "Stopping Synaps..."
    kill $BACKEND_PID 2>/dev/null
    [ -n "$FRONTEND_PID" ] && kill $FRONTEND_PID 2>/dev/null
    exit 0
}

trap cleanup SIGINT SIGTERM

# Wait for processes
wait
