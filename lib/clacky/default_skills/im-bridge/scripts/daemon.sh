#!/bin/bash
# IM Bridge daemon management script

set -e

BRIDGE_DIR="$HOME/.clacky/im-bridge"
RUNTIME_DIR="$BRIDGE_DIR/runtime"
LOG_DIR="$BRIDGE_DIR/logs"
PID_FILE="$RUNTIME_DIR/bridge.pid"
LOG_FILE="$LOG_DIR/bridge.log"

# Ensure directories exist
mkdir -p "$RUNTIME_DIR" "$LOG_DIR"

# Get daemon executable path
DAEMON_BIN="clacky-im-bridge"

# Check if daemon is running
is_running() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            return 0
        else
            # Stale PID file
            rm -f "$PID_FILE"
        fi
    fi

    # Also check for any orphaned clacky-im-bridge process
    ORPHAN_PID=$(pgrep -f "clacky-im-bridge$" 2>/dev/null | head -1)
    if [ -n "$ORPHAN_PID" ]; then
        echo "$ORPHAN_PID" > "$PID_FILE"
        return 0
    fi

    return 1
}

# Start daemon
start() {
    if is_running; then
        echo "IM bridge is already running (PID: $(cat "$PID_FILE"))"
        return 1
    fi

    echo "Starting IM bridge daemon..."

    # Start daemon in background
    nohup "$DAEMON_BIN" >> "$LOG_FILE" 2>&1 &

    # Wait a moment and check if it started
    sleep 2

    if is_running; then
        echo "✅ IM bridge started (PID: $(cat "$PID_FILE"))"
        echo "   Logs: $LOG_FILE"
    else
        echo "❌ Failed to start IM bridge. Check logs:"
        tail -20 "$LOG_FILE"
        return 1
    fi
}

# Stop daemon
stop() {
    if ! is_running; then
        echo "IM bridge is not running"
        return 0
    fi

    PID=$(cat "$PID_FILE")
    echo "Stopping IM bridge (PID: $PID)..."

    kill "$PID" 2>/dev/null || true

    # Wait for graceful shutdown (max 10 seconds)
    for i in {1..10}; do
        if ! ps -p "$PID" > /dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    # Force kill if still running
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "Force killing..."
        kill -9 "$PID" 2>/dev/null || true
    fi

    # Kill any remaining orphaned processes
    pkill -f "clacky-im-bridge$" 2>/dev/null || true

    rm -f "$PID_FILE"
    echo "✅ IM bridge stopped"
}

# Show status
status() {
    if is_running; then
        PID=$(cat "$PID_FILE")
        echo "✅ IM bridge is running (PID: $PID)"

        # Show status file if exists
        STATUS_FILE="$RUNTIME_DIR/status.json"
        if [ -f "$STATUS_FILE" ]; then
            echo ""
            echo "Status:"
            cat "$STATUS_FILE"
        fi
    else
        echo "❌ IM bridge is not running"

        # Show last error if exists
        STATUS_FILE="$RUNTIME_DIR/status.json"
        if [ -f "$STATUS_FILE" ]; then
            ERROR=$(grep -o '"error":"[^"]*"' "$STATUS_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
            if [ -n "$ERROR" ]; then
                echo "   Last error: $ERROR"
            fi
        fi
    fi
}

# Show logs
logs() {
    LINES="${1:-50}"

    if [ ! -f "$LOG_FILE" ]; then
        echo "No logs found at $LOG_FILE"
        return 1
    fi

    tail -n "$LINES" "$LOG_FILE"
}

# Restart daemon
restart() {
    stop
    sleep 1
    start
}

# Main command dispatcher
case "${1:-}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    logs)
        logs "${2:-50}"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs [N]}"
        exit 1
        ;;
esac
