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
DR_CLUSTER="${PROJECT}-eks-dr"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${PROJECT_ROOT}/terraform/environments/dr"

log_step() { echo -e "\n${BLUE}[STEP $1/$TOTAL_STEPS]${NC} $2"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

TOTAL_STEPS=6

echo -e "${GREEN}"
echo "============================================="
echo "  SolidaryTech - Deploy DR (Warm Standby)"
echo "  Regiao DR: ${DR_REGION}"
echo "============================================="
echo -e "${NC}"
echo ""
echo "Este script cria o ambiente DR com Warm Standby:"
echo "  - EKS com 1 node (workload minimo)"
echo "  - RDS standalone (em producao real seria Read Replica)"
echo "  - Apps deployados com 1 replica cada"
echo "  - RTO estimado: 3-5 minutos (vs 30 min com Cold DR)"
echo ""

for cmd in aws terraform kubectl; do
    if ! command -v $cmd &> /dev/null; then
        log_err "$cmd nao encontrado."
        exit 1
    fi
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_STATE_BUCKET="${PROJECT}-terraform-state-${ACCOUNT_ID}"

EKS_CLUSTER_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName,'LabEksClusterRole')].RoleName | [0]" --output text 2>/dev/null)
EKS_NODE_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName,'LabEksNodeRole')].RoleName | [0]" --output text 2>/dev/null)
[ -z "$EKS_CLUSTER_ROLE" ] || [ "$EKS_CLUSTER_ROLE" = "None" ] && EKS_CLUSTER_ROLE="LabRole"
[ -z "$EKS_NODE_ROLE" ] || [ "$EKS_NODE_ROLE" = "None" ] && EKS_NODE_ROLE="LabRole"

# Step 1: Terraform DR
log_step 1 "Provisionando infraestrutura DR com Terraform..."
cd "${TF_DIR}"
rm -f backend.tf

terraform init -upgrade \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=environments/dr/terraform.tfstate" \
    -backend-config="region=${PRIMARY_REGION}" \
    -backend-config="encrypt=true"

echo ""
read -p "Digite a senha do banco (mesma da producao): " -s DB_PASSWORD
echo ""
read -p "Digite o usuario do banco (default: solidarytech_admin): " DB_USERNAME
DB_USERNAME="${DB_USERNAME:-solidarytech_admin}"

terraform plan -out=tfplan \
    -var="db_password=${DB_PASSWORD}" \
    -var="db_username=${DB_USERNAME}" \
    -var="eks_cluster_role_name=${EKS_CLUSTER_ROLE}" \
    -var="eks_node_role_name=${EKS_NODE_ROLE}"

echo ""
read -p "Aplicar plano Terraform DR? (y/n): " APPLY_CONFIRM
if [[ "${APPLY_CONFIRM}" == "y" ]]; then
    terraform apply tfplan
    log_ok "Infraestrutura DR provisionada"
else
    log_warn "Terraform apply cancelado"
    exit 0
fi
cd - > /dev/null

# Step 2: Configurar kubectl para DR
log_step 2 "Configurando kubectl para cluster DR..."
aws eks update-kubeconfig \
    --name "${DR_CLUSTER}" \
    --region "${DR_REGION}" \
    --alias "${DR_CLUSTER}"
log_ok "kubectl configurado para ${DR_CLUSTER}"

# Step 3: Criar namespace e secrets no DR
log_step 3 "Criando namespace e secrets no cluster DR..."
kubectl create namespace solidarytech 2>/dev/null || true

DR_RDS_ENDPOINT=$(terraform -chdir="${TF_DIR}" output -raw dr_rds_endpoint 2>/dev/null || echo "")
DR_SQS_URL=$(terraform -chdir="${TF_DIR}" output -raw dr_sqs_queue_url 2>/dev/null || echo "")

if [ -z "$DR_RDS_ENDPOINT" ]; then
    DR_RDS_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier "${PROJECT}-dr-postgres" \
        --region "${DR_REGION}" \
        --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "pending")
fi

if [ -z "$DR_SQS_URL" ]; then
    DR_SQS_URL=$(aws sqs get-queue-url \
        --queue-name "${PROJECT}-dr-donations" \
        --region "${DR_REGION}" \
        --query 'QueueUrl' --output text 2>/dev/null || echo "pending")
fi

DATABASE_URL="postgresql://${DB_USERNAME}:${DB_PASSWORD}@${DR_RDS_ENDPOINT}:5432/solidarytech"

kubectl create secret generic solidarytech-secrets \
    --namespace solidarytech \
    --from-literal=DATABASE_URL="${DATABASE_URL}" \
    --from-literal=SQS_QUEUE_URL="${DR_SQS_URL}" \
    --dry-run=client -o yaml | kubectl apply -f -
log_ok "Secrets DR criados"

# Step 4: Instalar ArgoCD no DR
log_step 4 "Instalando ArgoCD no cluster DR..."
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Aguardando ArgoCD ficar pronto..."
kubectl wait --for=condition=available deployment/argocd-server \
    -n argocd --timeout=300s

kubectl scale deployment argocd-dex-server -n argocd --replicas=0 2>/dev/null || true
kubectl scale deployment argocd-notifications-controller -n argocd --replicas=0 2>/dev/null || true
kubectl scale deployment argocd-applicationset-controller -n argocd --replicas=0 2>/dev/null || true

log_ok "ArgoCD instalado no DR (componentes nao-essenciais desligados)"

# Step 5: Setup monitoring minimo no DR
log_step 5 "Instalando monitoramento minimo no DR..."
kubectl create namespace monitoring 2>/dev/null || true

GRAFANA_PASS=$(openssl rand -base64 16)
kubectl create secret generic grafana-admin-secret \
    --namespace monitoring \
    --from-literal=admin-password="${GRAFANA_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${PROJECT_ROOT}/kubernetes/monitoring/" 2>/dev/null || log_warn "Alguns recursos de monitoring falharam (esperado)"
log_ok "Monitoramento minimo instalado"

# Step 6: Deploy das apps via ArgoCD
log_step 6 "Configurando aplicacoes no ArgoCD DR..."
kubectl apply -f "${PROJECT_ROOT}/kubernetes/argocd/" 2>/dev/null || true
log_ok "Aplicacoes configuradas"

# Verificar status
echo ""
echo "Aguardando pods ficarem prontos..."
sleep 30
kubectl get pods --all-namespaces 2>/dev/null || true

echo ""
echo -e "${GREEN}"
echo "============================================="
echo "  DR Warm Standby Ativo!"
echo "============================================="
echo -e "${NC}"
echo ""
echo "Status:"
echo "  - EKS DR: 1 node ativo em ${DR_REGION}"
echo "  - RDS DR: Standalone (em producao real seria Read Replica)"
echo "  - Apps: Deployados com replicas minimas"
echo "  - SQS DR: Fila pronta para failover"
echo ""
echo "RTO estimado: 3-5 minutos"
echo ""
echo "Para failover: ./scripts/dr-failover.sh"
echo "Para destruir: ./scripts/destroy.sh"
echo ""
