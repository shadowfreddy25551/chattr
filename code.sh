#!/bin/bash

# chattr2 - (v4 fixed) simple secure chat using openssl s_server and s_client
# Fixes: proper FIFO usage, signal handling, foreground process management,
# non-blocking I/O, and clean exit with Ctrl+C.

DEFAULT_PORT=12345
LIVE_PORT=12346 # Port for the /live command

# --- Dependency Checks ---
for cmd in openssl socat ss; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Core dependency '$cmd' is not installed. Please install it." >&2
        echo "e.g., sudo apt-get install openssl socat iproute2" >&2
        exit 1
    fi
done

# --- Sudo Check ---
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
chattr2 (v4) - Secure chat with file transfer and remote command execution.

Usage:
  chattr2 server [port]
  chattr2 client <ip> [port]
  chattr2 --help

In-chat commands:
  /copy <local_file> [remote_path]   Request to send a file.
  /exec <command...>                 Request to execute a command on the peer.
  /live <command...>                 Request a fully interactive TTY session (e.g., nano, vim, ssh).
  /help                             Show this list of commands.
  exit                             Close the chat session.

Path Shortcuts:
  \$/   Expands to YOUR home directory (e.g., /copy \$/file.txt)
  ~/    Expands to the PEER's home directory (e.g., /exec ls ~/)
EOF
}

# --- Certificate Management ---
function generate_cert() {
    local cert_dir="/tmp/chattr2_certs"
    mkdir -p "$cert_dir"
    local cert_path="$cert_dir/chattr2_server.pem"
    if [[ ! -f "$cert_path" ]]; then
        echo "Generating self-signed certificate in $cert_path..." >&2
        openssl req -newkey rsa:2048 -nodes -keyout "$cert_path" -x509 -days 365 -out "$cert_path" \
            -subj "/CN=chattr2.local" &>/dev/null
    fi
    echo "$cert_path"
}

# --- Cleanup ---
TMP_DIR=""
OPENSSL_PID=""
RECEIVER_PID=""
SENDER_PID=""

function cleanup() {
    tput cnorm  # Restore cursor on exit
    [[ -n $OPENSSL_PID ]] && kill "$OPENSSL_PID" 2>/dev/null
    [[ -n $RECEIVER_PID ]] && kill "$RECEIVER_PID" 2>/dev/null
    [[ -n $SENDER_PID ]] && kill "$SENDER_PID" 2>/dev/null
    [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"
    echo -e "\nExiting."
}
trap cleanup EXIT INT TERM

# --- Core Chat Logic ---
function start_chat() {
    local peer_name=$1
    local openssl_pid=$2
    local PIPE_IN=$3
    local PIPE_OUT=$4

    tput civis # Hide cursor

    # Receiver loop (runs in background)
    (
        while read -r line; do
            echo -ne "\r\033[K"
            local prefix="${line%%:*}"
            local data="${line#*:}"

            case "$prefix" in
                REQ_COPY)
                    local src_b64="${data%%:*}"; local dest_b64="${data#*:}"
                    local src_file=$(echo "$src_b64" | base64 -d)
                    local dest_file=$(echo "$dest_b64" | base64 -d)
                    dest_file="${dest_file/#\~/$HOME}"
                    echo "--> Incoming file request: '$src_file' to '$dest_file'. Allow? (yes/no)"
                    ;;
                REQ_EXEC)
                    local cmd_b64="$data"
                    local cmd=$(echo "$cmd_b64" | base64 -d)
                    echo "--> Incoming exec request: '$cmd'. Allow? (yes/no)"
                    ;;
                REQ_LIVE)
                    local cmd_b64="${data%%:*}"
                    local peer_ip="${data#*:}"
                    local cmd=$(echo "$cmd_b64" | base64 -d)
                    echo "--> Incoming interactive session request: '$cmd'. Allow? (yes/no)"
                    ;;
                RESP_LIVE_OK)
                    echo "--> Peer accepted. Starting interactive session..."
                    tput cnorm
                    socat "TCP:$data:$LIVE_PORT" "READLINE,history=$LOCAL_HOME/.chattr2_history"
                    tput civis
                    echo "--> Interactive session ended."
                    ;;
                RESP_OK) echo "--> Peer accepted the request." ;;
                RESP_NO) echo "--> Peer denied the request." ;;
                CMD_ERR) echo -e "--> Remote command failed:\n---\n$(echo "$data" | base64 -d)\n---" ;;
                FILE_DATA)
                    if [[ -f "$TMP_DIR/transfer" ]]; then
                        local transfer_path
                        transfer_path=$(cat "$TMP_DIR/transfer")
                        echo "$data" | base64 -d >> "$transfer_path"
                    fi
                    ;;
                FILE_BEGIN)
                    local transfer_path="$data"
                    echo "$transfer_path" > "$TMP_DIR/transfer"
                    echo "--> Receiving file to '$transfer_path'..."
                    mkdir -p "$(dirname "$transfer_path")" && >"$transfer_path"
                    ;;
                FILE_END)
                    rm -f "$TMP_DIR/transfer"
                    echo "--> File transfer complete."
                    ;;
                CMD_OUT) echo "[Remote]: $data" ;;
                INFO) echo "[$peer_name Info]: $data" ;;
                *) echo "[$peer_name]: $line" ;;
            esac
            echo -n "You: "
        done < "$PIPE_OUT"
    ) &
    RECEIVER_PID=$!

    # Sender loop (foreground)
    exec 3>"$PIPE_IN"
    while true; do
        # Using 'read -e -p' properly to allow input
        read -e -p "You: " msg || break

        # Find pending requests
        local pending_req_file=$(find "$TMP_DIR" -name "req.??????" 2>/dev/null | head -n1)

        if [[ -f "$pending_req_file" ]]; then
            local req_line
            req_line=$(cat "$pending_req_file")
            local req_prefix="${req_line%%:*}"
            local req_data="${req_line#*:}"

            if [[ "$msg" =~ ^[yY]([eE][sS])?$ ]]; then
                echo "RESP_OK" >&3
                if [[ "$req_prefix" == "REQ_COPY" ]]; then
                    echo "FILE_BEGIN:$req_data" >&3
                elif [[ "$req_prefix" == "REQ_EXEC" ]]; then
                    local cmd_to_run
                    cmd_to_run=$(echo "$req_data" | base64 -d)
                    echo "INFO:Executing '$cmd_to_run'..." >&3
                    local output
                    output=$(bash -c "$cmd_to_run" 2>&1)
                    local status=$?
                    if [[ $status -ne 0 ]]; then
                        echo "CMD_ERR:$(echo -n "$output" | base64 -w0)" >&3
                    else
                        while IFS= read -r l; do echo "CMD_OUT:$l" >&3; done <<< "$output"
                    fi
                elif [[ "$req_prefix" == "REQ_LIVE" ]]; then
                    local cmd_b64="${req_data%%:*}"
                    local peer_ip="${req_data#*:}"
                    local cmd_to_run
                    cmd_to_run=$(echo "$cmd_b64" | base64 -d)
                    echo "RESP_LIVE_OK:$peer_ip" >&3
                    echo "--> Accepted. Starting interactive session for peer..."
                    tput cnorm
                    $SUDO_CMD socat "TCP-LISTEN:$LIVE_PORT,reuseaddr,fork" "EXEC:'$cmd_to_run',pty,stderr,setsid,sigint,sane"
                    tput civis
                    echo "--> Peer's session ended."
                fi
                rm -f "$pending_req_file"
            else
                echo "RESP_NO" >&3
                echo "--> Denied request."
                rm -f "$pending_req_file"
            fi
        elif [[ "$msg" == /* ]]; then
            msg="${msg//\$'/'/$LOCAL_HOME}"
            read -r -a cmd_parts <<< "$msg"
            case "${cmd_parts[0]}" in
                "/copy")
                    local local_file="${cmd_parts[1]}"
                    local remote_file="${cmd_parts[2]:-$(basename -- "${cmd_parts[1]}")}"
                    if [[ ! -f "$local_file" ]]; then
                        echo "Error: File '$local_file' not found."
                        continue
                    fi
                    echo "REQ_COPY:$(echo -n "$local_file" | base64 -w0):$(echo -n "$remote_file" | base64 -w0)" >&3
                    ( while read -r line; do
                        if [[ "${line%%:*}" == "RESP_OK" ]]; then
                            echo "INFO:Sending file..." >&3
                            base64 -w0 "$local_file" | while IFS= read -r -n 4096 chunk; do echo "FILE_DATA:$chunk" >&3; done
                            echo "FILE_END" >&3
                            break
                        elif [[ "${line%%:*}" == "RESP_NO" ]]; then
                            break
                        fi
                    done < "$PIPE_OUT" ) &
                    ;;
                "/exec")
                    local cmd_to_req="${msg#*/exec }"
                    if [[ -z "$cmd_to_req" ]]; then
                        echo "Usage: /exec <command...>"
                    else
                        echo "REQ_EXEC:$(echo -n "$cmd_to_req" | base64 -w0)" >&3
                    fi
                    ;;
                "/live")
                    local cmd_to_req="${msg#*/live }"
                    if [[ -z "$cmd_to_req" ]]; then
                        echo "Usage: /live <command...>"
                        continue
                    fi
                    local local_ip
                    local_ip=$(ss -tnp | grep "$openssl_pid" | grep 'ESTAB' | awk '{print $4}' | head -n1 | cut -d: -f1)
                    if [[ -z "$local_ip" ]]; then
                        echo "Error: Could not determine local IP."
                        continue
                    fi
                    echo "REQ_LIVE:$(echo -n "$cmd_to_req" | base64 -w0):$local_ip" >&3
                    ;;
                "/help")
                    show_help
                    ;;
                *)
                    echo "Unknown command: ${cmd_parts[0]}."
                    ;;
            esac
        elif [[ "$msg" == "exit" ]]; then
            break
        else
            if ! ps -p "$openssl_pid" > /dev/null; then
                echo "Connection lost."
                break
            fi
            echo "$msg" >&3
        fi
    done

    exec 3>&-
    kill "$RECEIVER_PID" 2>/dev/null
    wait "$RECEIVER_PID" 2>/dev/null
    tput cnorm
}

function server_mode() {
    local port_arg=$1
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    else
        PORT=$DEFAULT_PORT
    fi
    local cert_file
    cert_file=$(generate_cert)

    while true; do
        TMP_DIR=$(mktemp -d "/tmp/chattr2.server.$$.XXXXXX")
        local PIPE_IN="$TMP_DIR/in"
        local PIPE_OUT="$TMP_DIR/out"
        mkfifo "$PIPE_IN" "$PIPE_OUT"

        echo "Starting chattr2 server on port $PORT... (Ctrl+C to stop)"

        # Run openssl s_server in background with proper redirection
        $SUDO_CMD openssl s_server -n -N -brief -accept "$PORT" -cert "$cert_file" -quiet <"$PIPE_IN" >"$PIPE_OUT" 2>/dev/null &
        OPENSSL_PID=$!

        echo "Waiting for a client to connect..."
        until ss -tnp | grep -q "$OPENSSL_PID.*ESTAB"; do
            if ! ps -p $OPENSSL_PID > /dev/null; then
                echo "OpenSSL server process exited unexpectedly."
                break 2
            fi
            sleep 0.5
        done

        echo "Client connected. (Type /help or 'exit')"
        start_chat "Client" "$OPENSSL_PID" "$PIPE_IN" "$PIPE_OUT"

        kill "$OPENSSL_PID" 2>/dev/null
        wait "$OPENSSL_PID" 2>/dev/null
        rm -rf "$TMP_DIR"
        echo "Session ended. Server is ready for a new connection."
        sleep 1
    done
}

function client_mode() {
    local server_ip=$1
    local port_arg=$2
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    else
        PORT=$DEFAULT_PORT
    fi

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

    echo "Connected. (Type /help or 'exit')"
    start_chat "Server" "$OPENSSL_PID" "$PIPE_IN" "$PIPE_OUT"

    kill "$OPENSSL_PID" 2>/dev/null
    wait "$OPENSSL_PID" 2>/dev/null
    rm -rf "$TMP_DIR"
}

# --- Main Execution Logic ---
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
    --help|-h)
        show_help
        ;;
    "")
        show_help
        ;;
    *)
        echo "Error: Invalid command '$1'." >&2
        show_help
        exit 1
        ;;
esac
