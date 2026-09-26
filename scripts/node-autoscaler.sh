#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER_NAME="solidarytech-eks-production"
NODEGROUP="solidarytech-node-group"
REGION="${AWS_REGION:-us-east-1}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
MIN_NODES=1
MAX_NODES=3
SCALE_DOWN_DELAY=120

log() { echo -e "[$(date +'%H:%M:%S')] ${BLUE}[AUTOSCALER]${NC} $1"; }
log_ok() { echo -e "[$(date +'%H:%M:%S')] ${GREEN}[SCALE]${NC} $1"; }
log_warn() { echo -e "[$(date +'%H:%M:%S')] ${YELLOW}[WARN]${NC} $1"; }

last_scale_up=0

get_current_desired() {
    aws eks describe-nodegroup \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODEGROUP" \
        --region "$REGION" \
        --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null || echo "1"
}

get_pending_pods() {
    kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l
}

get_ready_nodes() {
    kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0"
}

get_pod_capacity_pct() {
    local total_allocatable=0
    local total_running=0
    for node in $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
        local alloc=$(kubectl get node "$node" -o jsonpath='{.status.allocatable.pods}' 2>/dev/null || echo "0")
        local running=$(kubectl get pods --all-namespaces --field-selector=spec.nodeName="$node" --no-headers 2>/dev/null | wc -l)
        total_allocatable=$((total_allocatable + alloc))
        total_running=$((total_running + running))
    done
    if [ "$total_allocatable" -eq 0 ]; then
        echo "100"
    else
        echo $((total_running * 100 / total_allocatable))
    fi
}

scale_nodegroup() {
    local new_desired=$1
    local current=$(get_current_desired)
    if [ "$new_desired" -eq "$current" ]; then
        return
    fi
    aws eks update-nodegroup-config \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODEGROUP" \
        --scaling-config "minSize=${MIN_NODES},maxSize=${MAX_NODES},desiredSize=${new_desired}" \
        --region "$REGION" > /dev/null 2>&1
    log_ok "Nodegroup escalado: ${current} -> ${new_desired} nodes"

    if [ "$new_desired" -gt "$current" ]; then
        log "Aguardando novo node ficar Ready..."
        for i in $(seq 1 24); do
            local ready=$(get_ready_nodes)
            if [ "$ready" -ge "$new_desired" ]; then
                log_ok "${ready} nodes Ready"
                for iid in $(aws ec2 describe-instances \
                    --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
                    --query 'Reservations[].Instances[].InstanceId' --output text --region "${REGION}" 2>/dev/null); do
                    aws ec2 modify-instance-metadata-options \
                        --instance-id "$iid" \
                        --http-put-response-hop-limit 2 \
                        --region "${REGION}" > /dev/null 2>&1 || true
                done
                log_ok "IMDS hop limit corrigido nos nodes"
                break
            fi
            sleep 10
        done
    fi
}

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  SolidaryTech — Node Autoscaler (Academy)        ║"
echo "║  Simula Cluster Autoscaler via EKS API           ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Cluster:   ${CLUSTER_NAME}             ║"
echo "║  Min/Max:   ${MIN_NODES}/${MAX_NODES} nodes                          ║"
echo "║  Intervalo: ${CHECK_INTERVAL}s                                ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

log "Monitorando pods Pending e capacidade de pods..."

while true; do
    PENDING=$(get_pending_pods)
    CURRENT_DESIRED=$(get_current_desired)
    READY_NODES=$(get_ready_nodes)
    POD_PCT=$(get_pod_capacity_pct)
    NOW=$(date +%s)

    log "Nodes: ${READY_NODES}/${CURRENT_DESIRED} | Pods Pending: ${PENDING} | Capacidade: ${POD_PCT}%"

    # SCALE UP: pods pending ou capacidade > 85%
    if [ "$PENDING" -gt 0 ] || [ "$POD_PCT" -ge 85 ]; then
        if [ "$CURRENT_DESIRED" -lt "$MAX_NODES" ]; then
            NEW_DESIRED=$((CURRENT_DESIRED + 1))
            log_ok "SCALE UP: ${PENDING} pods Pending, capacidade ${POD_PCT}% -> adicionando node"
            scale_nodegroup "$NEW_DESIRED"
            last_scale_up=$NOW
        else
            log_warn "SCALE UP necessario mas ja no maximo (${MAX_NODES} nodes)"
        fi
    fi

    # SCALE DOWN: sem pods pending, capacidade < 40%, e nao escalou recentemente
    if [ "$PENDING" -eq 0 ] && [ "$POD_PCT" -lt 40 ] && [ "$CURRENT_DESIRED" -gt "$MIN_NODES" ]; then
        ELAPSED=$((NOW - last_scale_up))
        if [ "$ELAPSED" -gt "$SCALE_DOWN_DELAY" ]; then
            NEW_DESIRED=$((CURRENT_DESIRED - 1))
            log_ok "SCALE DOWN: capacidade ${POD_PCT}%, sem pods Pending -> removendo node"
            scale_nodegroup "$NEW_DESIRED"
        else
            REMAINING=$((SCALE_DOWN_DELAY - ELAPSED))
            log "Scale down em ${REMAINING}s (cooldown)"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
