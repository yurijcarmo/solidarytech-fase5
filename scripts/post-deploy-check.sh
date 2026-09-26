#!/bin/bash
set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
FIXED=0
NAMESPACE_APP="solidarytech"
NAMESPACE_MON="monitoring"
MAX_WAIT=90
POLL_INTERVAL=10

log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
log_fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_fix()  { echo -e "  ${YELLOW}⟳${NC} $1 — corrigindo..."; FIXED=$((FIXED+1)); }
log_info() { echo -e "  ${CYAN}ℹ${NC} $1"; }

header() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

check_pod_health() {
    local app="$1"
    local namespace="$2"
    local label="${3:-app=${app}}"

    local pod_line
    pod_line=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | head -1)
    if [ -z "$pod_line" ]; then
        return 1
    fi

    local status ready restarts
    status=$(echo "$pod_line" | awk '{print $3}')
    ready=$(echo "$pod_line" | awk '{print $2}')
    restarts=$(echo "$pod_line" | awk '{print $4}')

    if [ "$status" = "Running" ] && [[ "$ready" == *"/"* ]] && \
       [ "$(echo "$ready" | cut -d/ -f1)" = "$(echo "$ready" | cut -d/ -f2)" ]; then
        if [ "$restarts" -gt 5 ]; then
            return 3
        fi
        return 0
    fi

    case "$status" in
        *CrashLoop*) return 4 ;;
        *ImagePull*|*ErrImagePull*) return 5 ;;
        Pending) return 6 ;;
        Running) return 2 ;;
        *Init*) return 7 ;;
        *) return 8 ;;
    esac
}

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  SolidaryTech — Post-Deploy Health Check         ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 1. Cluster ──────────────────────────────────────────
header "1. Cluster"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
if [ "$NODE_COUNT" -gt 0 ]; then
    log_ok "Nodes Ready: ${NODE_COUNT}"
else
    log_fail "Nenhum node Ready"
fi

TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
MAX_PODS=$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.pods}' 2>/dev/null | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}' 2>/dev/null || echo "999")
MAX_PODS=${MAX_PODS:-999}
if [ "$TOTAL_PODS" -lt "$MAX_PODS" ]; then
    log_ok "Pods: ${TOTAL_PODS}/${MAX_PODS} (OK)"
else
    log_fix "Pods no limite: ${TOTAL_PODS}/${MAX_PODS}"
    COREDNS_REPLICAS=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    if [ "$COREDNS_REPLICAS" -gt 1 ]; then
        kubectl scale deployment coredns -n kube-system --replicas=1 2>/dev/null || true
        log_info "CoreDNS reduzido para 1 replica"
    fi
fi

# ── 2. Namespaces ───────────────────────────────────────
header "2. Namespaces"

for ns in $NAMESPACE_APP $NAMESPACE_MON argocd kube-system; do
    if kubectl get namespace "$ns" &>/dev/null; then
        log_ok "Namespace: ${ns}"
    else
        log_fix "Namespace ${ns} nao existe"
        kubectl create namespace "$ns" 2>/dev/null || true
    fi
done

# ── 3. Monitoring Pods ──────────────────────────────────
header "3. Monitoring Stack"

EXPECTED_MON="alertmanager grafana loki otel-collector prometheus promtail selfhealing-handler"

for app in $EXPECTED_MON; do
    check_pod_health "$app" "$NAMESPACE_MON"
    rc=$?

    case $rc in
        0)
            POD_LINE=$(kubectl get pods -n "$NAMESPACE_MON" -l "app=${app}" --no-headers 2>/dev/null | head -1)
            READY=$(echo "$POD_LINE" | awk '{print $2}')
            log_ok "${app}: Running (${READY})"
            ;;
        1) log_fail "${app}: pod nao encontrado" ;;
        2) log_fail "${app}: Running mas nao Ready" ;;
        3)
            POD_NAME=$(kubectl get pods -n "$NAMESPACE_MON" -l "app=${app}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')
            RESTARTS=$(kubectl get pods -n "$NAMESPACE_MON" -l "app=${app}" --no-headers 2>/dev/null | head -1 | awk '{print $4}')
            log_fix "${app}: Running mas ${RESTARTS} restarts"
            kubectl delete pod "$POD_NAME" -n "$NAMESPACE_MON" 2>/dev/null || true
            log_info "Pod deletado para reinicio limpo"
            ;;
        4)
            POD_NAME=$(kubectl get pods -n "$NAMESPACE_MON" -l "app=${app}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')
            log_fix "${app}: CrashLoopBackOff"
            LAST_LOG=$(kubectl logs "$POD_NAME" -n "$NAMESPACE_MON" --tail=5 2>/dev/null | tail -1)
            log_info "Ultimo log: ${LAST_LOG}"
            kubectl delete pod "$POD_NAME" -n "$NAMESPACE_MON" 2>/dev/null || true
            log_info "Pod reiniciado"
            ;;
        5)
            log_fix "${app}: ImagePull error"
            IMAGE=$(kubectl get pods -n "$NAMESPACE_MON" -l "app=${app}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')
            IMAGE=$(kubectl get pod "$IMAGE" -n "$NAMESPACE_MON" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
            log_info "Imagem com problema: ${IMAGE}"
            ;;
        6) log_fix "${app}: Pending" ;;
        7)
            POD_NAME=$(kubectl get pods -n "$NAMESPACE_MON" -l "app=${app}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')
            log_fix "${app}: Init container"
            kubectl delete pod "$POD_NAME" -n "$NAMESPACE_MON" 2>/dev/null || true
            ;;
        *) log_fail "${app}: estado desconhecido" ;;
    esac
done

# Limpar ReplicaSets orfaos
ORPHAN_RS=$(kubectl get rs -n "$NAMESPACE_MON" --no-headers 2>/dev/null | awk '$2==0 && $3==0 && $4==0 {print $1}' | wc -l)
if [ "$ORPHAN_RS" -gt 0 ]; then
    kubectl get rs -n "$NAMESPACE_MON" --no-headers 2>/dev/null | awk '$2==0 && $3==0 && $4==0 {print $1}' | \
        xargs -r kubectl delete rs -n "$NAMESPACE_MON" 2>/dev/null || true
    log_info "Limpou ${ORPHAN_RS} ReplicaSet(s) orfao(s)"
fi

# ── 4. Application Services (com retry para pods inicializando) ────
header "4. Application Services"

EXPECTED_APP="ngo-service donation-service volunteer-service"
PENDING_APPS=""

for app in $EXPECTED_APP; do
    check_pod_health "$app" "$NAMESPACE_APP"
    rc=$?

    case $rc in
        0)
            POD_LINE=$(kubectl get pods -n "$NAMESPACE_APP" -l "app=${app}" --no-headers 2>/dev/null | head -1)
            READY=$(echo "$POD_LINE" | awk '{print $2}')
            log_ok "${app}: Running (${READY})"
            ;;
        1) log_fail "${app}: pod nao encontrado" ;;
        2) PENDING_APPS="${PENDING_APPS} ${app}" ;;
        4)
            log_fix "${app}: CrashLoopBackOff — rollout restart"
            kubectl rollout restart deployment/"${app}" -n "$NAMESPACE_APP" 2>/dev/null || true
            PENDING_APPS="${PENDING_APPS} ${app}"
            ;;
        6)
            log_fix "${app}: Pending"
            PENDING_APPS="${PENDING_APPS} ${app}"
            ;;
        *)
            STATUS=$(kubectl get pods -n "$NAMESPACE_APP" -l "app=${app}" --no-headers 2>/dev/null | head -1 | awk '{print $3}')
            log_fail "${app}: ${STATUS}"
            ;;
    esac
done

# Aguardar pods que estao inicializando
if [ -n "$PENDING_APPS" ]; then
    echo -e "\n  ${BLUE}Aguardando pods ficarem prontos (max ${MAX_WAIT}s)...${NC}"
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        sleep $POLL_INTERVAL
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        STILL_PENDING=""

        for app in $PENDING_APPS; do
            check_pod_health "$app" "$NAMESPACE_APP"
            rc=$?
            if [ $rc -eq 0 ]; then
                POD_LINE=$(kubectl get pods -n "$NAMESPACE_APP" -l "app=${app}" --no-headers 2>/dev/null | head -1)
                READY=$(echo "$POD_LINE" | awk '{print $2}')
                log_ok "${app}: Running (${READY}) [${ELAPSED}s]"
            else
                STILL_PENDING="${STILL_PENDING} ${app}"
            fi
        done

        PENDING_APPS="$STILL_PENDING"
        if [ -z "$PENDING_APPS" ]; then
            break
        fi
        echo -e "  ${CYAN}ℹ${NC} Aguardando:${PENDING_APPS} (${ELAPSED}s/${MAX_WAIT}s)"
    done

    for app in $PENDING_APPS; do
        STATUS=$(kubectl get pods -n "$NAMESPACE_APP" -l "app=${app}" --no-headers 2>/dev/null | head -1 | awk '{print $3}')
        READY=$(kubectl get pods -n "$NAMESPACE_APP" -l "app=${app}" --no-headers 2>/dev/null | head -1 | awk '{print $2}')
        log_fail "${app}: ${STATUS} (${READY}) apos ${MAX_WAIT}s"
    done
fi

# donation-worker
WORKER_LINE=$(kubectl get pods -n "$NAMESPACE_APP" -l "app=donation-service,component=worker" --no-headers 2>/dev/null | head -1)
if [ -n "$WORKER_LINE" ]; then
    W_STATUS=$(echo "$WORKER_LINE" | awk '{print $3}')
    W_READY=$(echo "$WORKER_LINE" | awk '{print $2}')
    if [ "$W_STATUS" = "Running" ]; then
        log_ok "donation-worker: ${W_STATUS} (${W_READY})"
    else
        log_fix "donation-worker: ${W_STATUS}"
        kubectl rollout restart deployment/donation-worker -n "$NAMESPACE_APP" 2>/dev/null || true
    fi
else
    log_info "donation-worker: nao encontrado (normal se SQS nao configurado)"
fi

# ── 5. HPA ──────────────────────────────────────────────
header "5. Auto-Scaling (HPA)"

HPA_COUNT=$(kubectl get hpa -n "$NAMESPACE_APP" --no-headers 2>/dev/null | wc -l)
if [ "$HPA_COUNT" -gt 0 ]; then
    while IFS= read -r line; do
        HPA_NAME=$(echo "$line" | awk '{print $1}')
        HPA_TARGETS=$(echo "$line" | awk '{print $3}')
        HPA_REPLICAS=$(echo "$line" | awk '{print $6}')
        if [[ "$HPA_TARGETS" == *"<unknown>"* ]]; then
            log_warn "${HPA_NAME}: metricas indisponiveis (metrics-server pode estar inicializando)"
        else
            log_ok "${HPA_NAME}: ${HPA_TARGETS} replicas=${HPA_REPLICAS}"
        fi
    done < <(kubectl get hpa -n "$NAMESPACE_APP" --no-headers 2>/dev/null)
else
    log_info "Nenhum HPA configurado"
fi

# ── 6. ArgoCD ───────────────────────────────────────────
header "6. ArgoCD"

ARGOCD_POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server --no-headers 2>/dev/null | head -1)
if [ -n "$ARGOCD_POD" ]; then
    A_STATUS=$(echo "$ARGOCD_POD" | awk '{print $3}')
    if [ "$A_STATUS" = "Running" ]; then
        log_ok "ArgoCD Server: Running"
    else
        log_fail "ArgoCD Server: ${A_STATUS}"
    fi
else
    log_fail "ArgoCD Server: nao encontrado"
fi

# ── 7. Connectivity ────────────────────────────────────
header "7. Conectividade Interna"

for svc in prometheus:9090 grafana:3000 loki:3100 alertmanager:9093; do
    SVC_NAME=$(echo "$svc" | cut -d: -f1)
    SVC_PORT=$(echo "$svc" | cut -d: -f2)
    SVC_IP=$(kubectl get svc "$SVC_NAME" -n "$NAMESPACE_MON" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [ -n "$SVC_IP" ] && [ "$SVC_IP" != "None" ]; then
        log_ok "${SVC_NAME}: ClusterIP ${SVC_IP}:${SVC_PORT}"
    else
        log_fail "${SVC_NAME}: servico nao encontrado"
    fi
done

# ── Resumo ──────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━ Resumo ━━━${NC}"
echo ""
echo -e "  ${GREEN}✓ Passou:${NC}   ${PASS}"
echo -e "  ${RED}✗ Falhou:${NC}   ${FAIL}"
echo -e "  ${YELLOW}⟳ Corrigido:${NC} ${FIXED}"
echo ""

if [ "$FAIL" -eq 0 ] && [ "$FIXED" -eq 0 ]; then
    echo -e "${GREEN}Ambiente 100% saudavel.${NC}"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "${YELLOW}Ambiente corrigido automaticamente. Execute novamente para validar.${NC}"
else
    echo -e "${RED}Ambiente com problemas. Verifique os itens acima.${NC}"
fi

echo ""
echo "Acessos:"
echo "  Grafana:       kubectl port-forward svc/grafana -n monitoring 3000:3000"
echo "  Prometheus:    kubectl port-forward svc/prometheus -n monitoring 9091:9090"
echo "  AlertManager:  kubectl port-forward svc/alertmanager -n monitoring 9093:9093"
echo "  ArgoCD:        kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""

exit "$FAIL"
