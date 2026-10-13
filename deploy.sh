#!/bin/bash
# deploy.sh
# Run this on your MacBook to push changes
#
# Commits only changes to files git already tracks - never new/untracked files such as logs,
# .env, databases or personal scripts - shows exactly what will be committed and asks first.
#   ./deploy.sh "Commit message"
#   DEPLOY_YES=1 ./deploy.sh "Commit message"    # no confirmation prompt

set -euo pipefail
cd "$(dirname "$0")"

echo "🚀 Deploying Synaps..."

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "❌ On branch '$BRANCH' - this script pushes main. Switch branches (or push yourself)."
    exit 1
fi

UNTRACKED=$(git ls-files --others --exclude-standard)
if [ -n "$UNTRACKED" ]; then
    echo "⚠️  Untracked files are NOT included (git add them yourself if they belong in the repo):"
    echo "$UNTRACKED" | sed 's/^/     /'
fi

# Stage changes and deletions of tracked files only
git add -u

SENSITIVE=$(git diff --cached --name-only | grep -E '(^|/)\.env$|\.(db|sqlite3?|log|pem|key)$' || true)
if [ -n "$SENSITIVE" ]; then
    echo "❌ Refusing to commit these files:"
    echo "$SENSITIVE" | sed 's/^/     /'
    echo "   Unstage them (git restore --staged <file>) and stop tracking them (git rm --cached <file>)."
    exit 1
fi

if git diff --cached --quiet; then
    echo "No tracked changes to commit."
else
    echo "📋 Changes to be committed:"
    git diff --cached --stat
    if [ "${DEPLOY_YES:-0}" != "1" ]; then
        read -r -p "Commit and push these changes? [y/N] " answer || answer=""
        case "$answer" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "Aborted - nothing committed (changes are left staged; 'git reset' unstages them)."; exit 1 ;;
        esac
    fi
    # Commit with a default or provided message
    COMMIT_MSG=${1:-"Update Synaps"}
    git commit -m "$COMMIT_MSG"
fi

# Push to origin
git push origin main

echo "✅ Push complete!"
echo "Now SSH into your NAS and run ./update.sh"
