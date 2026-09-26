#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT="solidarytech"
PRIMARY_REGION="us-east-1"
DR_REGION="us-west-2"
PROD_CLUSTER="${PROJECT}-eks-production"
DR_CLUSTER="${PROJECT}-eks-dr"
DB_INSTANCE_ID="${PROJECT}-postgres"
DB_REPLICA_ID="${PROJECT}-dr-postgres"

FAILURE_THRESHOLD=3
CHECK_INTERVAL=60
STATE_FILE="/tmp/dr-health-checker-state"

MODE="once"
DRY_RUN=false
AUTO_FAILOVER=false

usage() {
    echo "Uso: $0 [opcoes]"
    echo ""
    echo "Opcoes:"
    echo "  --once            Executa uma unica verificacao e sai (padrao)"
    echo "  --daemon          Executa continuamente a cada ${CHECK_INTERVAL}s"
    echo "  --dry-run         Simula as verificacoes sem executar failover"
    echo "  --auto-failover   Permite failover automatico ao atingir threshold"
    echo "  --interval N      Intervalo entre checks em segundos (padrao: ${CHECK_INTERVAL})"
    echo "  --threshold N     Falhas consecutivas para failover (padrao: ${FAILURE_THRESHOLD})"
    echo "  --help            Mostra esta mensagem"
    echo ""
    echo "Exemplos:"
    echo "  $0 --once                          # Check unico (para CronJob)"
    echo "  $0 --daemon --auto-failover        # Monitoramento continuo com failover"
    echo "  $0 --daemon --dry-run              # Teste sem failover real"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --once)      MODE="once"; shift ;;
        --daemon)    MODE="daemon"; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --auto-failover) AUTO_FAILOVER=true; shift ;;
        --interval)  CHECK_INTERVAL="$2"; shift 2 ;;
        --threshold) FAILURE_THRESHOLD="$2"; shift 2 ;;
        --help)      usage; exit 0 ;;
        *)           echo "Opcao desconhecida: $1"; usage; exit 1 ;;
    esac
done

log_ts() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log_ok()   { log_ts "${GREEN}[HEALTHY]${NC} $1"; }
log_warn() { log_ts "${YELLOW}[WARN]${NC} $1"; }
log_fail() { log_ts "${RED}[FALHA]${NC} $1"; }
log_info() { log_ts "${BLUE}[INFO]${NC} $1"; }

load_failure_count() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo 0
    fi
}

save_failure_count() {
    echo "$1" > "$STATE_FILE"
}

check_eks_cluster() {
    local status
    status=$(aws eks describe-cluster \
        --name "${PROD_CLUSTER}" \
        --region "${PRIMARY_REGION}" \
        --query 'cluster.status' \
        --output text 2>/dev/null) || status="UNREACHABLE"

    if [ "$status" = "ACTIVE" ]; then
        log_ok "EKS cluster ${PROD_CLUSTER}: ACTIVE"
        return 0
    else
        log_fail "EKS cluster ${PROD_CLUSTER}: ${status}"
        return 1
    fi
}

check_eks_nodes() {
    local current_ctx ready_nodes
    current_ctx=$(kubectl config current-context 2>/dev/null || echo "")

    aws eks update-kubeconfig \
        --name "${PROD_CLUSTER}" \
        --region "${PRIMARY_REGION}" \
        --alias prod-health-check 2>/dev/null || {
        log_fail "Nao foi possivel obter kubeconfig de producao"
        [ -n "$current_ctx" ] && kubectl config use-context "$current_ctx" 2>/dev/null
        return 1
    }

    ready_nodes=$(kubectl --context prod-health-check get nodes --no-headers 2>/dev/null \
        | grep -c " Ready" || echo 0)

    [ -n "$current_ctx" ] && kubectl config use-context "$current_ctx" 2>/dev/null

    if [ "$ready_nodes" -gt 0 ]; then
        log_ok "Nodes de producao prontos: ${ready_nodes}"
        return 0
    else
        log_fail "Nenhum node Ready em producao"
        return 1
    fi
}

check_rds_primary() {
    local status
    status=$(aws rds describe-db-instances \
        --db-instance-identifier "${DB_INSTANCE_ID}" \
        --region "${PRIMARY_REGION}" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null) || status="UNREACHABLE"

    if [ "$status" = "available" ]; then
        log_ok "RDS primario ${DB_INSTANCE_ID}: available"
        return 0
    else
        log_fail "RDS primario ${DB_INSTANCE_ID}: ${status}"
        return 1
    fi
}

check_production_health() {
    local checks_failed=0

    log_info "Verificando saude de producao (${PRIMARY_REGION})..."

    check_eks_cluster || ((checks_failed++))
    check_eks_nodes   || ((checks_failed++))
    check_rds_primary || ((checks_failed++))

    if [ "$checks_failed" -eq 0 ]; then
        return 0
    elif [ "$checks_failed" -lt 3 ]; then
        log_warn "Producao parcialmente degradada (${checks_failed}/3 checks falharam)"
        return 1
    else
        log_fail "Producao totalmente indisponivel (3/3 checks falharam)"
        return 1
    fi
}

execute_failover() {
    log_info "═══════════════════════════════════════════"
    log_info "  FAILOVER AUTOMATICO INICIADO"
    log_info "═══════════════════════════════════════════"

    local start_time
    start_time=$(date +%s)

    # Step 1: Promover RDS Read Replica
    log_info "[1/5] Promovendo RDS Read Replica..."
    if $DRY_RUN; then
        log_warn "[DRY-RUN] Simulando promocao de ${DB_REPLICA_ID}"
    else
        local replica_source
        replica_source=$(aws rds describe-db-instances \
            --db-instance-identifier "${DB_REPLICA_ID}" \
            --region "${DR_REGION}" \
            --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' \
            --output text 2>/dev/null || echo "")

        if [ -n "$replica_source" ] && [ "$replica_source" != "None" ]; then
            aws rds promote-read-replica \
                --db-instance-identifier "${DB_REPLICA_ID}" \
                --region "${DR_REGION}" 2>/dev/null && \
                log_ok "Promocao da replica iniciada" || \
                log_fail "Falha ao promover replica"

            log_info "Aguardando RDS ficar disponivel..."
            aws rds wait db-instance-available \
                --db-instance-identifier "${DB_REPLICA_ID}" \
                --region "${DR_REGION}" 2>/dev/null && \
                log_ok "RDS promovido e disponivel (read/write)" || \
                log_warn "Timeout aguardando RDS — verifique manualmente"
        else
            log_ok "RDS DR ja e standalone (nao e replica)"
        fi
    fi

    # Step 2: Configurar kubectl para DR
    log_info "[2/5] Apontando kubectl para cluster DR..."
    if $DRY_RUN; then
        log_warn "[DRY-RUN] Simulando update kubeconfig para ${DR_CLUSTER}"
    else
        aws eks update-kubeconfig \
            --name "${DR_CLUSTER}" \
            --region "${DR_REGION}" 2>/dev/null && \
            log_ok "kubectl apontando para cluster DR" || \
            log_fail "Falha ao configurar kubectl"
    fi

    # Step 3: Atualizar secrets com endpoint DR
    log_info "[3/5] Atualizando secrets com endpoint RDS DR..."
    if $DRY_RUN; then
        log_warn "[DRY-RUN] Simulando atualizacao de secrets"
    else
        local dr_endpoint db_user db_pass current_db_url
        dr_endpoint=$(aws rds describe-db-instances \
            --db-instance-identifier "${DB_REPLICA_ID}" \
            --region "${DR_REGION}" \
            --query 'DBInstances[0].Endpoint.Address' \
            --output text 2>/dev/null || echo "")

        current_db_url=$(kubectl get secret solidarytech-secrets \
            -n solidarytech \
            -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

        db_user=$(echo "$current_db_url" | sed -n 's|postgresql://\([^:]*\):.*|\1|p')
        db_pass=$(echo "$current_db_url" | sed -n 's|postgresql://[^:]*:\([^@]*\)@.*|\1|p')

        if [ -n "$db_user" ] && [ -n "$db_pass" ] && [ -n "$dr_endpoint" ]; then
            local dr_sqs_url new_db_url
            dr_sqs_url=$(aws sqs get-queue-url \
                --queue-name "${PROJECT}-dr-donations" \
                --region "${DR_REGION}" \
                --query 'QueueUrl' --output text 2>/dev/null || echo "")
            new_db_url="postgresql://${db_user}:${db_pass}@${dr_endpoint}:5432/solidarytech"

            kubectl create secret generic solidarytech-secrets \
                --namespace solidarytech \
                --from-literal=DATABASE_URL="${new_db_url}" \
                --from-literal=SQS_QUEUE_URL="${dr_sqs_url}" \
                --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null && \
                log_ok "Secrets atualizados com endpoint DR" || \
                log_fail "Falha ao atualizar secrets"
        else
            log_fail "Nao foi possivel extrair credenciais do secret existente"
        fi
    fi

    # Step 4: Reiniciar pods
    log_info "[4/5] Reiniciando pods para reconectar ao banco DR..."
    if $DRY_RUN; then
        log_warn "[DRY-RUN] Simulando rollout restart"
    else
        kubectl rollout restart deployment -n solidarytech 2>/dev/null || true
        kubectl rollout status deployment -n solidarytech --timeout=120s 2>/dev/null || \
            log_warn "Timeout aguardando rollout — verifique manualmente"
        log_ok "Pods reiniciados"
    fi

    # Step 5: Escalar nodes para capacidade de producao
    log_info "[5/5] Escalando nodes para capacidade de producao..."
    if $DRY_RUN; then
        log_warn "[DRY-RUN] Simulando scaling de nodes"
    else
        local nodegroup
        nodegroup=$(aws eks list-nodegroups \
            --cluster-name "${DR_CLUSTER}" \
            --region "${DR_REGION}" \
            --query "nodegroups[0]" --output text 2>/dev/null || echo "")

        if [ -n "${nodegroup}" ] && [ "${nodegroup}" != "None" ]; then
            aws eks update-nodegroup-config \
                --cluster-name "${DR_CLUSTER}" \
                --nodegroup-name "${nodegroup}" \
                --scaling-config minSize=1,maxSize=3,desiredSize=2 \
                --region "${DR_REGION}" 2>/dev/null && \
                log_ok "Node group escalado para 2 nodes" || \
                log_fail "Falha ao escalar nodes"
        else
            log_fail "Node group DR nao encontrado"
        fi
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    save_failure_count 0

    echo ""
    log_info "═══════════════════════════════════════════"
    if $DRY_RUN; then
        log_warn "  FAILOVER SIMULADO (DRY-RUN) em ${duration}s"
    else
        log_ok "  FAILOVER CONCLUIDO em ${duration}s"
    fi
    log_info "  Regiao ativa: ${DR_REGION}"
    if [ "$duration" -le 300 ]; then
        log_ok "  RTO atingido: ${duration}s <= 300s (5 min target)"
    else
        log_warn "  RTO excedido: ${duration}s > 300s (5 min target)"
    fi
    log_info "═══════════════════════════════════════════"
    echo ""
    log_info "Proximos passos:"
    log_info "  1. Monitorar: kubectl get pods -n solidarytech -w"
    log_info "  2. Grafana: kubectl port-forward svc/grafana 3000:3000 -n monitoring"
    log_info "  3. Comunicar stakeholders"
    log_info "  4. Failback: ./scripts/dr-failback.sh"
}

run_check() {
    local failure_count
    failure_count=$(load_failure_count)

    if check_production_health; then
        if [ "$failure_count" -gt 0 ]; then
            log_ok "Producao recuperada apos ${failure_count} falha(s) consecutiva(s)"
        fi
        save_failure_count 0
        return 0
    else
        failure_count=$((failure_count + 1))
        save_failure_count "$failure_count"

        log_warn "Falhas consecutivas: ${failure_count}/${FAILURE_THRESHOLD}"

        if [ "$failure_count" -ge "$FAILURE_THRESHOLD" ]; then
            log_fail "THRESHOLD ATINGIDO (${failure_count}/${FAILURE_THRESHOLD})"

            if $AUTO_FAILOVER; then
                execute_failover
                return 2
            else
                log_warn "Failover automatico DESATIVADO — use --auto-failover para ativar"
                log_warn "Ou execute manualmente: ./scripts/dr-failover.sh"
                return 1
            fi
        fi
        return 1
    fi
}

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  DR Health Checker - SolidaryTech               ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Modo:        ${MODE}                               ║"
echo "║  Dry-run:     ${DRY_RUN}                              ║"
echo "║  Auto-failover: ${AUTO_FAILOVER}                             ║"
echo "║  Threshold:   ${FAILURE_THRESHOLD} falhas consecutivas              ║"
echo "║  Intervalo:   ${CHECK_INTERVAL}s                                ║"
echo "║  Producao:    ${PRIMARY_REGION}                          ║"
echo "║  DR:          ${DR_REGION}                          ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

for cmd in aws kubectl; do
    if ! command -v $cmd &> /dev/null; then
        log_fail "$cmd nao encontrado. Instale antes de continuar."
        exit 1
    fi
done

if ! aws sts get-caller-identity &> /dev/null; then
    log_fail "Credenciais AWS nao configuradas."
    exit 1
fi

case "$MODE" in
    once)
        run_check
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_ok "Check concluido — producao saudavel"
        elif [ $exit_code -eq 2 ]; then
            log_info "Check concluido — failover executado"
        else
            log_warn "Check concluido — producao com problemas"
        fi
        exit $exit_code
        ;;
    daemon)
        log_info "Iniciando monitoramento continuo (Ctrl+C para parar)..."
        echo ""
        while true; do
            run_check
            result=$?
            if [ $result -eq 2 ]; then
                log_info "Failover executado — encerrando monitoramento"
                exit 0
            fi
            echo ""
            log_info "Proximo check em ${CHECK_INTERVAL}s..."
            sleep "$CHECK_INTERVAL"
        done
        ;;
esac
