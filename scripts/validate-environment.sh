#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }
header() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

PROJECT="solidarytech"
NAMESPACE="solidarytech"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  SolidaryTech - Validacao do Ambiente            ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================
header "1. CREDENCIAIS AWS"
# ============================================================

if aws sts get-caller-identity &>/dev/null; then
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    pass "AWS CLI autenticado - Account: ${ACCOUNT}"
else
    fail "AWS CLI nao autenticado"
    echo "  Execute: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=..."
    exit 1
fi

# ============================================================
header "2. INFRAESTRUTURA AWS (Terraform)"
# ============================================================

# VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=SolidaryTech" --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "None")
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
    pass "VPC encontrada: ${VPC_ID}"
else
    fail "VPC nao encontrada"
fi

# Subnets
SUBNET_COUNT=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query 'length(Subnets)' --output text --region "$REGION" 2>/dev/null || echo "0")
if [ "$SUBNET_COUNT" -ge 4 ]; then
    pass "Subnets: ${SUBNET_COUNT} (2 publicas + 2 privadas)"
else
    fail "Subnets: apenas ${SUBNET_COUNT} encontradas (esperado: 4)"
fi

# NAT Gateway
NAT_COUNT=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=available" "Name=tag:Project,Values=SolidaryTech" --query 'length(NatGateways)' --output text --region "$REGION" 2>/dev/null || echo "0")
if [ "$NAT_COUNT" -ge 1 ]; then
    pass "NAT Gateway ativo"
else
    warn "NAT Gateway nao encontrado ou nao ativo"
fi

# EKS
EKS_STATUS=$(aws eks describe-cluster --name "${PROJECT}-eks-production" --query 'cluster.status' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
if [ "$EKS_STATUS" = "ACTIVE" ]; then
    pass "EKS Cluster: ACTIVE"
    EKS_VERSION=$(aws eks describe-cluster --name "${PROJECT}-eks-production" --query 'cluster.version' --output text --region "$REGION")
    pass "EKS Versao: ${EKS_VERSION}"
else
    fail "EKS Cluster status: ${EKS_STATUS}"
fi

# RDS
RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier "${PROJECT}-postgres" --query 'DBInstances[0].DBInstanceStatus' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
if [ "$RDS_STATUS" = "available" ]; then
    RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "${PROJECT}-postgres" --query 'DBInstances[0].Endpoint.Address' --output text --region "$REGION")
    pass "RDS PostgreSQL: available (${RDS_ENDPOINT})"
    RDS_PUBLIC=$(aws rds describe-db-instances --db-instance-identifier "${PROJECT}-postgres" --query 'DBInstances[0].PubliclyAccessible' --output text --region "$REGION")
    if [ "$RDS_PUBLIC" = "False" ]; then
        pass "RDS acesso publico: desabilitado (seguro)"
    else
        fail "RDS acesso publico: HABILITADO (inseguro!)"
    fi
else
    fail "RDS status: ${RDS_STATUS}"
fi

# SQS
SQS_URL=$(aws sqs get-queue-url --queue-name "${PROJECT}-donations" --region "$REGION" --query 'QueueUrl' --output text 2>/dev/null || echo "NOT_FOUND")
if [ "$SQS_URL" != "NOT_FOUND" ]; then
    pass "SQS Queue: ${PROJECT}-donations"
    DLQ_URL=$(aws sqs get-queue-url --queue-name "${PROJECT}-donations-dlq" --region "$REGION" --query 'QueueUrl' --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$DLQ_URL" != "NOT_FOUND" ]; then
        pass "SQS DLQ: ${PROJECT}-donations-dlq"
    else
        warn "SQS DLQ nao encontrada"
    fi
else
    fail "SQS Queue nao encontrada"
fi

# DynamoDB
DYNAMO_STATUS=$(aws dynamodb describe-table --table-name "${PROJECT}-transactions" --query 'Table.TableStatus' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
if [ "$DYNAMO_STATUS" = "ACTIVE" ]; then
    pass "DynamoDB: ${PROJECT}-transactions (ACTIVE)"
else
    fail "DynamoDB status: ${DYNAMO_STATUS}"
fi

# ElastiCache
REDIS_STATUS=$(aws elasticache describe-cache-clusters --cache-cluster-id "${PROJECT}-redis" --query 'CacheClusters[0].CacheClusterStatus' --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
if [ "$REDIS_STATUS" = "available" ]; then
    pass "ElastiCache Redis: available"
else
    fail "ElastiCache Redis status: ${REDIS_STATUS}"
fi

# ECR
for SVC in ngo-service donation-service volunteer-service; do
    ECR_EXISTS=$(aws ecr describe-repositories --repository-names "${PROJECT}/${SVC}" --region "$REGION" --query 'repositories[0].repositoryName' --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$ECR_EXISTS" != "NOT_FOUND" ]; then
        pass "ECR: ${PROJECT}/${SVC}"
    else
        fail "ECR: ${PROJECT}/${SVC} nao encontrado"
    fi
done

# S3
S3_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name,'${PROJECT}-backups')].Name | [0]" --output text 2>/dev/null || echo "None")
if [ "$S3_BUCKET" != "None" ] && [ -n "$S3_BUCKET" ]; then
    pass "S3 Backup Bucket: ${S3_BUCKET}"
else
    warn "S3 Backup Bucket nao encontrado"
fi

# ============================================================
header "3. KUBERNETES - CLUSTER"
# ============================================================

if kubectl cluster-info &>/dev/null; then
    pass "kubectl conectado ao cluster"
else
    fail "kubectl nao conectado - execute: aws eks update-kubeconfig --name ${PROJECT}-eks-production --region ${REGION}"
    echo ""
    echo "Resultado parcial: ${PASS} pass, ${FAIL} fail, ${WARN} warn"
    exit 1
fi

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
if [ "$NODE_COUNT" -ge 1 ]; then
    pass "Nodes prontos: ${NODE_COUNT}"
    kubectl get nodes -o wide 2>/dev/null | head -5
else
    fail "Nenhum node Ready"
fi

# ============================================================
header "4. KUBERNETES - NAMESPACES"
# ============================================================

for NS in solidarytech monitoring argocd; do
    if kubectl get namespace "$NS" &>/dev/null; then
        pass "Namespace: ${NS}"
    else
        warn "Namespace nao encontrado: ${NS}"
    fi
done

# ============================================================
header "5. MICROSERVICOS"
# ============================================================

echo ""
echo "  Pods no namespace ${NAMESPACE}:"
kubectl get pods -n "$NAMESPACE" 2>/dev/null || warn "Nenhum pod encontrado"
echo ""

for SVC in ngo-service donation-service volunteer-service; do
    POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -l "app=${SVC}" --no-headers 2>/dev/null | head -1 | awk '{print $3}')
    if [ "$POD_STATUS" = "Running" ]; then
        pass "${SVC}: Running"
    elif [ -n "$POD_STATUS" ]; then
        fail "${SVC}: ${POD_STATUS}"
        echo "    Logs: kubectl logs -n ${NAMESPACE} -l app=${SVC} --tail=20"
    else
        fail "${SVC}: pod nao encontrado"
    fi
done

# Donation Worker
WORKER_STATUS=$(kubectl get pods -n "$NAMESPACE" -l "app=donation-worker" --no-headers 2>/dev/null | head -1 | awk '{print $3}')
if [ -n "$WORKER_STATUS" ]; then
    if [ "$WORKER_STATUS" = "Running" ]; then
        pass "donation-worker: Running"
    else
        fail "donation-worker: ${WORKER_STATUS}"
    fi
else
    warn "donation-worker: pod nao encontrado"
fi

# ============================================================
header "6. SERVICES & ENDPOINTS"
# ============================================================

echo ""
echo "  Services no namespace ${NAMESPACE}:"
kubectl get svc -n "$NAMESPACE" 2>/dev/null || warn "Nenhum service encontrado"
echo ""

for SVC in ngo-service donation-service volunteer-service; do
    SVC_IP=$(kubectl get svc "$SVC" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [ -n "$SVC_IP" ]; then
        SVC_PORT=$(kubectl get svc "$SVC" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
        pass "${SVC}: ${SVC_IP}:${SVC_PORT}"
    else
        fail "${SVC}: Service nao encontrado"
    fi
done

# ============================================================
header "7. HEALTH CHECKS (via port-forward)"
# ============================================================

echo ""
echo -e "  ${YELLOW}Testando saude dos servicos via port-forward...${NC}"
echo ""

test_health() {
    local svc=$1
    local port=$2
    local health_path=$3

    kubectl port-forward "svc/${svc}" "${port}:${port}" -n "$NAMESPACE" &>/dev/null &
    local PF_PID=$!
    sleep 3

    local HTTP_CODE
    HTTP_CODE=$(curl -sL -o /dev/null -w "%{http_code}" "http://localhost:${port}${health_path}" 2>/dev/null || echo "000")

    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true

    if [ "$HTTP_CODE" = "200" ]; then
        pass "${svc} ${health_path}: HTTP ${HTTP_CODE}"
    else
        fail "${svc} ${health_path}: HTTP ${HTTP_CODE}"
    fi
}

test_health "ngo-service" 8080 "/health"
test_health "donation-service" 8081 "/health"
test_health "volunteer-service" 8082 "/health"

# ============================================================
header "8. PROMETHEUS METRICS"
# ============================================================

for SVC in ngo-service donation-service volunteer-service; do
    case $SVC in
        ngo-service) PORT=8080 ;;
        donation-service) PORT=8081 ;;
        volunteer-service) PORT=8082 ;;
    esac

    kubectl port-forward "svc/${SVC}" "${PORT}:${PORT}" -n "$NAMESPACE" &>/dev/null &
    PF_PID=$!
    sleep 3

    METRICS=$(curl -s "http://localhost:${PORT}/metrics" 2>/dev/null | head -5)
    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true

    if [ -n "$METRICS" ]; then
        pass "${SVC}: /metrics expondo metricas Prometheus"
    else
        fail "${SVC}: /metrics nao respondeu"
    fi
done

# ============================================================
header "9. OBSERVABILIDADE (Monitoring Stack)"
# ============================================================

echo ""
echo "  Pods no namespace monitoring:"
kubectl get pods -n monitoring 2>/dev/null || warn "Namespace monitoring nao encontrado"
echo ""

for COMPONENT in prometheus grafana alertmanager otel-collector loki; do
    POD_COUNT=$(kubectl get pods -n monitoring -l "app=${COMPONENT}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$POD_COUNT" -ge 1 ]; then
        pass "${COMPONENT}: ${POD_COUNT} pod(s) Running"
    else
        POD_COUNT2=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -i "${COMPONENT}" | grep -c "Running" || echo "0")
        if [ "$POD_COUNT2" -ge 1 ]; then
            pass "${COMPONENT}: ${POD_COUNT2} pod(s) Running"
        else
            warn "${COMPONENT}: nenhum pod Running"
        fi
    fi
done

# ============================================================
header "10. ARGOCD"
# ============================================================

ARGOCD_PODS=$(kubectl get pods -n argocd --no-headers 2>/dev/null | grep -c "Running" || echo "0")
if [ "$ARGOCD_PODS" -ge 1 ]; then
    pass "ArgoCD: ${ARGOCD_PODS} pods Running"

    ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "NAO_ENCONTRADO")
    if [ "$ARGOCD_PWD" != "NAO_ENCONTRADO" ]; then
        pass "ArgoCD senha inicial disponivel"
        echo -e "    ${YELLOW}Senha: ${ARGOCD_PWD}${NC}"
    else
        warn "ArgoCD senha inicial nao encontrada"
    fi
else
    fail "ArgoCD: nenhum pod Running"
fi

# ArgoCD Applications
APP_COUNT=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$APP_COUNT" -ge 1 ]; then
    pass "ArgoCD Applications: ${APP_COUNT} configuradas"
    echo ""
    kubectl get applications -n argocd 2>/dev/null
    echo ""
else
    warn "ArgoCD: nenhuma Application configurada"
fi

# ============================================================
header "11. KUBERNETES SECURITY"
# ============================================================

# Network Policies
NP_COUNT=$(kubectl get networkpolicies -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$NP_COUNT" -ge 1 ]; then
    pass "NetworkPolicies: ${NP_COUNT} configuradas"
else
    warn "NetworkPolicies: nenhuma encontrada"
fi

# Security Context
for SVC in ngo-service donation-service volunteer-service; do
    RUN_AS_NON_ROOT=$(kubectl get deployment "$SVC" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}' 2>/dev/null || echo "")
    if [ "$RUN_AS_NON_ROOT" = "true" ]; then
        pass "${SVC}: runAsNonRoot=true"
    else
        warn "${SVC}: runAsNonRoot nao configurado no deployment"
    fi
done

# PDBs
PDB_COUNT=$(kubectl get pdb -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$PDB_COUNT" -ge 1 ]; then
    pass "PodDisruptionBudgets: ${PDB_COUNT} configurados"
else
    warn "PodDisruptionBudgets: nenhum encontrado"
fi

# HPAs
HPA_COUNT=$(kubectl get hpa -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$HPA_COUNT" -ge 1 ]; then
    pass "HorizontalPodAutoscalers: ${HPA_COUNT} configurados"
else
    warn "HPA: nenhum encontrado"
fi

# ============================================================
header "12. FINOPS TAGS"
# ============================================================

TAGS=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=SolidaryTech --query 'length(ResourceTagMappingList)' --output text --region "$REGION" 2>/dev/null || echo "0")
if [ "$TAGS" -ge 5 ]; then
    pass "Recursos com tag Project=SolidaryTech: ${TAGS}"
else
    warn "Apenas ${TAGS} recursos com tag Project=SolidaryTech"
fi

# ============================================================
header "13. CUSTO ATUAL"
# ============================================================

echo -e "  ${YELLOW}Budget: \$50.00 (verificar no Learner Lab)${NC}"
echo ""
echo "  Recursos ativos estimados:"
echo "    EKS Control Plane:  \$0.10/h"
echo "    EC2 (${NODE_COUNT}x t3.medium): \$$(echo "scale=3; 0.042 * ${NODE_COUNT}" | bc)/h"
echo "    NAT Gateway:        \$0.045/h"
echo "    RDS:                \$0.018/h"
echo "    ElastiCache:        \$0.017/h"
TOTAL_HOUR=$(echo "scale=3; 0.10 + 0.042 * ${NODE_COUNT} + 0.045 + 0.018 + 0.017" | bc)
echo "    ─────────────────────────────"
echo -e "    ${YELLOW}TOTAL:              ~\$${TOTAL_HOUR}/h (~\$$(echo "scale=2; ${TOTAL_HOUR} * 24" | bc)/dia)${NC}"

# ============================================================
header "RESULTADO FINAL"
# ============================================================

echo ""
echo -e "  ${GREEN}PASS: ${PASS}${NC}"
echo -e "  ${RED}FAIL: ${FAIL}${NC}"
echo -e "  ${YELLOW}WARN: ${WARN}${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}Ambiente validado com sucesso!${NC}"
else
    echo -e "  ${RED}${FAIL} item(s) falharam - verifique acima.${NC}"
fi

echo ""
echo "══════════════════════════════════════════"
echo "  ACESSOS (executar em terminais separados)"
echo "══════════════════════════════════════════"
echo ""
echo "  Grafana (dashboards SRE):"
echo "    kubectl port-forward svc/grafana 3000:3000 -n monitoring"
echo "    Abrir: http://localhost:3000 (admin/admin)"
echo ""
echo "  Prometheus (metricas):"
echo "    kubectl port-forward svc/prometheus 9091:9090 -n monitoring"
echo "    Abrir: http://localhost:9091"
echo ""
echo "  ArgoCD (GitOps):"
echo "    kubectl port-forward svc/argocd-server 8443:443 -n argocd"
echo "    Abrir: https://localhost:8443 (admin/${ARGOCD_PWD:-ver_acima})"
echo ""
echo "  APIs dos microservicos:"
echo "    kubectl port-forward svc/ngo-service 8080:8080 -n solidarytech"
echo "    kubectl port-forward svc/donation-service 8081:8081 -n solidarytech"
echo "    kubectl port-forward svc/volunteer-service 8082:8082 -n solidarytech"
echo ""
echo "  Testar APIs:"
echo "    curl http://localhost:8080/health"
echo "    curl http://localhost:8080/api/v1/ngos"
echo "    curl http://localhost:8081/health"
echo "    curl http://localhost:8081/api/v1/donations/stats"
echo "    curl http://localhost:8082/health"
echo "    curl http://localhost:8082/api/v1/volunteers"
echo ""
echo "  Para parar e economizar: bash scripts/stop-environment.sh"
echo "  Para destruir tudo:      bash scripts/destroy.sh"
echo ""
