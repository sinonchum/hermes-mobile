#!/data/data/com.hermes.mobile/files/usr/bin/bash
# ==========================================================================
# Hermes Mobile — Termux Bootstrap Script
# Runs inside the Termux environment on first launch.
# Sets up Python, dependencies, and Hermes Agent.
# ==========================================================================

set -e

PREFIX="${PREFIX:-/data/data/com.hermes.mobile/files/usr}"
HOME="${HOME:-/data/data/com.hermes.mobile/files/home}"
HERMES_HOME="${HOME}/.hermes"
TMPDIR="${TMPDIR:-/data/data/com.hermes.mobile/cache}"

export PREFIX HOME HERMES_HOME TMPDIR
export PATH="${PREFIX}/bin:${PATH}"
export LANG="en_US.UTF-8"
export TERM="xterm-256color"

LOG_FILE="${HOME}/bootstrap.log"

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== Hermes Mobile Bootstrap ==="
log "PREFIX=$PREFIX"
log "HOME=$HOME"

# ── Step 1: Update package repos ──────────────────────────────────────
log "[1/6] Updating package repos..."
apt update -y 2>&1 | tail -3 >> "$LOG_FILE" || true

# ── Step 2: Install core packages ─────────────────────────────────────
log "[2/6] Installing Python & essentials..."
apt install -y \
    python \
    git \
    curl \
    openssl \
    libffi \
    clang \
    make \
    libxml2 \
    libxslt \
    2>&1 | tail -5 >> "$LOG_FILE"

# ── Step 3: Upgrade pip ───────────────────────────────────────────────
log "[3/6] Upgrading pip..."
python -m pip install --upgrade pip setuptools wheel 2>&1 | tail -3 >> "$LOG_FILE"

# ── Step 4: Clone Hermes Agent ────────────────────────────────────────
log "[4/6] Setting up Hermes Agent..."
mkdir -p "$HERMES_HOME"

if [ ! -d "${HOME}/hermes-agent" ]; then
    # Clone from the mobile branch or main
    log "  Cloning hermes-agent..."
    git clone --depth 1 \
        https://github.com/nicholasgasior/nicholasgasior.github.io.git \
        "${HOME}/hermes-agent" \
        2>&1 | tail -3 >> "$LOG_FILE" || {
        log "  WARN: Git clone failed, using bundled files"
    }
else
    log "  hermes-agent already exists, pulling updates..."
    cd "${HOME}/hermes-agent" && git pull 2>&1 | tail -3 >> "$LOG_FILE" || true
fi

# ── Step 5: Install Python dependencies ───────────────────────────────
log "[5/6] Installing Python packages..."
if [ -f "${HOME}/hermes-agent/requirements.txt" ]; then
    cd "${HOME}/hermes-agent"
    python -m pip install -r requirements.txt 2>&1 | tail -5 >> "$LOG_FILE"
fi

# Install FastAPI server dependencies
python -m pip install \
    fastapi \
    uvicorn \
    websockets \
    pydantic \
    httpx \
    2>&1 | tail -3 >> "$LOG_FILE"

# ── Step 6: Copy API server into hermes-agent ─────────────────────────
log "[6/6] Configuring API server..."
# api_server.py is copied by the Android app from assets

# ── Create startup script ─────────────────────────────────────────────
cat > "${HOME}/start_hermes.sh" << 'STARTEOF'
#!/data/data/com.hermes.mobile/files/usr/bin/bash
export PREFIX="/data/data/com.hermes.mobile/files/usr"
export HOME="/data/data/com.hermes.mobile/files/home"
export PATH="${PREFIX}/bin:${PATH}"
export LANG="en_US.UTF-8"
export HERMES_HOME="${HOME}/.hermes"
export TMPDIR="/data/data/com.hermes.mobile/cache"

cd "${HOME}/hermes-agent"
exec python api_server.py --host 127.0.0.1 --port 18923
STARTEOF
chmod +x "${HOME}/start_hermes.sh"

log "=== Bootstrap complete ✓ ==="
touch "${HOME}/.bootstrap_done"
