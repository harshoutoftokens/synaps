#!/bin/bash
# update.sh
# Run this on your NAS to pull and build the latest changes.
# Nothing is restarted unless the new backend imports and the frontend builds, so a broken
# update leaves the running version serving.

set -eu
cd "$(dirname "$0")"

# Opt-in static-frontend mode: SYNAPS_FRONTEND_DIST (environment or backend/.env) makes the
# backend serve the web app's static export, so there is no Node.js server to restart.
frontend_dist() {
    if [ -n "${SYNAPS_FRONTEND_DIST:-}" ]; then echo "$SYNAPS_FRONTEND_DIST"; return; fi
    [ -f backend/.env ] || return 0
    sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}SYNAPS_FRONTEND_DIST[[:space:]]*=[[:space:]]*//p' backend/.env \
        | tail -n 1 | tr -d "\"'"
}
FRONTEND_DIST=$(frontend_dist)

echo "🔄 Updating Synaps..."

# Pull latest changes (fast-forward only: never create merge commits on the NAS)
PREVIOUS=$(git rev-parse HEAD)
git pull --ff-only origin main

# Update backend dependencies
echo "📦 Updating backend..."
cd backend
set +u; source venv/bin/activate; set -u
pip install -r requirements.txt

echo "🔎 Checking that the backend imports..."
if ! python -c "import main" >/dev/null; then
    echo "❌ The new backend does not import - services were NOT restarted (the previous"
    echo "   version keeps running). Put the previous code back with: git reset --hard $PREVIOUS"
    exit 1
fi
cd ..

# Update and build frontend
echo "📦 Updating frontend..."
cd frontend
if [ -f package-lock.json ]; then
    npm ci  # exact versions from the lockfile
else
    npm install
fi
if [ -n "$FRONTEND_DIST" ]; then
    echo "🏗 Building the static web app (served by the backend from $FRONTEND_DIST)..."
    npm run build:static
else
    echo "🏗 Building optimized frontend for production..."
    npm run build
fi
cd ..

# Restart services
echo "🔄 Restarting systemd services..."
UNITS=$(systemctl list-unit-files 2>/dev/null || true)
if echo "$UNITS" | grep synaps-backend >/dev/null; then
    sudo systemctl restart synaps-backend
    if [ -n "$FRONTEND_DIST" ]; then
        echo "ℹ️  Static web app mode: synaps-frontend not restarted (the backend serves the web app;"
        echo "   the Node service can be turned off with: sudo systemctl disable --now synaps-frontend)"
    elif echo "$UNITS" | grep synaps-frontend >/dev/null; then
        sudo systemctl restart synaps-frontend
    fi

    if command -v curl >/dev/null; then
        HEALTH_URL="http://127.0.0.1:${SYNAPS_PORT:-8000}/api/health"
        for _ in $(seq 1 30); do
            if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
                echo "✅ Update complete! Synaps is back online."
                exit 0
            fi
            sleep 1
        done
        echo "⚠️ Backend did not answer $HEALTH_URL within 30 s. Check: sudo journalctl -u synaps-backend -n 50"
        echo "   To roll back: git reset --hard $PREVIOUS, rebuild the frontend (cd frontend && npm ci &&"
        echo "   npm run build), then sudo systemctl restart synaps-backend synaps-frontend"
        exit 1
    fi
    echo "✅ Update complete! Synaps is back online."
else
    echo "⚠️ Systemd services not found. You can start the app manually:"
    echo "   ./start-prod.sh"
fi
