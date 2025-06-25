#!/bin/bash

# === Basic Configuration ===
BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"

# === Terminal Colors ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# === Check Docker ===
function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker not found. Installing Docker...${RESET}"
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update
        apt install -y docker-ce
        systemctl enable docker
        systemctl start docker
    fi
}

# === Check Cron ===
function check_cron() {
    if ! command -v cron >/dev/null 2>&1; then
        echo -e "${YELLOW}Cron not found. Installing cron...${RESET}"
        apt update
        apt install -y cron
        systemctl enable cron
        systemctl start cron
    fi
}

# === Build Docker Image ===
function build_image() {
    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id

RUN apt-get update && apt-get install -y \\
    curl \\
    screen \\
    bash \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh \\
    && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e
PROVER_ID_FILE="/root/.nexus/node-id"
if [ -z "\$NODE_ID" ]; then
    echo "NODE_ID is not set"
    exit 1
fi
echo "\$NODE_ID" > "\$PROVER_ID_FILE"
screen -S nexus -X quit >/dev/null 2>&1 || true
screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"
sleep 3
if screen -list | grep -q "nexus"; then
    echo "Node is running in the background"
else
    echo "Failed to start node"
    cat /root/nexus.log
    exit 1
fi
tail -f /root/nexus.log
EOF

    docker build -t "$IMAGE_NAME" .
    cd -
    rm -rf "$WORKDIR"
}

# === Run Docker Container ===
function run_container() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"

    docker rm -f "$container_name" 2>/dev/null || true
    mkdir -p "$LOG_DIR"
    touch "$log_file"
    chmod 644 "$log_file"

    docker run -d --name "$container_name" -v "$log_file":/root/nexus.log -e NODE_ID="$node_id" "$IMAGE_NAME"

    check_cron
    echo "0 0 * * * rm -f $log_file" > "/etc/cron.d/nexus-log-cleanup-${node_id}"
}

# === Uninstall Node ===
function uninstall_node() {
    local node_id=$1
    local cname="${BASE_CONTAINER_NAME}-${node_id}"
    docker rm -f "$cname" 2>/dev/null || true
    rm -f "${LOG_DIR}/nexus-${node_id}.log" "/etc/cron.d/nexus-log-cleanup-${node_id}"
    echo -e "${YELLOW}Node $node_id has been removed.${RESET}"
}

# === Get All Nodes ===
function get_all_nodes() {
    docker ps -a --format "{{.Names}}" | grep "^${BASE_CONTAINER_NAME}-" | sed "s/${BASE_CONTAINER_NAME}-//"
}


# === View Node Logs ===
function view_logs() {
    local nodes=($(get_all_nodes))
    if [ ${#nodes[@]} -eq 0 ]; then
        echo "No nodes found."
        read -p "Press enter to continue..."
        return
    fi
    echo "Select a node to view logs:"
    for i in "${!nodes[@]}"; do
        echo "$((i+1)). ${nodes[$i]}"
    done
    read -rp "Number: " choice
    if [[ "$choice" =~ ^[0-9]+$ && choice -ge 1 && choice -le ${#nodes[@]} ]]; then
        local selected=${nodes[$((choice-1))]}
        echo -e "${YELLOW}Showing logs for node: $selected${RESET}"
        docker logs -f "${BASE_CONTAINER_NAME}-${selected}"
    else
        echo "Invalid choice. Skipped."
    fi
    read -p "Press enter to continue..."
}

# === Uninstall Multiple Nodes ===
function batch_uninstall_nodes() {
    local nodes=($(get_all_nodes))
    echo "Enter the numbers of the nodes to uninstall (space-separated):"
    for i in "${!nodes[@]}"; do
        echo "$((i+1)). ${nodes[$i]}"
    done
    read -rp "Numbers: " input
    for i in $input; do
        [[ "$i" =~ ^[0-9]+$ && i -ge 1 && i -le ${#nodes[@]} ]] \
            && uninstall_node "${nodes[$((i-1))]}" \
            || echo "Skipped: $i"
    done
    read -p "Press enter to continue..."
}

# === MAIN MENU ===
while true; do
    show_header
    echo -e "${GREEN} 1.${RESET} ➤ Install & Run Node"
    echo -e "${GREEN} 2.${RESET} ❌ Remove Specific Node"
    echo -e "${GREEN} 3.${RESET} 🧾 View Node Logs"
    echo -e "${GREEN} 4.${RESET} 🚪 Exit"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    read -rp "Select an option (1-6): " choice
    case $choice in
        1)
            check_docker
            read -rp "Enter NODE_ID: " NODE_ID
            [ -z "$NODE_ID" ] && echo "NODE_ID cannot be empty." && read -p "Press enter to continue..." && continue
            build_image
            run_container "$NODE_ID"
            read -p "Press enter to continue..."
            ;;
        2) batch_uninstall_nodes ;;
        3) view_logs ;;
        4) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option."; read -p "Press enter to continue..." ;;
    esac
done

