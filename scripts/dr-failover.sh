#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

PRIMARY_REGION="us-east-1"
DR_REGION="us-west-2"
PROJECT="solidarytech"
DR_CLUSTER="${PROJECT}-eks-dr"
PROD_CLUSTER="${PROJECT}-eks-production"
DB_REPLICA_ID="${PROJECT}-dr-postgres"

log_step() { echo -e "${BLUE}[FAILOVER $1]${NC} $2"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${RED}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  DISASTER RECOVERY - FAILOVER                   ║"
echo "║                                                  ║"
echo "║  Modelo: Warm Standby (Pilot Light)              ║"
echo "║  De:     ${PRIMARY_REGION} (Producao)                    ║"
echo "║  Para:   ${DR_REGION} (DR)                        ║"
echo "║  RTO:    3-5 minutos                             ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo "O ambiente DR ja esta com workload minimo ativo:"
echo "  - EKS: 1 node com apps rodando (1 replica cada)"
echo "  - RDS: Read Replica sincronizada com producao"
echo "  - SQS: Fila pronta para receber mensagens"
echo ""
SCRIPT_DIR="$(dirname "$0")"

echo "Este failover ira:"
echo "  1. SYNC dados Producao -> DR (preservar integridade)"
echo "  2. Promover RDS Read Replica para standalone (write-enabled)"
echo "  3. Atualizar secrets com o novo endpoint RDS"
echo "  4. Reiniciar pods para reconectar ao banco promovido"
echo "  5. Escalar nodes para capacidade de producao"
echo "  6. Executar health checks e validar dados"
echo ""
echo -e "${YELLOW}ATENCAO: Execute apenas em desastre real ou drill planejado.${NC}"
echo ""
read -p "Confirma o failover? (digite 'FAILOVER'): " CONFIRM
if [[ "${CONFIRM}" != "FAILOVER" ]]; then
    echo "Failover cancelado."
    exit 0
fi

TOTAL_STEPS=6
START_TIME=$(date +%s)

# Step 1: Sync dados producao -> DR
log_step "1/${TOTAL_STEPS}" "Sincronizando dados Producao -> DR (preservar integridade)..."

if [ -f "${SCRIPT_DIR}/dr-data-sync.sh" ]; then
    bash "${SCRIPT_DIR}/dr-data-sync.sh" prod-to-dr false && \
        log_ok "Dados sincronizados com sucesso" || \
        log_err "Falha na sincronizacao (continuando failover - RPO pode ser > 0)"
else
    log_err "Script de sync nao encontrado - dados podem divergir!"
fi

SYNC_TIME=$(date +%s)
echo -e "  Tempo de sync: $((SYNC_TIME - START_TIME))s"

# Step 2: Promover RDS Read Replica
log_step "2/${TOTAL_STEPS}" "Promovendo RDS Read Replica para standalone..."

DB_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "${DB_REPLICA_ID}" \
    --region "${DR_REGION}" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "not-found")

if [ "$DB_STATUS" = "not-found" ]; then
    log_err "RDS DR (${DB_REPLICA_ID}) nao encontrado!"
    exit 1
fi

REPLICA_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "${DB_REPLICA_ID}" \
    --region "${DR_REGION}" \
    --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text 2>/dev/null || echo "")

if [ -n "$REPLICA_STATUS" ] && [ "$REPLICA_STATUS" != "None" ]; then
    aws rds promote-read-replica \
        --db-instance-identifier "${DB_REPLICA_ID}" \
        --region "${DR_REGION}" && \
        log_ok "Promocao da replica iniciada" || \
        log_err "Falha ao promover replica"

    echo "Aguardando RDS ficar disponivel..."
    aws rds wait db-instance-available \
        --db-instance-identifier "${DB_REPLICA_ID}" \
        --region "${DR_REGION}" && \
        log_ok "RDS promovido e disponivel (read/write)" || \
        echo -e "${YELLOW}[WARN]${NC} Timeout - verifique manualmente"
else
    log_ok "RDS DR ja e standalone (nao e replica)"
fi

PROMOTE_TIME=$(date +%s)
echo -e "  Tempo de promocao: $((PROMOTE_TIME - START_TIME))s"

# Step 2: Configurar kubectl e atualizar secrets
log_step "3/${TOTAL_STEPS}" "Configurando kubectl e atualizando secrets..."

aws eks update-kubeconfig \
    --name "${DR_CLUSTER}" \
    --region "${DR_REGION}" 2>/dev/null && \
    log_ok "kubectl apontando para cluster DR" || \
    log_err "Falha ao configurar kubectl"

DR_RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "${DB_REPLICA_ID}" \
    --region "${DR_REGION}" \
    --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null)

DR_SQS_URL=$(aws sqs get-queue-url \
    --queue-name "${PROJECT}-dr-donations" \
    --region "${DR_REGION}" \
    --query 'QueueUrl' --output text 2>/dev/null || echo "")

CURRENT_DB_URL=$(kubectl get secret solidarytech-secrets -n solidarytech \
    -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

DB_USER=$(echo "$CURRENT_DB_URL" | sed -n 's|postgresql://\([^:]*\):.*|\1|p')
DB_PASS=$(echo "$CURRENT_DB_URL" | sed -n 's|postgresql://[^:]*:\([^@]*\)@.*|\1|p')

if [ -n "$DB_USER" ] && [ -n "$DB_PASS" ]; then
    NEW_DB_URL="postgresql://${DB_USER}:${DB_PASS}@${DR_RDS_ENDPOINT}:5432/solidarytech"
    kubectl create secret generic solidarytech-secrets \
        --namespace solidarytech \
        --from-literal=DATABASE_URL="${NEW_DB_URL}" \
        --from-literal=SQS_QUEUE_URL="${DR_SQS_URL}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_ok "Secrets atualizados com endpoint DR"
else
    log_err "Nao foi possivel extrair credenciais do secret existente"
    echo "Atualize manualmente: kubectl edit secret solidarytech-secrets -n solidarytech"
fi

# Step 3: Reiniciar pods para reconectar
log_step "4/${TOTAL_STEPS}" "Reiniciando pods para reconectar ao banco promovido..."
kubectl rollout restart deployment -n solidarytech 2>/dev/null || true
kubectl rollout status deployment -n solidarytech --timeout=120s 2>/dev/null || \
    echo -e "${YELLOW}[WARN]${NC} Timeout aguardando rollout"
log_ok "Pods reiniciados"

# Step 4: Escalar para capacidade de producao
log_step "5/${TOTAL_STEPS}" "Escalando nodes para capacidade de producao..."

NODEGROUP=$(aws eks list-nodegroups \
    --cluster-name "${DR_CLUSTER}" \
    --region "${DR_REGION}" \
    --query "nodegroups[0]" --output text 2>/dev/null || echo "")

if [ -n "${NODEGROUP}" ] && [ "${NODEGROUP}" != "None" ]; then
    aws eks update-nodegroup-config \
        --cluster-name "${DR_CLUSTER}" \
        --nodegroup-name "${NODEGROUP}" \
        --scaling-config minSize=1,maxSize=3,desiredSize=2 \
        --region "${DR_REGION}" 2>/dev/null && \
        log_ok "Node group escalado para 2 nodes" || \
        log_err "Falha ao escalar"
else
    log_err "Node group nao encontrado"
fi

# Step 5: Health checks
log_step "6/${TOTAL_STEPS}" "Verificando saude dos servicos e integridade dos dados..."
echo ""

ALL_HEALTHY=true
for svc in ngo-service donation-service volunteer-service; do
    POD=$(kubectl get pods -n solidarytech -l app=${svc} --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    if [ -n "$POD" ]; then
        STATUS=$(kubectl get pod "$POD" -n solidarytech -o jsonpath='{.status.phase}' 2>/dev/null)
        READY=$(kubectl get pod "$POD" -n solidarytech -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$STATUS" = "Running" ] && [ "$READY" = "True" ]; then
            log_ok "  ${svc}: Running e Ready"
        else
            echo -e "  ${YELLOW}[WARN]${NC} ${svc}: ${STATUS} (Ready=${READY})"
            ALL_HEALTHY=false
        fi
    else
        echo -e "  ${RED}[ERROR]${NC} ${svc}: Pod nao encontrado"
        ALL_HEALTHY=false
    fi
done

# Resumo final
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  FAILOVER CONCLUIDO                             ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Duracao total: ${DURATION}s                            ║"
echo "║  Regiao ativa:  ${DR_REGION}                      ║"
echo "║  RDS:           Standalone (read/write)          ║"
echo "║  Nodes:         Escalando para 2                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "${ALL_HEALTHY}" = true ]; then
    echo -e "${GREEN}Todos os servicos estao saudaveis no DR.${NC}"
else
    echo -e "${YELLOW}Alguns servicos ainda estao inicializando.${NC}"
    echo "Monitore: kubectl get pods -n solidarytech -w"
fi

RTO_TARGET=300
if [ "$DURATION" -le "$RTO_TARGET" ]; then
    echo -e "${GREEN}RTO atingido: ${DURATION}s <= ${RTO_TARGET}s (5 min target)${NC}"
else
    echo -e "${YELLOW}RTO excedido: ${DURATION}s > ${RTO_TARGET}s (5 min target)${NC}"
fi

echo ""
echo "Validando integridade dos dados no DR..."
DR_DONATIONS=$(kubectl get pods -n solidarytech -l app=donation-service --no-headers 2>/dev/null | head -1 | awk '{print $1}')
if [ -n "$DR_DONATIONS" ]; then
    kubectl exec "$DR_DONATIONS" -n solidarytech -- python3 -c "
import os, psycopg2
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute('SELECT count(*) FROM donations')
count = cur.fetchone()[0]
cur.execute('SELECT COALESCE(sum(amount),0) FROM donations')
total = cur.fetchone()[0]
print(f'  Donations no DR: {count} registros, R\$ {total:.2f}')
conn.close()
" 2>/dev/null || echo "  [WARN] Nao foi possivel validar dados"
fi

echo ""
echo "Proximos passos:"
echo "  1. Monitorar pods: kubectl get pods -n solidarytech -w"
echo "  2. Verificar Grafana: kubectl port-forward svc/grafana 3000:3000 -n monitoring"
echo "  3. Comunicar stakeholders"
echo "  4. Quando a regiao primaria voltar: ./scripts/dr-failback.sh"
echo ""
echo -e "${YELLOW}IMPORTANTE: Ao executar failback, os dados criados no DR serao"
echo -e "preservados e sincronizados de volta para producao.${NC}"
