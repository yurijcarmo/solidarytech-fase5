#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-plan}"
PROJECT="solidarytech"
PRIMARY_REGION="us-east-1"
DR_REGION="us-west-2"
TF_DIR="terraform/environments/dr"

: "${AWS_ACCESS_KEY_ID:?Exporte as credenciais do AWS Academy}"
: "${AWS_SECRET_ACCESS_KEY:?Exporte as credenciais do AWS Academy}"
: "${AWS_SESSION_TOKEN:?Exporte as credenciais do AWS Academy}"
: "${DB_USERNAME:?Exporte DB_USERNAME}"
: "${DB_PASSWORD:?Exporte DB_PASSWORD}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="${PROJECT}-terraform-state-${ACCOUNT_ID}"

CLUSTER_ROLE="$(aws iam list-roles --query "Roles[?contains(RoleName,'LabEksClusterRole')].RoleName | [0]" --output text 2>/dev/null || true)"
NODE_ROLE="$(aws iam list-roles --query "Roles[?contains(RoleName,'LabEksNodeRole')].RoleName | [0]" --output text 2>/dev/null || true)"
[[ -z "$CLUSTER_ROLE" || "$CLUSTER_ROLE" == "None" ]] && CLUSTER_ROLE=LabRole
[[ -z "$NODE_ROLE" || "$NODE_ROLE" == "None" ]] && NODE_ROLE=LabRole

export TF_VAR_db_username="$DB_USERNAME"
export TF_VAR_db_password="$DB_PASSWORD"
export TF_VAR_eks_cluster_role_name="$CLUSTER_ROLE"
export TF_VAR_eks_node_role_name="$NODE_ROLE"

terraform -chdir="$TF_DIR" init -upgrade \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=environments/dr/terraform.tfstate" \
  -backend-config="region=$PRIMARY_REGION" \
  -backend-config="encrypt=true"
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" plan -out=tfplan

echo "[OK] Warm Standby DR planejado em $DR_REGION"

if [[ "$MODE" == "apply" ]]; then
  terraform -chdir="$TF_DIR" apply tfplan
  echo "[OK] Infraestrutura DR criada"
else
  echo "Somente plan executado. Para criar o DR: ./scripts/deploy-dr.sh apply"
fi
