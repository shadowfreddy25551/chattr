#!/bin/bash

DEFAULT_PORT=12345

for cmd in openssl ss; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Core dependency '$cmd' not installed. Please install." >&2
        exit 1
    fi
done

SUDO_CMD=""
if [[ "$EUID" -eq 0 ]]; then
    SUDO_CMD="sudo"
    if [[ -n "$SUDO_USER" ]]; then
        LOCAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        LOCAL_HOME=$HOME
    fi
else
    LOCAL_HOME=$HOME
fi

function show_help() {
    cat <<EOF
Usage:
  chattr2 server [port]
  chattr2 client <ip> [port]
  chattr2 --help

Commands:
/copy <local_file> [remote_path] - send file
/exec <command...>               - execute command on peer
/help                           - show this help
exit                           - quit chat

Note: /live command disabled in this version.
EOF
}

function generate_cert() {
    local cert_dir="/tmp/chattr2_certs"
    mkdir -p "$cert_dir"
    local cert_path="$cert_dir/chattr2_server.pem"
    if [[ ! -f "$cert_path" ]]; then
        openssl req -newkey rsa:2048 -nodes -keyout "$cert_path" -x509 -days 365 -out "$cert_path" -subj "/CN=chattr2.local" &>/dev/null
    fi
    echo "$cert_path"
}

TMP_DIR=""
OPENSSL_PID=""
RECEIVER_PID=""

function cleanup() {
    tput cnorm
    [[ -n $OPENSSL_PID ]] && kill "$OPENSSL_PID" 2>/dev/null
    [[ -n $RECEIVER_PID ]] && kill "$RECEIVER_PID" 2>/dev/null
    [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"
    echo -e "\nExiting."
}
trap cleanup EXIT INT TERM

function start_chat() {
    local peer_name=$1
    local openssl_pid=$2
    local PIPE_IN=$3
    local PIPE_OUT=$4

    tput civis

    # Receiver reads peer messages and prints them async
    (
        while read -r line; do
            echo -ne "\r\033[K"
            case "$line" in
                REQ_COPY:*)
                    echo "--> Incoming file request. Auto-denied."
                    echo "RESP_NO" >&3
                    ;;
                REQ_EXEC:*)
                    echo "--> Incoming exec request. Auto-denied."
                    echo "RESP_NO" >&3
                    ;;
                RESP_OK) echo "--> Peer accepted your request." ;;
                RESP_NO) echo "--> Peer denied your request." ;;
                CMD_OUT:*)
                    echo "[Remote]: ${line#CMD_OUT:}"
                    ;;
                INFO:*)
                    echo "[Info]: ${line#INFO:}"
                    ;;
                *)
                    echo "[$peer_name]: $line"
                    ;;
            esac
            echo -n "You: "
        done < "$PIPE_OUT"
    ) &
    RECEIVER_PID=$!

    exec 3>"$PIPE_IN"

    while true; do
        read -e -p "You: " msg || break

        if [[ "$msg" == "/live"* ]]; then
            echo "Error: /live command disabled in this version."
            continue
        fi

        if [[ "$msg" == /copy* || "$msg" == /exec* ]]; then
            echo "REQ_$(echo "$msg" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]'):$(echo -n "${msg#* }" | base64 -w0)" >&3
            echo "--> Sent request: $msg"
            continue
        fi

        if [[ "$msg" == "exit" ]]; then
            break
        fi

        # Send plain messages directly
        echo "$msg" >&3
    done

    exec 3>&-
    kill "$RECEIVER_PID" 2>/dev/null
    wait "$RECEIVER_PID" 2>/dev/null
    tput cnorm
}

function server_mode() {
    local port_arg=$1
    PORT=${port_arg:-$DEFAULT_PORT}

    local cert_file
    cert_file=$(generate_cert)

    while true; do
        TMP_DIR=$(mktemp -d "/tmp/chattr2.server.$$.XXXXXX")
        local PIPE_IN="$TMP_DIR/in"
        local PIPE_OUT="$TMP_DIR/out"
        mkfifo "$PIPE_IN" "$PIPE_OUT"

        echo "Starting server on port $PORT... (Ctrl+C to stop)"

        $SUDO_CMD openssl s_server -accept "$PORT" -cert "$cert_file" -quiet <"$PIPE_IN" >"$PIPE_OUT" 2>/dev/null &
        OPENSSL_PID=$!

        echo "Waiting for client..."
        until ss -tnp | grep -q "$OPENSSL_PID.*ESTAB"; do
            if ! ps -p $OPENSSL_PID > /dev/null; then
                echo "OpenSSL server process exited."
                break 2
            fi
            sleep 0.5
        done

        echo "Client connected. Type /help or exit."

        start_chat "Client" "$OPENSSL_PID" "$PIPE_IN" "$PIPE_OUT"

        kill "$OPENSSL_PID" 2>/dev/null
        wait "$OPENSSL_PID" 2>/dev/null
        rm -rf "$TMP_DIR"
        echo "Session ended. Waiting for new connection."
        sleep 1
    done
}

function client_mode() {
    local server_ip=$1
    local port_arg=$2
    PORT=${port_arg:-$DEFAULT_PORT}

    TMP_DIR=$(mktemp -d "/tmp/chattr2.client.$$.XXXXXX")
    local PIPE_IN="$TMP_DIR/in"
    local PIPE_OUT="$TMP_DIR/out"
    mkfifo "$PIPE_IN" "$PIPE_OUT"

    echo "Connecting to $server_ip:$PORT ..."
    openssl s_client -connect "$server_ip:$PORT" -quiet <"$PIPE_IN" >"$PIPE_OUT" 2>/dev/null &
    OPENSSL_PID=$!

    sleep 0.5
    if ! ps -p "$OPENSSL_PID" > /dev/null; then
        echo "Connection failed. Is the server running at $server_ip:$PORT?" >&2
        exit 1
    fi

    echo "Connected. Type /help or exit."
    start_chat "Server" "$OPENSSL_PID" "$PIPE_IN" "$PIPE_OUT"

    kill "$OPENSSL_PID" 2>/dev/null
    wait "$OPENSSL_PID" 2>/dev/null
    rm -rf "$TMP_DIR"
}

case "$1" in
    server) server_mode "${@:2}" ;;
    client)
        if [[ -z "$2" ]]; then
            echo "Error: Missing server IP." >&2
            show_help
            exit 1
        fi
        client_mode "${@:2}"
        ;;
    --help|-h) show_help ;;
    *)
        echo "Error: Invalid command '$1'."
        show_help
        exit 1
        ;;
esac
