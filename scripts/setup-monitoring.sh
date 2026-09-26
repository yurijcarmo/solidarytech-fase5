#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${PROJECT_ROOT}/kubernetes/monitoring"

log_step() { echo -e "${BLUE}[MONITORING $1]${NC} $2"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }

echo -e "${BLUE}Instalando stack de monitoramento...${NC}"

# Criar namespace
kubectl create namespace monitoring 2>/dev/null || true

kubectl create namespace solidarytech 2>/dev/null || true
if ! kubectl get secret solidarytech-secrets -n solidarytech 2>/dev/null; then
    kubectl create secret generic solidarytech-secrets \
        --from-literal=DATABASE_URL="placeholder" \
        --from-literal=SQS_QUEUE_URL="placeholder" \
        -n solidarytech
    log_ok "solidarytech-secrets criado (atualize com valores reais)"
fi

# Cluster components (metrics-server, cluster-autoscaler)
echo -e "${BLUE}Instalando componentes de cluster...${NC}"
kubectl apply -f "${PROJECT_ROOT}/kubernetes/base/cluster/" 2>/dev/null || true
# AWS Academy: LabEksNodeRole sem autoscaling:DescribeAutoScalingGroups
kubectl scale deployment/cluster-autoscaler -n kube-system --replicas=0 2>/dev/null || true
log_ok "Metrics-server configurado (Cluster Autoscaler desativado — limitacao IAM Academy)"

# Step 1: Prometheus + AlertManager + Alerting Rules
log_step "1/6" "Instalando Prometheus + AlertManager..."
kubectl apply -f "${K8S_DIR}/prometheus/" -n monitoring
kubectl apply -f "${K8S_DIR}/alertmanager/" -n monitoring
kubectl wait --for=condition=available deployment/prometheus \
    -n monitoring --timeout=180s 2>/dev/null || true
kubectl wait --for=condition=available deployment/alertmanager \
    -n monitoring --timeout=180s 2>/dev/null || true
log_ok "Prometheus + AlertManager instalados"

# Step 2: Grafana
log_step "2/6" "Instalando Grafana..."
if ! kubectl get secret grafana-admin-secret -n monitoring 2>/dev/null; then
    GRAFANA_PASS=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    kubectl create secret generic grafana-admin-secret \
        --from-literal=admin-password="${GRAFANA_PASS}" \
        -n monitoring
    log_ok "grafana-admin-secret criado (senha sera salva no arquivo de credenciais)"
fi
kubectl create configmap grafana-datasources \
    --from-file=datasources.yaml="${K8S_DIR}/grafana/provisioning/datasources/datasources.yaml" \
    -n monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap grafana-dashboard-provider \
    --from-file=dashboards.yaml="${K8S_DIR}/grafana/provisioning/dashboards/dashboards.yaml" \
    -n monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${K8S_DIR}/grafana/" -n monitoring
kubectl wait --for=condition=available deployment/grafana \
    -n monitoring --timeout=180s 2>/dev/null || true
log_ok "Grafana instalado"

# Step 3: Loki + Promtail
log_step "3/6" "Instalando Loki + Promtail..."
kubectl apply -f "${K8S_DIR}/loki/" -n monitoring
kubectl apply -f "${K8S_DIR}/promtail/" -n monitoring
kubectl wait --for=condition=available deployment/loki \
    -n monitoring --timeout=180s 2>/dev/null || true
log_ok "Loki + Promtail instalados"

# Step 4: OpenTelemetry Collector
log_step "4/6" "Instalando OpenTelemetry Collector..."
kubectl apply -f "${K8S_DIR}/otel-collector.yaml" -n monitoring
log_ok "OTel Collector instalado"

# Step 5: Self-Healing Handler
log_step "5/6" "Instalando Self-Healing Handler..."
kubectl apply -f "${K8S_DIR}/selfhealing/" -n monitoring
kubectl wait --for=condition=available deployment/selfhealing-handler \
    -n monitoring --timeout=120s 2>/dev/null || true
log_ok "Self-Healing Handler instalado"

# Step 6: Verificar pods
log_step "6/6" "Verificando pods de monitoramento..."
echo ""
kubectl get pods -n monitoring -o wide
echo ""

READY_COUNT=$(kubectl get pods -n monitoring --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
TOTAL_COUNT=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l)

if [ "$READY_COUNT" -eq "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
    log_ok "Todos os pods de monitoramento estao rodando (${READY_COUNT}/${TOTAL_COUNT})"
else
    echo -e "${YELLOW}[WARN]${NC} Alguns pods ainda nao estao prontos (${READY_COUNT}/${TOTAL_COUNT}). Verifique com: kubectl get pods -n monitoring"
fi

echo ""
echo -e "${GREEN}Stack de monitoramento instalada!${NC}"
echo ""
echo "Componentes:"
echo "  - Prometheus (metricas + alertas)"
echo "  - AlertManager (roteamento de alertas)"
echo "  - Grafana (dashboards SRE + SLO)"
echo "  - Loki + Promtail (logs centralizados)"
echo "  - OpenTelemetry Collector (traces)"
echo "  - Self-Healing Handler (remediacao automatica)"
echo ""
echo "Acessos:"
echo "  Prometheus:    kubectl port-forward svc/prometheus -n monitoring 9091:9090"
echo "  Grafana:       kubectl port-forward svc/grafana -n monitoring 3000:3000"
echo "  AlertManager:  kubectl port-forward svc/alertmanager -n monitoring 9093:9093"
echo "  Loki:          kubectl port-forward svc/loki -n monitoring 3100:3100"
