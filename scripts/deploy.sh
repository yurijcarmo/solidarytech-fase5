#!/usr/bin/env bash
set -euo pipefail

PROJECT="solidarytech"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
TF_DIR="terraform/environments/production"
CLUSTER_NAME="${PROJECT}-eks-production"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERRO] $1 nao encontrado"; exit 1; }; }
for c in aws terraform kubectl; do need "$c"; done

: "${AWS_ACCESS_KEY_ID:?Exporte AWS_ACCESS_KEY_ID do AWS Academy}"
: "${AWS_SECRET_ACCESS_KEY:?Exporte AWS_SECRET_ACCESS_KEY do AWS Academy}"
: "${AWS_SESSION_TOKEN:?Exporte AWS_SESSION_TOKEN do AWS Academy}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="${PROJECT}-terraform-state-${ACCOUNT_ID}"

echo "[1/6] AWS OK - conta ${ACCOUNT_ID}"

if ! aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  echo "[2/6] Criando bucket de state: $STATE_BUCKET"
  aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" >/dev/null
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
else
  echo "[2/6] Bucket de state ja existe"
fi

EKS_CLUSTER_ROLE="$(aws iam list-roles --query "Roles[?contains(RoleName,'LabEksClusterRole')].RoleName | [0]" --output text 2>/dev/null || true)"
EKS_NODE_ROLE="$(aws iam list-roles --query "Roles[?contains(RoleName,'LabEksNodeRole')].RoleName | [0]" --output text 2>/dev/null || true)"
[[ -z "$EKS_CLUSTER_ROLE" || "$EKS_CLUSTER_ROLE" == "None" ]] && EKS_CLUSTER_ROLE="LabRole"
[[ -z "$EKS_NODE_ROLE" || "$EKS_NODE_ROLE" == "None" ]] && EKS_NODE_ROLE="LabRole"

echo "[3/6] Roles: cluster=$EKS_CLUSTER_ROLE node=$EKS_NODE_ROLE"

if [[ -z "${DB_USERNAME:-}" ]]; then read -r -p "DB username [solidarytech_admin]: " DB_USERNAME; fi
DB_USERNAME="${DB_USERNAME:-solidarytech_admin}"
if [[ -z "${DB_PASSWORD:-}" ]]; then read -r -s -p "DB password: " DB_PASSWORD; echo; fi
[[ ${#DB_PASSWORD} -lt 8 ]] && { echo "[ERRO] DB_PASSWORD precisa ter pelo menos 8 caracteres"; exit 1; }

export TF_VAR_db_username="$DB_USERNAME"
export TF_VAR_db_password="$DB_PASSWORD"
export TF_VAR_eks_cluster_role_name="$EKS_CLUSTER_ROLE"
export TF_VAR_eks_node_role_name="$EKS_NODE_ROLE"

terraform -chdir="$TF_DIR" init -upgrade \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=environments/production/terraform.tfstate" \
  -backend-config="region=$REGION" \
  -backend-config="encrypt=true"
terraform -chdir="$TF_DIR" fmt -check -recursive
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" plan -out=tfplan

echo "[4/6] Aplicando Terraform..."
terraform -chdir="$TF_DIR" apply tfplan

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
kubectl get nodes

echo "[INFO] Instalando Metrics Server (addon do cluster)..."
kubectl apply -f kubernetes/base/cluster/metrics-server.yaml

echo "[5/6] Criando secrets de runtime (fora do Git)..."
RDS_ENDPOINT="$(terraform -chdir="$TF_DIR" output -raw rds_endpoint)"
SQS_URL="$(terraform -chdir="$TF_DIR" output -raw sqs_donations_queue_url)"
REDIS_URL="$(terraform -chdir="$TF_DIR" output -raw redis_url)"
DATABASE_URL="postgresql://${DB_USERNAME}:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/solidarytech"

kubectl create namespace solidarytech --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic solidarytech-secrets -n solidarytech \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --from-literal=SQS_QUEUE_URL="$SQS_URL" \
  --from-literal=REDIS_URL="$REDIS_URL" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  read -r -s -p "Grafana admin password: " GRAFANA_ADMIN_PASSWORD
  echo
fi
kubectl create secret generic grafana-admin-secret -n monitoring \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
  kubectl create secret generic newrelic-otel -n monitoring \
    --from-literal=license-key="$NEW_RELIC_LICENSE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "[OK] Secret New Relic criado"
else
  echo "[AVISO] NEW_RELIC_LICENSE_KEY nao exportada. Crie antes do bootstrap do ArgoCD."
fi

unset TF_VAR_db_password DB_PASSWORD DATABASE_URL

echo "[6/6] Infraestrutura pronta."
echo "Proximo passo: execute as 3 pipelines CI no GitHub Actions e depois ./scripts/bootstrap-argocd.sh"
