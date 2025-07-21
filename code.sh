#!/bin/bash

# chattr2 - (v2) simple secure chat using openssl s_server and s_client
# This version is a major refactor to fix instability, race conditions, and UX issues.
# It introduces a robust server loop, safer command execution, proper temporary file
# management, and a clean UI during message exchange.

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
# Handles running with or without sudo, finding the correct home directory.
SUDO_CMD=""
if [[ "$EUID" -eq 0 ]]; then
    SUDO_CMD="sudo"
    # If we are root, try to find the original user for home dir context
    if [[ -n "$SUDO_USER" ]]; then
        LOCAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        # If run as root directly, home is /root
        LOCAL_HOME=$HOME
    fi
else
    LOCAL_HOME=$HOME
fi

function show_help() {
    cat <<EOF
chattr2 (v2) - Secure chat with file transfer and remote command execution.

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

Notes:
- The /live command requires 'socat' to be installed on both machines.
- The script can be run with 'sudo' if you need to bind to a privileged port (<1024).
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
# A robust cleanup function using a dedicated temp directory.
# This ensures all pipes and request files are removed on exit.
TMP_DIR=$(mktemp -d "/tmp/chattr2.$$.XXXXXX")
PIPE_IN="$TMP_DIR/in"
PIPE_OUT="$TMP_DIR/out"

function cleanup() {
    # Kill all child processes of this script gracefully
    pkill -P $$ &>/dev/null
    rm -rf "$TMP_DIR"
    tput cnorm # Ensure cursor is visible on exit
    echo -e "\nExiting."
}
trap cleanup EXIT INT TERM

# --- Core Chat Logic ---
function start_chat() {
    local peer_name=$1
    local is_server=$2
    local openssl_pid=$3

    mkfifo "$PIPE_IN" "$PIPE_OUT"

    tput civis # Hide cursor

    # This subshell reads incoming data from the peer and displays it.
    (
        local in_file_transfer=false
        local transfer_path=""
        local pending_req_file=""

        while read -r line; do
            # The core of the improved UX: clear the current line, print the message, then redraw the prompt.
            echo -ne "\r\033[K"

            local prefix="${line%%:*}"
            local data="${line#*:}"

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
                    echo "--> Peer accepted. Starting interactive session... (Exit the command to return)"
                    tput cnorm
                    # Connect our terminal to the peer's listening socat
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
                    # Ensure directory exists
                    mkdir -p "$(dirname "$transfer_path")"
                    # Create/truncate the file
                    >"$transfer_path"
                    ;;
                FILE_END) in_file_transfer=false; echo "--> File transfer to '$transfer_path' complete."; transfer_path="" ;;
                CMD_OUT) echo "[Remote]: $data" ;;
                INFO) echo "[$peer_name Info]: $data" ;;
                *) echo "[$peer_name]: $line" ;;
            esac
            # Redraw the user's prompt and current input buffer
            echo -n "You: ${READLINE_LINE}"
        done < "$PIPE_OUT"
        
        echo -e "\r\033[K--> $peer_name disconnected."
        # The connection is dead, kill the parent script to exit cleanly.
        kill $$

    ) &

    # This loop reads user input and sends it to the peer.
    exec 3>"$PIPE_IN"
    while READLINE_LINE="" read -r -e -p "You: " msg; do
        # Check for a pending request file (created by the receiver subshell)
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
                    # SAFER execution using bash -c instead of eval
                    local output; output=$(bash -c "$cmd_to_run" 2>&1); local status=$?
                    if [[ $status -ne 0 ]]; then
                        echo "CMD_ERR:$(echo -n "$output" | base64 -w 0)" >&3
                    else
                        # Stream output back line by line
                        while IFS= read -r output_line; do echo "CMD_OUT:$output_line" >&3; done <<< "$output"
                    fi
                elif [[ "$req_prefix" == "REQ_LIVE" ]]; then
                    local cmd_b64="${req_data%%:*}"; local peer_ip="${req_data#*:}"
                    local cmd_to_run; cmd_to_run=$(echo "$cmd_b64" | base64 -d)
                    
                    echo "RESP_LIVE_OK:$peer_ip" >&3
                    echo "--> Accepted. Starting interactive session for peer... (Ctrl+C in this terminal will NOT stop it)"
                    tput cnorm
                    # This socat listens and executes the command in a new PTY for the peer
                    $SUDO_CMD socat "TCP-LISTEN:$LIVE_PORT,reuseaddr,fork" "EXEC:'$cmd_to_run',pty,stderr,setsid,sigint,sane"
                    tput civis
                    echo "--> Peer's interactive session ended."
                fi
            else
                echo "RESP_NO" >&3; echo "--> Denied request."
            fi
            rm -f "$pending_req_file"

        elif [[ "$msg" == /* ]]; then
            msg="${msg//\$'/'/$LOCAL_HOME}" # Expand local home dir shortcut
            read -r -a cmd_parts <<< "$msg"
            case "${cmd_parts[0]}" in
                "/copy")
                    local local_file="${cmd_parts[1]}"
                    local remote_file="${cmd_parts[2]}"
                    if [[ ! -f "$local_file" ]]; then echo "Error: File '$local_file' not found."; continue; fi
                    if [[ -z "$remote_file" ]]; then remote_file=$(basename -- "$local_file"); fi
                    
                    local src_b64; src_b64=$(echo -n "$local_file" | base64 -w0)
                    local dest_b64; dest_b64=$(echo -n "$remote_file" | base64 -w0)
                    echo "REQ_COPY:$src_b64:$dest_b64" >&3
                    echo "--> Requesting to send '$local_file' as '$remote_file'. Waiting..."
                    # Start the file transfer upon peer's 'yes' (RESP_OK)
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
                    local cmd_b64; cmd_b64=$(echo -n "$cmd_to_req" | base64 -w0)
                    echo "REQ_EXEC:$cmd_b64" >&3
                    echo "--> Requesting to execute on peer. Waiting..."
                    ;;
                "/live")
                    local cmd_to_req="${msg#*/live }"; if [[ -z "$cmd_to_req" ]]; then echo "Usage: /live <command...>"; continue; fi
                    local local_ip;
                    # More robust IP detection
                    local_ip=$(ss -tnp | grep "$openssl_pid" | grep 'ESTAB' | awk '{print $4}' | head -n1 | cut -d: -f1)
                    if [[ -z "$local_ip" ]]; then echo "Error: Could not determine local IP for live session."; continue; fi

                    local cmd_b64; cmd_b64=$(echo -n "$cmd_to_req" | base64 -w0)
                    echo "REQ_LIVE:$cmd_b64:$local_ip" >&3
                    echo "--> Requesting interactive session. Waiting..."
                    ;;
                "/help") show_help; ;;
                *) echo "Unknown command: ${cmd_parts[0]}. Type /help." ;;
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

    # This is the main server loop. It is now STABLE.
    # It correctly waits for a client, handles the session, and then waits for the next one.
    while true; do
        echo "Starting chattr2 server on port $PORT... (Ctrl+C to stop)"
        
        # Use a subshell to manage the openssl process and chat session for one client.
        # When the subshell exits (client disconnects), the loop continues for the next client.
        (
            # Start openssl s_server for a single client connection.
            # -n: do not fork for each connection (we handle looping)
            # -N: clean shutdown
            $SUDO_CMD openssl s_server -n -N -brief -accept "$PORT" -cert "$cert_file" -quiet < "$PIPE_IN" > "$PIPE_OUT" 2>/dev/null &
            local openssl_pid=$!
            
            echo "Waiting for a client to connect..."
            # Wait for the connection to be established
            until ss -tnp | grep -q "$openssl_pid.*ESTAB"; do
                # If openssl dies before connecting, exit the subshell
                if ! ps -p $openssl_pid > /dev/null; then exit; fi
                sleep 0.5
            done
            
            echo "Client connected. (Type /help for commands or 'exit' to quit)"
            start_chat "Client" "true" "$openssl_pid"
        )
        
        # The subshell for the previous client has exited.
        # cleanup function is handled by the trap.
        # A brief pause before listening for the next client.
        echo "Session ended. Server is ready for a new connection."
        sleep 1
        # Re-create the temp dir for the next session
        rm -rf "$TMP_DIR"
        TMP_DIR=$(mktemp -d "/tmp/chattr2.$$.XXXXXX")
        PIPE_IN="$TMP_DIR/in"
        PIPE_OUT="$TMP_DIR/out"
    done
}

function client_mode() {
    local server_ip=$1; local port_arg=$2
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then PORT=$port_arg; fi

    echo "Connecting to $server_ip:$PORT ..."
    openssl s_client -connect "$server_ip:$PORT" -quiet < "$PIPE_IN" > "$PIPE_OUT" 2>/dev/null &
    local openssl_pid=$!

    sleep 0.5
    if ! ps -p $openssl_pid > /dev/null; then
       echo "Connection failed. Is the server running at $server_ip:$PORT?" >&2; exit 1
    fi

    echo "Connected. (Type /help for commands or 'exit' to quit)"
    start_chat "Server" "false" "$openssl_pid"
}

# --- Main Execution Logic ---
case "$1" in
    server) server_mode "${@:2}"; ;;
    client) if [[ -z "$2" ]]; then echo "Error: Missing server IP." >&2; show_help; exit 1; fi; client_mode "${@:2}"; ;;
    --help|-h) show_help; ;;
    ""|*) if [[ -n "$1" ]]; then echo "Error: Invalid command '$1'." >&2; fi; show_help; exit 1 ;;
esac
