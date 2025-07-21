#!/bin/bash

# chattr2 - (v3) simple secure chat using openssl s_server and s_client
# This version fixes a critical race condition where named pipes were used
# before being created, leading to connection failures.

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
chattr2 (v3) - Secure chat with file transfer and remote command execution.

Usage:
  chattr2 server [port]
  chattr2 client <ip> [port]
  chattr2 --help

In-chat commands:
  /copy <local_file> [remote_path]   Request to send a file.
  /exec <command...>                 Request to execute a command on the peer.
  /live <command...>                 Request a fully interactive TTY session (e.g., for nano, vim, ssh).
  /help                              Show this list of commands.
  exit                               Close the chat session.

Path Shortcuts:
  \$/   Expands to YOUR home directory (e.g., /copy \$/file.txt)
  ~/   Expands to the PEER's home directory (e.g., /exec ls ~/)
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
# A dynamic temp directory is now created by the server/client modes.
TMP_DIR=""
function cleanup() {
    pkill -P $$ &>/dev/null
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    tput cnorm # Ensure cursor is visible on exit
    echo -e "\nExiting."
}
trap cleanup EXIT INT TERM

# --- Core Chat Logic ---
function start_chat() {
    local peer_name=$1
    local is_server=$2
    local openssl_pid=$3
    local PIPE_IN=$4
    local PIPE_OUT=$5

    tput civis # Hide cursor

    # Receiver subshell: Reads from PIPE_OUT and displays messages
    (
        local in_file_transfer=false
        local transfer_path=""
        local pending_req_file=""

        while read -r line; do
            echo -ne "\r\033[K" # Clear line, print message, redraw prompt
            local prefix="${line%%:*}"; local data="${line#*:}"

            case "$prefix" in
                REQ_COPY)
                    local src_b64="${data%%:*}"; local dest_b64="${data#*:}"
                    local src_file; src_file=$(echo "$src_b64" | base64 -d)
                    local dest_file; dest_file=$(echo "$dest_b64" | base64 -d)
                    dest_file="${dest_file/#\~/$HOME}" # Expand peer's home dir
                    pending_req_file=$(mktemp "$TMP_DIR/req.XXXXXX")
                    echo "REQ_COPY:$src_b64:$(echo -n "$dest_file" | base64 -w0)" > "$pending_req_file"
                    echo "--> Incoming file request: '$src_file' to '$dest_file'. Allow? (yes/no)"
                    ;;
                REQ_EXEC)
                    local cmd_b64="$data"; local cmd; cmd=$(echo "$cmd_b64" | base64 -d)
                    pending_req_file=$(mktemp "$TMP_DIR/req.XXXXXX")
                    echo "REQ_EXEC:$cmd_b64" > "$pending_req_file"
                    echo "--> Incoming exec request: '$cmd'. Allow? (yes/no)"
                    ;;
                REQ_LIVE)
                    local cmd_b64="${data%%:*}"; local peer_ip="${data#*:}"
                    local cmd; cmd=$(echo "$cmd_b64" | base64 -d)
                    pending_req_file=$(mktemp "$TMP_DIR/req.XXXXXX")
                    echo "REQ_LIVE:$cmd_b64:$peer_ip" > "$pending_req_file"
                    echo "--> Incoming interactive session request for: '$cmd'. Allow? (yes/no)"
                    ;;
                RESP_LIVE_OK)
                    echo "--> Peer accepted. Starting interactive session... (Exit command to return)"
                    tput cnorm
                    socat "TCP:$data:$LIVE_PORT" "READLINE,history=$LOCAL_HOME/.chattr2_history"
                    tput civis
                    echo "--> Interactive session ended. You are back in chat."
                    ;;
                RESP_OK) echo "--> Peer accepted the request." ;;
                RESP_NO) echo "--> Peer denied the request." ;;
                CMD_ERR)
                    local err_msg; err_msg=$(echo "$data" | base64 -d)
                    echo -e "--> Remote command failed:\n---\n$err_msg\n---"
                    ;;
                FILE_DATA) if [[ "$in_file_transfer" == true ]]; then echo "$data" | base64 -d >> "$transfer_path"; fi ;;
                FILE_BEGIN)
                    in_file_transfer=true; transfer_path="$data";
                    echo "--> Receiving file to '$transfer_path'..."
                    mkdir -p "$(dirname "$transfer_path")" && >"$transfer_path"
                    ;;
                FILE_END) in_file_transfer=false; echo "--> File transfer to '$transfer_path' complete."; transfer_path="" ;;
                CMD_OUT) echo "[Remote]: $data" ;;
                INFO) echo "[$peer_name Info]: $data" ;;
                *) echo "[$peer_name]: $line" ;;
            esac
            echo -n "You: ${READLINE_LINE}"
        done < "$PIPE_OUT"
        
        echo -e "\r\033[K--> $peer_name disconnected."
        kill $$ # Exit cleanly
    ) &

    # Sender loop: Reads user input and writes to PIPE_IN
    exec 3>"$PIPE_IN"
    while READLINE_LINE="" read -r -e -p "You: " msg; do
        local pending_req_file; pending_req_file=$(find "$TMP_DIR" -name "req.??????")

        if [[ -f "$pending_req_file" ]]; then
            local req_line; req_line=$(cat "$pending_req_file")
            local req_prefix="${req_line%%:*}"; local req_data="${req_line#*:}"

            if [[ "$msg" =~ ^[yY]([eE][sS])?$ ]]; then
                echo "RESP_OK" >&3
                if [[ "$req_prefix" == "REQ_COPY" ]]; then
                    local dest_file; dest_file=$(echo "${req_data#*:}" | base64 -d)
                    echo "FILE_BEGIN:$dest_file" >&3
                elif [[ "$req_prefix" == "REQ_EXEC" ]]; then
                    local cmd_to_run; cmd_to_run=$(echo "$req_data" | base64 -d)
                    echo "INFO:Executing '$cmd_to_run'..." >&3
                    local output; output=$(bash -c "$cmd_to_run" 2>&1); local status=$?
                    if [[ $status -ne 0 ]]; then
                        echo "CMD_ERR:$(echo -n "$output" | base64 -w 0)" >&3
                    else
                        while IFS= read -r output_line; do echo "CMD_OUT:$output_line" >&3; done <<< "$output"
                    fi
                elif [[ "$req_prefix" == "REQ_LIVE" ]]; then
                    local cmd_b64="${req_data%%:*}"; local peer_ip="${req_data#*:}"
                    local cmd_to_run; cmd_to_run=$(echo "$cmd_b64" | base64 -d)
                    echo "RESP_LIVE_OK:$peer_ip" >&3
                    echo "--> Accepted. Starting interactive session for peer..."
                    tput cnorm
                    $SUDO_CMD socat "TCP-LISTEN:$LIVE_PORT,reuseaddr,fork" "EXEC:'$cmd_to_run',pty,stderr,setsid,sigint,sane"
                    tput civis
                    echo "--> Peer's interactive session ended."
                fi
            else
                echo "RESP_NO" >&3; echo "--> Denied request."
            fi
            rm -f "$pending_req_file"

        elif [[ "$msg" == /* ]]; then
            msg="${msg//\$'/'/$LOCAL_HOME}"
            read -r -a cmd_parts <<< "$msg"
            case "${cmd_parts[0]}" in
                "/copy")
                    local local_file="${cmd_parts[1]}"; local remote_file="${cmd_parts[2]}"
                    if [[ ! -f "$local_file" ]]; then echo "Error: File '$local_file' not found."; continue; fi
                    if [[ -z "$remote_file" ]]; then remote_file=$(basename -- "$local_file"); fi
                    echo "REQ_COPY:$(echo -n "$local_file" | base64 -w0):$(echo -n "$remote_file" | base64 -w0)" >&3
                    echo "--> Requesting to send '$local_file'. Waiting..."
                    ( while read -r line; do
                        if [[ "${line%%:*}" == "RESP_OK" ]]; then
                            echo "INFO:Sending file..." >&3
                            base64 -w 0 "$local_file" | while IFS= read -r -n 4096 chunk; do echo "FILE_DATA:$chunk" >&3; done
                            echo "FILE_END" >&3
                            break
                        elif [[ "${line%%:*}" == "RESP_NO" ]]; then break; fi
                      done < "$PIPE_OUT" ) &
                    ;;
                "/exec")
                    local cmd_to_req="${msg#*/exec }"; if [[ -z "$cmd_to_req" ]]; then echo "Usage: /exec <command...>"; continue; fi
                    echo "REQ_EXEC:$(echo -n "$cmd_to_req" | base64 -w0)" >&3
                    echo "--> Requesting to execute on peer. Waiting..."
                    ;;
                "/live")
                    local cmd_to_req="${msg#*/live }"; if [[ -z "$cmd_to_req" ]]; then echo "Usage: /live <command...>"; continue; fi
                    local local_ip; local_ip=$(ss -tnp | grep "$openssl_pid" | grep 'ESTAB' | awk '{print $4}' | head -n1 | cut -d: -f1)
                    if [[ -z "$local_ip" ]]; then echo "Error: Could not determine local IP."; continue; fi
                    echo "REQ_LIVE:$(echo -n "$cmd_to_req" | base64 -w0):$local_ip" >&3
                    echo "--> Requesting interactive session. Waiting..."
                    ;;
                "/help") show_help; ;;
                *) echo "Unknown command: ${cmd_parts[0]}." ;;
            esac
        elif [[ "$msg" == "exit" ]]; then
            break
        else
            if ! ps -p $openssl_pid > /dev/null; then echo "Connection lost."; break; fi
            echo "$msg" >&3
        fi
    done
    exec 3>&-
}

function server_mode() {
    local port_arg=$1; if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then PORT=$port_arg; fi
    local cert_file; cert_file=$(generate_cert)

    while true; do
        # For each new session, create a unique directory and the pipes within it.
        TMP_DIR=$(mktemp -d "/tmp/chattr2.server.$$.XXXXXX")
        local PIPE_IN="$TMP_DIR/in"
        local PIPE_OUT="$TMP_DIR/out"
        mkfifo "$PIPE_IN" "$PIPE_OUT" # <-- FIX: Create pipes BEFORE they are used.

        echo "Starting chattr2 server on port $PORT... (Ctrl+C to stop)"
        (
            $SUDO_CMD openssl s_server -n -N -brief -accept "$PORT" -cert "$cert_file" -quiet < "$PIPE_IN" > "$PIPE_OUT" 2>/dev/null &
            local openssl_pid=$!
            
            echo "Waiting for a client to connect..."
            until ss -tnp | grep -q "$openssl_pid.*ESTAB"; do
                if ! ps -p $openssl_pid > /dev/null; then exit; fi
                sleep 0.5
            done
            
            echo "Client connected. (Type /help or 'exit')"
            start_chat "Client" "true" "$openssl_pid" "$PIPE_IN" "$PIPE_OUT"
        )
        
        # Cleanup the temp dir for the session that just ended.
        rm -rf "$TMP_DIR"
        echo "Session ended. Server is ready for a new connection."
        sleep 1
    done
}

function client_mode() {
    local server_ip=$1; local port_arg=$2
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then PORT=$port_arg; fi

    # Create a unique directory and pipes for the client session.
    TMP_DIR=$(mktemp -d "/tmp/chattr2.client.$$.XXXXXX")
    local PIPE_IN="$TMP_DIR/in"
    local PIPE_OUT="$TMP_DIR/out"
    mkfifo "$PIPE_IN" "$PIPE_OUT" # <-- FIX: Create pipes BEFORE they are used.

    echo "Connecting to $server_ip:$PORT ..."
    openssl s_client -connect "$server_ip:$PORT" -quiet < "$PIPE_IN" > "$PIPE_OUT" 2>/dev/null &
    local openssl_pid=$!

    sleep 0.5
    if ! ps -p $openssl_pid > /dev/null; then
       echo "Connection failed. Is the server running at $server_ip:$PORT?" >&2; exit 1
    fi

    echo "Connected. (Type /help or 'exit')"
    start_chat "Server" "false" "$openssl_pid" "$PIPE_IN" "$PIPE_OUT"
}

# --- Main Execution Logic ---
case "$1" in
    server) server_mode "${@:2}"; ;;
    client) if [[ -z "$2" ]]; then echo "Error: Missing server IP." >&2; show_help; exit 1; fi; client_mode "${@:2}"; ;;
    --help|-h) show_help; ;;
    ""|*) if [[ -n "$1" ]]; then echo "Error: Invalid command '$1'." >&2; fi; show_help; exit 1 ;;
esac
