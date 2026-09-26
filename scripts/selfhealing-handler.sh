#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

###############################################################################
# SolidaryTech - Self-Healing Handler
#
# Triggered by AlertManager webhook. Receives alerts and executes automated
# remediation actions based on the alert type, then logs every action for
# the post-mortem audit trail.
#
# Usage:
#   Run as a lightweight webhook server inside the cluster:
#     PORT=9095 ./selfhealing-handler.sh serve
#
#   Or invoke a specific action directly (for testing):
#     ./selfhealing-handler.sh handle <alert_json_file>
###############################################################################

NAMESPACE="solidarytech"
LOG_FILE="/var/log/selfhealing/actions.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_action() {
    local action="$1"
    local target="$2"
    local reason="$3"
    local result="$4"
    local entry="{\"timestamp\":\"$TIMESTAMP\",\"action\":\"$action\",\"target\":\"$target\",\"reason\":\"$reason\",\"result\":\"$result\"}"
    echo "$entry" | tee -a "$LOG_FILE"
}

handle_crash_loop() {
    local pod_name="$1"
    local deployment
    deployment=$(echo "$pod_name" | sed 's/-[a-z0-9]*-[a-z0-9]*$//')

    echo "[SELFHEAL] CrashLoopBackOff detectado: $pod_name"
    echo "[SELFHEAL] Executando rollout restart no deployment: $deployment"

    if kubectl rollout restart deployment/"$deployment" -n "$NAMESPACE" 2>/dev/null; then
        log_action "rollout_restart" "$deployment" "PodCrashLooping: $pod_name" "success"
        echo "[SELFHEAL] Rollout restart concluido com sucesso"

        kubectl rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
            log_action "rollout_status_check" "$deployment" "Timeout aguardando rollout" "timeout"
    else
        log_action "rollout_restart" "$deployment" "PodCrashLooping: $pod_name" "failed"
        echo "[SELFHEAL] FALHA no rollout restart - escalonamento manual necessario"
    fi
}

handle_high_memory() {
    local pod_name="$1"
    local deployment
    deployment=$(echo "$pod_name" | sed 's/-[a-z0-9]*-[a-z0-9]*$//')

    echo "[SELFHEAL] Alto uso de memoria detectado: $pod_name"

    local current_replicas
    current_replicas=$(kubectl get deployment "$deployment" -n "$NAMESPACE" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)
    local new_replicas=$((current_replicas + 1))
    local max_replicas=6

    if [ "$new_replicas" -le "$max_replicas" ]; then
        echo "[SELFHEAL] Escalando $deployment de $current_replicas para $new_replicas replicas"
        kubectl scale deployment/"$deployment" -n "$NAMESPACE" --replicas="$new_replicas"
        log_action "scale_up" "$deployment" "HighMemoryUsage: $pod_name" "success: ${current_replicas}->${new_replicas}"
    else
        echo "[SELFHEAL] $deployment ja no maximo de replicas ($max_replicas)"
        log_action "scale_up" "$deployment" "HighMemoryUsage: $pod_name" "skipped: max_replicas_reached"
    fi
}

handle_queue_backlog() {
    local queue_depth="$1"

    echo "[SELFHEAL] Backlog na fila de doacoes: $queue_depth mensagens"

    local current_replicas
    current_replicas=$(kubectl get deployment donation-worker -n "$NAMESPACE" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)
    local new_replicas=$((current_replicas + 1))
    local max_replicas=4

    if [ "$new_replicas" -le "$max_replicas" ]; then
        echo "[SELFHEAL] Escalando donation-worker de $current_replicas para $new_replicas"
        kubectl scale deployment/donation-worker -n "$NAMESPACE" --replicas="$new_replicas"
        log_action "scale_worker" "donation-worker" "DonationQueueBacklog: ${queue_depth} msgs" "success: ${current_replicas}->${new_replicas}"
    else
        echo "[SELFHEAL] donation-worker ja no maximo ($max_replicas)"
        log_action "scale_worker" "donation-worker" "DonationQueueBacklog: ${queue_depth} msgs" "skipped: max_replicas_reached"
    fi
}

handle_high_cpu() {
    local pod_name="$1"
    local deployment
    deployment=$(echo "$pod_name" | sed 's/-[a-z0-9]*-[a-z0-9]*$//')

    echo "[SELFHEAL] Alto uso de CPU detectado: $pod_name"
    echo "[SELFHEAL] HPA deve ajustar automaticamente. Verificando status..."

    kubectl get hpa -n "$NAMESPACE" 2>/dev/null || true
    log_action "hpa_check" "$deployment" "HighCPUUsage: $pod_name" "delegated_to_hpa"
}

process_alert() {
    local alert_json="$1"

    local alert_name
    alert_name=$(echo "$alert_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('alerts',[{}])[0].get('labels',{}).get('alertname','unknown'))" 2>/dev/null || echo "unknown")
    local pod_name
    pod_name=$(echo "$alert_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('alerts',[{}])[0].get('labels',{}).get('pod','unknown'))" 2>/dev/null || echo "unknown")
    local status
    status=$(echo "$alert_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('alerts',[{}])[0].get('status','unknown'))" 2>/dev/null || echo "unknown")

    echo "[SELFHEAL] Alerta recebido: $alert_name | Pod: $pod_name | Status: $status"

    if [ "$status" = "resolved" ]; then
        log_action "alert_resolved" "$alert_name" "Pod: $pod_name" "info"
        return 0
    fi

    case "$alert_name" in
        PodCrashLooping)
            handle_crash_loop "$pod_name"
            ;;
        HighMemoryUsage)
            handle_high_memory "$pod_name"
            ;;
        HighCPUUsage)
            handle_high_cpu "$pod_name"
            ;;
        DonationQueueBacklog)
            handle_queue_backlog "100"
            ;;
        HighErrorRate|HighLatency)
            echo "[SELFHEAL] $alert_name detectado - iniciando RCA automatizado"
            "$(dirname "$0")/automated-rca.sh" "$pod_name" &
            log_action "trigger_rca" "$pod_name" "$alert_name" "rca_started"
            ;;
        *)
            echo "[SELFHEAL] Alerta nao mapeado para remediacao automatica: $alert_name"
            log_action "unknown_alert" "$alert_name" "Pod: $pod_name" "no_action"
            ;;
    esac
}

serve() {
    local port="${PORT:-9095}"
    echo "[SELFHEAL] Servidor webhook iniciado na porta $port"
    echo "[SELFHEAL] Aguardando alertas do AlertManager..."

    while true; do
        {
            read -r request_line
            content_length=0
            while read -r header; do
                header=$(echo "$header" | tr -d '\r')
                [ -z "$header" ] && break
                if echo "$header" | grep -qi "content-length"; then
                    content_length=$(echo "$header" | grep -oi '[0-9]*')
                fi
            done

            body=""
            if [ "$content_length" -gt 0 ] 2>/dev/null; then
                body=$(dd bs=1 count="$content_length" 2>/dev/null)
            fi

            if [ -n "$body" ]; then
                echo "$body" | process_alert /dev/stdin &
            fi

            echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        } | nc -l -p "$port" -q 1 2>/dev/null || sleep 1
    done
}

case "${1:-serve}" in
    serve)
        serve
        ;;
    handle)
        process_alert "$(cat "${2:-/dev/stdin}")"
        ;;
    *)
        echo "Usage: $0 {serve|handle <alert_json>}"
        exit 1
        ;;
esac
