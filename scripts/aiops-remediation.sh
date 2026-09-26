#!/bin/bash
set -uo pipefail

###############################################################################
# SolidaryTech - AIOps Proactive Remediation
#
# Detecta e corrige automaticamente problemas no ambiente.
# Roda como CronJob no cluster ou manualmente via CLI.
#
# Uso:
#   ./aiops-remediation.sh              # Executa todas as verificacoes
#   ./aiops-remediation.sh --dry-run    # Apenas detecta, nao corrige
#   ./aiops-remediation.sh --watch      # Loop continuo (intervalo 60s)
###############################################################################

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="solidarytech"
MONITORING_NS="monitoring"
ARGOCD_NS="argocd"
DRY_RUN=false
WATCH_MODE=false
FIXES=0
ISSUES=0
CHECKS=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --watch)   WATCH_MODE=true ;;
    esac
done

log()     { echo -e "${BLUE}[AIOPS $(date +'%H:%M:%S')]${NC} $1"; }
fixed()   { echo -e "${GREEN}[FIXED]${NC} $1"; FIXES=$((FIXES + 1)); }
issue()   { echo -e "${RED}[ISSUE]${NC} $1"; ISSUES=$((ISSUES + 1)); }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
skipped() { echo -e "${YELLOW}[DRY-RUN]${NC} $1"; }

apply() {
    if [ "$DRY_RUN" = true ]; then
        skipped "Acao: $1"
    else
        eval "$1"
    fi
}

###############################################################################
# 1. Pods em estado anormal
###############################################################################
check_unhealthy_pods() {
    log "Verificando pods em estado anormal..."
    CHECKS=$((CHECKS + 1))

    # CrashLoopBackOff — restart do deployment
    local crashloop_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers \
        --field-selector=status.phase!=Succeeded \
        -o custom-columns="NAME:.metadata.name,STATUS:.status.containerStatuses[0].state.waiting.reason" 2>/dev/null \
        | grep "CrashLoopBackOff" | awk '{print $1}')

    for pod in $crashloop_pods; do
        local deploy=$(echo "$pod" | sed 's/-[a-f0-9]*-[a-z0-9]*$//')
        issue "CrashLoopBackOff: $pod (deployment: $deploy)"
        apply "kubectl rollout restart deployment/$deploy -n $NAMESPACE 2>/dev/null"
        [ "$DRY_RUN" = false ] && fixed "Rollout restart: $deploy"
    done

    # ImagePullBackOff — nao tem correcao automatica, apenas alerta
    local imagepull_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers \
        -o custom-columns="NAME:.metadata.name,STATUS:.status.containerStatuses[0].state.waiting.reason" 2>/dev/null \
        | grep "ImagePullBackOff\|ErrImagePull" | awk '{print $1}')

    for pod in $imagepull_pods; do
        issue "ImagePullBackOff: $pod (verificar credenciais ECR ou tag da imagem)"
    done

    # Pending — verificar se e por limite de pods no node
    local pending_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers \
        --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l)

    if [ "$pending_pods" -gt 0 ]; then
        local total_pods=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
        local node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        local max_pods=$((node_count * 17))

        if [ "$total_pods" -ge "$max_pods" ]; then
            issue "$pending_pods pods Pending — limite de pods atingido ($total_pods/$max_pods)"
            check_pod_capacity
        else
            issue "$pending_pods pods Pending — verificar recursos (CPU/memoria)"
        fi
    fi

    [ -z "$crashloop_pods" ] && [ -z "$imagepull_pods" ] && [ "$pending_pods" -eq 0 ] && \
        ok "Todos os pods saudaveis"
}

###############################################################################
# 2. Capacidade de pods nos nodes
###############################################################################
check_pod_capacity() {
    log "Verificando capacidade de pods..."
    CHECKS=$((CHECKS + 1))

    local total_pods=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
    local node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local max_pods=$((node_count * 17))
    local threshold=$((max_pods * 85 / 100))

    if [ "$total_pods" -ge "$max_pods" ]; then
        issue "Capacidade de pods esgotada: $total_pods/$max_pods"

        # Reduzir CoreDNS para 1 replica
        local coredns_replicas=$(kubectl get deployment coredns -n kube-system \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        if [ "$coredns_replicas" -gt 1 ]; then
            apply "kubectl scale deployment coredns -n kube-system --replicas=1 2>/dev/null"
            [ "$DRY_RUN" = false ] && fixed "CoreDNS reduzido para 1 replica"
        fi

        # Verificar HPAs com excesso de replicas
        for hpa in $(kubectl get hpa -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            local current=$(kubectl get hpa "$hpa" -n "$NAMESPACE" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)
            local min=$(kubectl get hpa "$hpa" -n "$NAMESPACE" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
            if [ "$current" -gt "$min" ] && [ "$current" -gt 2 ]; then
                local target=$((current - 1))
                local deploy=$(kubectl get hpa "$hpa" -n "$NAMESPACE" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)
                issue "HPA $hpa com $current replicas — reduzindo para $target"
                apply "kubectl scale deployment/$deploy -n $NAMESPACE --replicas=$target 2>/dev/null"
                [ "$DRY_RUN" = false ] && fixed "Deployment $deploy reduzido para $target replicas"
            fi
        done
    elif [ "$total_pods" -ge "$threshold" ]; then
        issue "Pods acima de 85%: $total_pods/$max_pods — monitorar"
    else
        ok "Capacidade de pods: $total_pods/$max_pods"
    fi
}

###############################################################################
# 3. Monitoring stack
###############################################################################
check_monitoring() {
    log "Verificando stack de monitoramento..."
    CHECKS=$((CHECKS + 1))

    local all_ok=true
    for component in prometheus alertmanager grafana loki; do
        local ready=$(kubectl get deployment "$component" -n "$MONITORING_NS" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

        if [ "$ready" = "0" ] || [ -z "$ready" ]; then
            all_ok=false

            # Verificar se falta ConfigMap (problema recorrente do Grafana)
            if [ "$component" = "grafana" ]; then
                local events=$(kubectl get events -n "$MONITORING_NS" \
                    --field-selector involvedObject.name=$(kubectl get pod -n "$MONITORING_NS" -l app=grafana -o name 2>/dev/null | head -1 | sed 's|pod/||') \
                    --sort-by='.lastTimestamp' -o json 2>/dev/null \
                    | grep -c "configmap.*not found" 2>/dev/null || echo "0")

                if [ "$events" -gt 0 ]; then
                    issue "Grafana parado — ConfigMaps faltando"
                    local k8s_dir=$(find /home -name "grafana" -path "*/monitoring/*" -type d 2>/dev/null | head -1)
                    if [ -n "$k8s_dir" ] && [ -f "$k8s_dir/provisioning/datasources/datasources.yaml" ]; then
                        apply "kubectl create configmap grafana-datasources \
                            --from-file=datasources.yaml=$k8s_dir/provisioning/datasources/datasources.yaml \
                            -n $MONITORING_NS --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null"
                        apply "kubectl create configmap grafana-dashboard-provider \
                            --from-file=dashboards.yaml=$k8s_dir/provisioning/dashboards/dashboards.yaml \
                            -n $MONITORING_NS --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null"
                        apply "kubectl delete pod -n $MONITORING_NS -l app=grafana 2>/dev/null"
                        [ "$DRY_RUN" = false ] && fixed "Grafana ConfigMaps criados e pod reiniciado"
                    fi
                else
                    issue "$component nao esta pronto — tentando restart"
                    apply "kubectl rollout restart deployment/$component -n $MONITORING_NS 2>/dev/null"
                    [ "$DRY_RUN" = false ] && fixed "$component reiniciado"
                fi
            else
                issue "$component nao esta pronto — tentando restart"
                apply "kubectl rollout restart deployment/$component -n $MONITORING_NS 2>/dev/null"
                [ "$DRY_RUN" = false ] && fixed "$component reiniciado"
            fi
        fi
    done

    # DaemonSets (promtail, otel-collector)
    for ds in promtail otel-collector; do
        local desired=$(kubectl get daemonset "$ds" -n "$MONITORING_NS" \
            -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        local ready=$(kubectl get daemonset "$ds" -n "$MONITORING_NS" \
            -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        if [ "$ready" != "$desired" ] && [ "$desired" != "0" ]; then
            all_ok=false
            issue "$ds: $ready/$desired nodes prontos"
        fi
    done

    [ "$all_ok" = true ] && ok "Stack de monitoramento completa"
}

###############################################################################
# 4. ArgoCD
###############################################################################
check_argocd() {
    log "Verificando ArgoCD..."
    CHECKS=$((CHECKS + 1))

    local argocd_ready=$(kubectl get deployment argocd-server -n "$ARGOCD_NS" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    if [ "$argocd_ready" = "0" ] || [ -z "$argocd_ready" ]; then
        issue "ArgoCD Server nao esta pronto"
        apply "kubectl rollout restart deployment/argocd-server -n $ARGOCD_NS 2>/dev/null"
        [ "$DRY_RUN" = false ] && fixed "ArgoCD Server reiniciado"
    else
        ok "ArgoCD Server operacional"
    fi

    # Verificar apps com health Degraded
    local degraded=$(kubectl get applications.argoproj.io -n "$ARGOCD_NS" \
        -o jsonpath='{range .items[?(@.status.health.status=="Degraded")]}{.metadata.name}{" "}{end}' 2>/dev/null)

    for app in $degraded; do
        issue "ArgoCD app $app: Degraded"
    done
}

###############################################################################
# 5. Services e endpoints
###############################################################################
check_services() {
    log "Verificando services e endpoints..."
    CHECKS=$((CHECKS + 1))

    local all_ok=true
    for svc in ngo-service donation-service volunteer-service; do
        local endpoints=$(kubectl get endpoints "$svc" -n "$NAMESPACE" \
            -o jsonpath='{.subsets[0].addresses}' 2>/dev/null)

        if [ -z "$endpoints" ] || [ "$endpoints" = "null" ]; then
            all_ok=false
            issue "Service $svc sem endpoints ativos"
        fi
    done

    [ "$all_ok" = true ] && ok "Todos os services com endpoints ativos"
}

###############################################################################
# 6. Health check dos aplicativos
###############################################################################
check_app_health() {
    log "Verificando health dos aplicativos..."
    CHECKS=$((CHECKS + 1))

    local all_ok=true
    local svc_ports=("ngo-service:8080" "donation-service:8081" "volunteer-service:8082")

    for svc_port in "${svc_ports[@]}"; do
        local svc="${svc_port%%:*}"
        local port="${svc_port##*:}"

        local health=$(kubectl exec -n "$NAMESPACE" deployment/"$svc" -- \
            python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:$port/health').read().decode())" 2>/dev/null || echo "")

        if echo "$health" | grep -q "healthy"; then
            ok "$svc: healthy"
        else
            all_ok=false
            issue "$svc: health check falhou — tentando restart"
            apply "kubectl rollout restart deployment/$svc -n $NAMESPACE 2>/dev/null"
            [ "$DRY_RUN" = false ] && fixed "$svc reiniciado"
        fi
    done
}

###############################################################################
# 7. AWS resources
###############################################################################
check_aws_resources() {
    log "Verificando recursos AWS..."
    CHECKS=$((CHECKS + 1))

    # RDS
    local rds_status=$(aws rds describe-db-instances \
        --db-instance-identifier solidarytech-postgres \
        --region us-east-1 \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "not-found")

    if [ "$rds_status" = "available" ]; then
        ok "RDS: available"
    elif [ "$rds_status" = "stopped" ]; then
        issue "RDS parado — iniciando"
        apply "aws rds start-db-instance --db-instance-identifier solidarytech-postgres --region us-east-1 2>/dev/null"
        [ "$DRY_RUN" = false ] && fixed "RDS start solicitado"
    else
        issue "RDS em estado inesperado: $rds_status"
    fi

    # ElastiCache
    local redis_status=$(aws elasticache describe-cache-clusters \
        --cache-cluster-id solidarytech-redis \
        --region us-east-1 \
        --query 'CacheClusters[0].CacheClusterStatus' --output text 2>/dev/null || echo "not-found")

    if [ "$redis_status" = "available" ]; then
        ok "ElastiCache Redis: available"
    else
        issue "ElastiCache Redis: $redis_status"
    fi
}

###############################################################################
# 8. Namespaces travados (Terminating)
###############################################################################
check_stuck_namespaces() {
    log "Verificando namespaces travados..."
    CHECKS=$((CHECKS + 1))

    local stuck=$(kubectl get namespaces --no-headers 2>/dev/null | grep "Terminating" | awk '{print $1}')

    if [ -n "$stuck" ]; then
        for ns in $stuck; do
            issue "Namespace $ns travado em Terminating"
            # Remover finalizers para destravar
            apply "kubectl get namespace $ns -o json 2>/dev/null | \
                python3 -c \"import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))\" | \
                kubectl replace --raw /api/v1/namespaces/$ns/finalize -f - 2>/dev/null"
            [ "$DRY_RUN" = false ] && fixed "Namespace $ns destravado"
        done
    else
        ok "Nenhum namespace travado"
    fi
}

###############################################################################
# Execucao
###############################################################################
run_checks() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  SolidaryTech — AIOps Proactive Remediation     ║${NC}"
    if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}║  MODO: DRY-RUN (apenas detecta, nao corrige)    ║${NC}"
    fi
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    FIXES=0
    ISSUES=0
    CHECKS=0

    check_unhealthy_pods
    echo ""
    check_pod_capacity
    echo ""
    check_monitoring
    echo ""
    check_argocd
    echo ""
    check_services
    echo ""
    check_app_health
    echo ""
    check_aws_resources
    echo ""
    check_stuck_namespaces

    echo ""
    echo -e "${BLUE}━━━ Resumo AIOps ━━━${NC}"
    echo -e "  Verificacoes: ${CHECKS}"
    echo -e "  ${GREEN}Correcoes automaticas: ${FIXES}${NC}"
    echo -e "  ${RED}Problemas detectados:  ${ISSUES}${NC}"

    if [ "$ISSUES" -eq 0 ]; then
        echo -e "\n${GREEN}Ambiente 100% saudavel — nenhuma acao necessaria.${NC}"
    elif [ "$FIXES" -gt 0 ] && [ "$DRY_RUN" = false ]; then
        echo -e "\n${YELLOW}Correcoes aplicadas. Re-execute em 60s para validar.${NC}"
    elif [ "$DRY_RUN" = true ]; then
        echo -e "\n${YELLOW}Problemas detectados. Execute sem --dry-run para corrigir.${NC}"
    else
        echo -e "\n${RED}Problemas que requerem intervencao manual.${NC}"
    fi
    echo ""
}

if [ "$WATCH_MODE" = true ]; then
    echo "[AIOPS] Modo watch ativado — executando a cada 60s (Ctrl+C para parar)"
    while true; do
        run_checks
        echo -e "${BLUE}[AIOPS $(date +'%H:%M:%S')] Proxima verificacao em 60s...${NC}"
        sleep 60
    done
else
    run_checks
fi
