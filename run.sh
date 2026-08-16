#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.llmfailoverproxy.pid"
LOG_FILE="$SCRIPT_DIR/llmfailoverproxy.log"
PORT="${PORT:-4000}"
HOST="${HOST:-127.0.0.1}"

# Helper to find litellm binary dynamically
find_litellm_bin() {
    local bin=""
    if [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -x "$VIRTUAL_ENV/bin/litellm" ]]; then
        bin="$VIRTUAL_ENV/bin/litellm"
    else
        bin=$(find "$SCRIPT_DIR" -maxdepth 3 -type f -name litellm -path "*/bin/litellm" 2>/dev/null | head -n 1 || true)
    fi

    if [[ -z "$bin" ]] || [[ ! -x "$bin" ]]; then
        if command -v litellm >/dev/null 2>&1; then
            bin="$(command -v litellm)"
        else
            echo "Error: litellm executable not found." >&2
            echo "Please create a virtual environment in this directory and install requirements:" >&2
            echo "  python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt" >&2
            return 1
        fi
    fi
    echo "$bin"
}

load_env() {
    if [[ -f "$SCRIPT_DIR/llm-failover.env" ]]; then
        # shellcheck disable=SC1091
        set -a
        source "$SCRIPT_DIR/llm-failover.env"
        set +a
    fi
}

get_pid() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi

    # Fallback: check if litellm is running with this config
    local proc_pid
    proc_pid=$(pgrep -f "litellm.*${SCRIPT_DIR}/config\.yaml" 2>/dev/null | head -n 1 || true)
    if [[ -z "$proc_pid" ]]; then
        proc_pid=$(pgrep -f "litellm.*config\.yaml" 2>/dev/null | head -n 1 || true)
    fi

    if [[ -n "$proc_pid" ]] && kill -0 "$proc_pid" 2>/dev/null; then
        echo "$proc_pid"
        return 0
    fi

    return 1
}

start_foreground() {
    load_env
    local bin
    bin=$(find_litellm_bin)
    cd "$SCRIPT_DIR"
    # LiteLLM treats the generic DEBUG environment variable as a boolean option.
    # Do not inherit unrelated values such as DEBUG=release from the caller.
    exec env -u DEBUG "$bin" --config "$SCRIPT_DIR/config.yaml" --port "$PORT" --host "$HOST" "$@"
}

start_background() {
    if local_pid=$(get_pid); then
        echo "llm-failover-proxy is already running (PID: $local_pid) on http://$HOST:$PORT"
        return 0
    fi

    load_env
    local bin
    bin=$(find_litellm_bin)

    echo "Starting llm-failover-proxy in background..."
    cd "$SCRIPT_DIR"
    # See start_foreground: prevent unrelated DEBUG values from breaking Click parsing.
    nohup env -u DEBUG "$bin" --config "$SCRIPT_DIR/config.yaml" --port "$PORT" --host "$HOST" > "$LOG_FILE" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"

    # Wait briefly for startup verification
    local count=0
    while [[ $count -lt 15 ]]; do
        if kill -0 "$new_pid" 2>/dev/null; then
            if curl -s "http://$HOST:$PORT/health/liveliness" 2>/dev/null | grep -q "alive"; then
                echo "✓ llm-failover-proxy started successfully (PID: $new_pid) on http://$HOST:$PORT"
                echo "  Logs: $LOG_FILE"
                return 0
            fi
        else
            echo "✗ Failed to start llm-failover-proxy. Check logs:" >&2
            tail -n 20 "$LOG_FILE" >&2
            rm -f "$PID_FILE"
            return 1
        fi
        sleep 0.5
        count=$((count + 1))
    done

    echo "✓ llm-failover-proxy process started (PID: $new_pid), listening on http://$HOST:$PORT"
    echo "  Logs: $LOG_FILE"
}

stop_service() {
    local pid
    if pid=$(get_pid); then
        echo "Stopping llm-failover-proxy (PID: $pid)..."
        kill "$pid" 2>/dev/null || true

        local count=0
        while kill -0 "$pid" 2>/dev/null && [[ $count -lt 10 ]]; do
            sleep 0.5
            count=$((count + 1))
        done

        if kill -0 "$pid" 2>/dev/null; then
            echo "Process still running, forcing termination..."
            kill -9 "$pid" 2>/dev/null || true
        fi

        rm -f "$PID_FILE"
        echo "✓ llm-failover-proxy stopped."
    else
        rm -f "$PID_FILE"
        echo "llm-failover-proxy is not running."
    fi
}

status_service() {
    local pid
    if pid=$(get_pid); then
        echo "● llm-failover-proxy is running"
        echo "  PID: $pid"
        echo "  Endpoint: http://$HOST:$PORT"
        echo "  Health: $(curl -s "http://$HOST:$PORT/health/liveliness" 2>/dev/null || echo "not responding")"
        echo "  Logs: $LOG_FILE"
    else
        echo "○ llm-failover-proxy is stopped."
    fi
}

logs_service() {
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
    fi
    tail -f "$LOG_FILE"
}

# If the script is sourced into an interactive shell, export the shell function:
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    llmfailoverproxy() {
        "$SCRIPT_DIR/run.sh" "$@"
    }
    export -f llmfailoverproxy 2>/dev/null || true
    echo "Loaded shell function: llmfailoverproxy [start|stop|restart|status|logs|run]"
    return 0
fi

# Direct CLI execution
action="${1:-run}"
case "$action" in
    start)
        start_background
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service
        start_background
        ;;
    status)
        status_service
        ;;
    logs)
        logs_service
        ;;
    run)
        shift || true
        start_foreground "$@"
        ;;
    -h|--help|help)
        echo "Usage: ./run.sh [start|stop|restart|status|logs|run]"
        echo ""
        echo "Commands:"
        echo "  start    - Start llm-failover-proxy in the background"
        echo "  stop     - Stop the background llm-failover-proxy proxy"
        echo "  restart  - Restart the background proxy"
        echo "  status   - Check if the proxy is running and healthy"
        echo "  logs     - Follow proxy logs in real time"
        echo "  run      - Run the proxy in the foreground (default)"
        echo ""
        echo "Shell function:"
        echo "  source ./run.sh   # Enables 'llmfailoverproxy <command>' in your current shell"
        ;;
    *)
        start_foreground "$@"
        ;;
esac
