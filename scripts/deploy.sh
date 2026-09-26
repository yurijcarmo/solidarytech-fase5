#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT="solidarytech"
REGION="${AWS_REGION:-us-east-1}"
DR_REGION="us-west-2"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
TF_DIR="${PROJECT_ROOT}/terraform/environments/production"
TF_DR_DIR="${PROJECT_ROOT}/terraform/environments/dr"
K8S_DIR="${PROJECT_ROOT}/kubernetes"

log_step() { echo -e "\n${BLUE}[STEP $1/$TOTAL_STEPS]${NC} $2"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

TOTAL_STEPS=10

echo -e "${GREEN}"
echo "============================================="
echo "  SolidaryTech - Deploy Completo (Prod + DR)"
echo "  Producao: ${REGION}"
echo "  DR:       ${DR_REGION}"
echo "============================================="
echo -e "${NC}"

# ── Pre-requisitos ──────────────────────────────────────
echo -e "${BLUE}Verificando pre-requisitos...${NC}"
for cmd in aws terraform kubectl docker; do
    if ! command -v $cmd &> /dev/null; then
        log_err "$cmd nao encontrado. Instale antes de continuar."
        exit 1
    fi
done
log_ok "Todos os pre-requisitos instalados"

if ! aws sts get-caller-identity &> /dev/null; then
    log_err "Credenciais AWS nao configuradas. Execute 'aws configure' ou exporte as variaveis."
    exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_ok "AWS Account: ${ACCOUNT_ID}"

TF_STATE_BUCKET="${PROJECT}-terraform-state-${ACCOUNT_ID}"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
CLUSTER_NAME="${PROJECT}-eks-production"
DR_CLUSTER="${PROJECT}-eks-dr"

echo -e "${BLUE}Detectando IAM Roles do Academy Lab...${NC}"
EKS_CLUSTER_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName,'LabEksClusterRole')].RoleName | [0]" --output text 2>/dev/null)
EKS_NODE_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName,'LabEksNodeRole')].RoleName | [0]" --output text 2>/dev/null)

if [ -z "$EKS_CLUSTER_ROLE" ] || [ "$EKS_CLUSTER_ROLE" = "None" ]; then
    EKS_CLUSTER_ROLE="LabRole"
    log_warn "LabEksClusterRole nao encontrado, usando LabRole"
else
    log_ok "EKS Cluster Role: ${EKS_CLUSTER_ROLE}"
fi

if [ -z "$EKS_NODE_ROLE" ] || [ "$EKS_NODE_ROLE" = "None" ]; then
    EKS_NODE_ROLE="LabRole"
    log_warn "LabEksNodeRole nao encontrado, usando LabRole"
else
    log_ok "EKS Node Role: ${EKS_NODE_ROLE}"
fi

# ── Coletar credenciais do banco uma unica vez ──────────
echo ""
while true; do
    read -p "Digite a senha do banco de dados PostgreSQL: " -s DB_PASSWORD
    echo ""
    if [ ${#DB_PASSWORD} -lt 8 ]; then
        log_err "Senha deve ter no minimo 8 caracteres."
        continue
    fi
    if [[ "${DB_PASSWORD}" =~ [/@\"\ ] ]]; then
        log_err "Senha nao pode conter os caracteres: / @ \" ou espaco"
        continue
    fi
    if [[ "${DB_PASSWORD}" =~ [^[:print:]] ]]; then
        log_err "Senha deve conter apenas caracteres ASCII imprimiveis"
        continue
    fi
    break
done
read -p "Digite o usuario do banco (default: solidarytech_admin): " DB_USERNAME
DB_USERNAME="${DB_USERNAME:-solidarytech_admin}"

# ════════════════════════════════════════════════════════
#  PRODUCAO
# ════════════════════════════════════════════════════════

# Step 1: Criar bucket S3 para Terraform state
log_step 1 "Criando bucket S3 para Terraform state..."
if aws s3 ls "s3://${TF_STATE_BUCKET}" 2>/dev/null; then
    log_ok "Bucket ${TF_STATE_BUCKET} ja existe"
else
    aws s3 mb "s3://${TF_STATE_BUCKET}" --region "${REGION}"
    aws s3api put-bucket-versioning \
        --bucket "${TF_STATE_BUCKET}" \
        --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption \
        --bucket "${TF_STATE_BUCKET}" \
        --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-public-access-block \
        --bucket "${TF_STATE_BUCKET}" \
        --public-access-block-configuration \
        'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
    log_ok "Bucket ${TF_STATE_BUCKET} criado com versionamento, encriptacao e acesso publico bloqueado"
fi

# Step 2: Criar repositorios ECR
log_step 2 "Criando repositorios ECR..."
for service in ngo-service donation-service volunteer-service; do
    REPO_NAME="${PROJECT}/${service}"
    if aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REGION}" &>/dev/null; then
        aws ecr put-image-tag-mutability \
            --repository-name "${REPO_NAME}" \
            --image-tag-mutability MUTABLE \
            --region "${REGION}" > /dev/null 2>&1 || true
        log_ok "ECR ${REPO_NAME} ja existe (MUTABLE)"
    else
        aws ecr create-repository \
            --repository-name "${REPO_NAME}" \
            --region "${REGION}" \
            --image-scanning-configuration scanOnPush=true \
            --image-tag-mutability MUTABLE \
            --tags Key=Project,Value=SolidaryTech Key=ManagedBy,Value=Script \
            > /dev/null
        log_ok "ECR ${REPO_NAME} criado"
    fi
done

# Step 3: Terraform init e apply (Producao)
log_step 3 "Provisionando infraestrutura com Terraform..."

echo -e "${BLUE}Limpando recursos orfaos de deploy anterior...${NC}"
clean_orphans() {
    local region="$1"
    local prefix="$2"

    # EKS em estado FAILED
    local eks_name="${PROJECT}-eks-${prefix}"
    local eks_status=$(aws eks describe-cluster --name "${eks_name}" --region "${region}" \
        --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$eks_status" = "FAILED" ]; then
        log_warn "Cluster EKS ${eks_name} em estado FAILED — removendo..."
        aws eks delete-cluster --name "${eks_name}" --region "${region}" 2>/dev/null || true
        aws eks wait cluster-deleted --name "${eks_name}" --region "${region}" 2>/dev/null || true
        log_ok "Cluster FAILED removido: ${eks_name}"
    fi

    # RDS subnet groups orfaos
    for sg in $(aws rds describe-db-subnet-groups --region "${region}" \
        --query "DBSubnetGroups[?contains(DBSubnetGroupName,'${PROJECT}')].DBSubnetGroupName" \
        --output text 2>/dev/null); do
        aws rds delete-db-subnet-group --db-subnet-group-name "$sg" --region "${region}" 2>/dev/null && \
            log_ok "DB subnet group orfao removido: $sg" || true
    done

    # RDS parameter groups orfaos
    for pg in $(aws rds describe-db-parameter-groups --region "${region}" \
        --query "DBParameterGroups[?contains(DBParameterGroupName,'${PROJECT}')].DBParameterGroupName" \
        --output text 2>/dev/null); do
        aws rds delete-db-parameter-group --db-parameter-group-name "$pg" --region "${region}" 2>/dev/null && \
            log_ok "Parameter group orfao removido: $pg" || true
    done

    # ElastiCache subnet groups orfaos
    for ecsg in $(aws elasticache describe-cache-subnet-groups --region "${region}" \
        --query "CacheSubnetGroups[?contains(CacheSubnetGroupName,'${PROJECT}')].CacheSubnetGroupName" \
        --output text 2>/dev/null); do
        aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$ecsg" --region "${region}" 2>/dev/null && \
            log_ok "ElastiCache subnet group orfao removido: $ecsg" || true
    done

    # CloudWatch Log Groups orfaos
    for lg in $(aws logs describe-log-groups --region "${region}" \
        --log-group-name-prefix "/aws/eks/${PROJECT}" \
        --query 'logGroups[*].logGroupName' --output text 2>/dev/null); do
        aws logs delete-log-group --log-group-name "$lg" --region "${region}" 2>/dev/null && \
            log_ok "Log group orfao removido: $lg" || true
    done

    # CloudWatch Alarms orfaos (SQS DLQ)
    for alarm in $(aws cloudwatch describe-alarms --region "${region}" \
        --alarm-name-prefix "${PROJECT}" \
        --query 'MetricAlarms[*].AlarmName' --output text 2>/dev/null); do
        aws cloudwatch delete-alarms --alarm-names "$alarm" --region "${region}" 2>/dev/null && \
            log_ok "Alarm orfao removido: $alarm" || true
    done
}
clean_orphans "${REGION}" "production"
clean_orphans "${DR_REGION}" "dr"

BACKUP_BUCKET="${PROJECT}-backups-production"
if aws s3api head-bucket --bucket "${BACKUP_BUCKET}" 2>/dev/null; then
    log_warn "Removendo bucket ${BACKUP_BUCKET} de tentativa anterior..."
    aws s3 rm "s3://${BACKUP_BUCKET}" --recursive 2>/dev/null || true
    aws s3api delete-bucket --bucket "${BACKUP_BUCKET}" --region "${REGION}" 2>/dev/null || true
fi

rm -f "${TF_DIR}/backend.tf"

terraform -chdir="${TF_DIR}" init -upgrade \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=environments/production/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="encrypt=true"

export TF_VAR_db_password="${DB_PASSWORD}"
export TF_VAR_db_username="${DB_USERNAME}"
export TF_VAR_eks_cluster_role_name="${EKS_CLUSTER_ROLE}"
export TF_VAR_eks_node_role_name="${EKS_NODE_ROLE}"
export TF_VAR_tf_state_bucket="${TF_STATE_BUCKET}"

terraform -chdir="${TF_DIR}" plan -out=tfplan

echo ""
read -p "Deseja aplicar o plano Terraform? (y/n): " APPLY_CONFIRM
if [[ "${APPLY_CONFIRM}" == "y" ]]; then
    terraform -chdir="${TF_DIR}" apply tfplan
    log_ok "Infraestrutura provisionada com sucesso"
else
    log_warn "Terraform apply cancelado pelo usuario"
    exit 0
fi

# Step 4: Configurar kubectl
log_step 4 "Configurando kubectl para o cluster EKS..."
aws eks update-kubeconfig \
    --name "${CLUSTER_NAME}" \
    --region "${REGION}"
kubectl cluster-info
log_ok "kubectl configurado para o cluster ${CLUSTER_NAME}"

# Fix IMDS hop limit para pods acessarem credenciais IAM do node role
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text --region "${REGION}" 2>/dev/null || echo "")
for iid in $INSTANCE_IDS; do
    aws ec2 modify-instance-metadata-options \
        --instance-id "$iid" \
        --http-put-response-hop-limit 2 \
        --region "${REGION}" > /dev/null 2>&1 || true
done
[ -n "$INSTANCE_IDS" ] && log_ok "IMDS hop limit ajustado para 2 em $(echo $INSTANCE_IDS | wc -w) node(s)"

# Step 5: Instalar ArgoCD
log_step 5 "Instalando ArgoCD..."
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "Aguardando ArgoCD ficar pronto..."
kubectl wait --for=condition=available deployment/argocd-server \
    -n argocd --timeout=300s
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
log_ok "ArgoCD instalado (credenciais serao salvas no final)"

GRAFANA_PASSWORD=""

# Step 6: Aplicar stack de monitoramento
log_step 6 "Instalando stack de monitoramento..."
bash "${PROJECT_ROOT}/scripts/setup-monitoring.sh"
GRAFANA_PASSWORD=$(kubectl get secret grafana-admin-secret -n monitoring \
    -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "admin")
log_ok "Stack de monitoramento instalada"

# Step 7: Build e push das imagens Docker para ECR
log_step 7 "Build e push das imagens Docker para ECR..."
IMAGE_TAG="$(date +%Y%m%d%H%M%S)"

aws ecr get-login-password --region "${REGION}" | \
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"
log_ok "Login no ECR realizado"

for service in ngo-service donation-service volunteer-service; do
    IMAGE="${ECR_REGISTRY}/${PROJECT}/${service}"
    echo -e "${BLUE}  Building ${service}...${NC}"
    docker build -t "${IMAGE}:${IMAGE_TAG}" -t "${IMAGE}:latest" \
        "${PROJECT_ROOT}/microservices/${service}"
    echo -e "${BLUE}  Pushing ${service}...${NC}"
    docker push "${IMAGE}:${IMAGE_TAG}"
    docker push "${IMAGE}:latest"
    log_ok "${service} -> ${IMAGE}:${IMAGE_TAG}"
done
log_ok "Todas as imagens construidas e enviadas para o ECR"

# Step 8: Deploy e rollout dos servicos
log_step 8 "Aplicando aplicacoes e aguardando rollout..."
kubectl create namespace solidarytech 2>/dev/null || true

# Obter endpoints da infraestrutura para criar secrets
RDS_ENDPOINT=$(terraform -chdir="${TF_DIR}" output -raw rds_endpoint 2>/dev/null || echo "")
SQS_URL=$(terraform -chdir="${TF_DIR}" output -raw sqs_donations_queue_url 2>/dev/null || echo "")

if [ -z "$RDS_ENDPOINT" ]; then
    RDS_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier "${PROJECT}-postgres" \
        --region "${REGION}" \
        --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo "pending")
fi

if [ -z "$SQS_URL" ]; then
    SQS_URL=$(aws sqs get-queue-url \
        --queue-name "${PROJECT}-donations" \
        --region "${REGION}" \
        --query 'QueueUrl' --output text 2>/dev/null || echo "pending")
fi

DATABASE_URL="postgresql://${DB_USERNAME}:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/solidarytech"

kubectl create secret generic solidarytech-secrets \
    --namespace solidarytech \
    --from-literal=DATABASE_URL="${DATABASE_URL}" \
    --from-literal=SQS_QUEUE_URL="${SQS_URL}" \
    --dry-run=client -o yaml | kubectl apply -f -
log_ok "Secrets do solidarytech criados/atualizados"

# Aplicar configmaps, services, HPA, PDB e network policies
for service in ngo-service donation-service volunteer-service; do
    kubectl apply -f "${K8S_DIR}/base/${service}/configmap.yaml" 2>/dev/null || true
    kubectl apply -f "${K8S_DIR}/base/${service}/service.yaml" 2>/dev/null || true
    kubectl apply -f "${K8S_DIR}/base/${service}/hpa.yaml" 2>/dev/null || true
    kubectl apply -f "${K8S_DIR}/base/${service}/pdb.yaml" 2>/dev/null || true
done
kubectl apply -f "${K8S_DIR}/base/network-policies.yaml" -n solidarytech 2>/dev/null || true

# Aplicar deployments com a imagem do build atual
for service in ngo-service donation-service volunteer-service; do
    IMAGE="${ECR_REGISTRY}/${PROJECT}/${service}:${IMAGE_TAG}"
    sed "s|image:.*${service}.*|image: ${IMAGE}|" \
        "${K8S_DIR}/base/${service}/deployment.yaml" | kubectl apply -f -
done
# Worker do donation-service (usa mesma imagem)
DONATION_IMAGE="${ECR_REGISTRY}/${PROJECT}/donation-service:${IMAGE_TAG}"
sed "s|image:.*donation-service.*|image: ${DONATION_IMAGE}|" \
    "${K8S_DIR}/base/donation-service/worker-deployment.yaml" | kubectl apply -f -
kubectl apply -f "${K8S_DIR}/base/donation-service/worker-hpa.yaml" 2>/dev/null || true
# AWS Academy: LabEksNodeRole sem sqs:ReceiveMessage — worker fica em CrashLoopBackOff
kubectl scale deployment/donation-worker -n solidarytech --replicas=0 2>/dev/null || true
log_ok "Deployments aplicados com imagem tag ${IMAGE_TAG} (worker escalado a 0 — LabEksNodeRole sem sqs:ReceiveMessage)"

# Configurar ArgoCD para GitOps continuo
kubectl apply -f "${K8S_DIR}/argocd/" 2>/dev/null || true
log_ok "ArgoCD configurado para GitOps"

echo -e "${BLUE}Aguardando rollout completar...${NC}"
for service in ngo-service donation-service volunteer-service; do
    if kubectl rollout status deployment/${service} -n solidarytech --timeout=180s 2>/dev/null; then
        log_ok "${service} rollout completo"
    else
        log_warn "${service} rollout ainda em andamento"
    fi
done

# Step 9: Health Check
log_step 9 "Verificando saude do ambiente..."
bash "${PROJECT_ROOT}/scripts/post-deploy-check.sh" || log_warn "Health check detectou problemas — verifique acima"

# ════════════════════════════════════════════════════════
#  DR (Warm Standby)
# ════════════════════════════════════════════════════════

# Step 10: Deploy DR
log_step 10 "Provisionando DR (Warm Standby) em ${DR_REGION}..."
echo ""
echo "  O ambiente DR roda com workload minimo:"
echo "    - EKS: 1 node (t3.medium), escala somente no failover"
echo "    - RDS: Standalone db.t3.micro (em producao real seria Read Replica)"
echo "    - Apps: 1 replica cada"
echo ""

rm -f "${TF_DR_DIR}/backend.tf"

terraform -chdir="${TF_DR_DIR}" init -upgrade \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=environments/dr/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="encrypt=true"

terraform -chdir="${TF_DR_DIR}" plan -out=tfplan

terraform -chdir="${TF_DR_DIR}" apply tfplan
log_ok "Infraestrutura DR provisionada"

aws eks update-kubeconfig \
    --name "${DR_CLUSTER}" \
    --region "${DR_REGION}" \
    --alias "${DR_CLUSTER}"
log_ok "kubectl apontando para cluster DR"

# Namespace e secrets no DR
kubectl --context "${DR_CLUSTER}" create namespace solidarytech 2>/dev/null || true

DR_RDS_ENDPOINT=$(terraform -chdir="${TF_DR_DIR}" output -raw dr_rds_endpoint 2>/dev/null || echo "")
DR_SQS_URL=$(terraform -chdir="${TF_DR_DIR}" output -raw dr_sqs_queue_url 2>/dev/null || echo "")

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

DR_DATABASE_URL="postgresql://${DB_USERNAME}:${DB_PASSWORD}@${DR_RDS_ENDPOINT}:5432/solidarytech"

kubectl --context "${DR_CLUSTER}" create secret generic solidarytech-secrets \
    --namespace solidarytech \
    --from-literal=DATABASE_URL="${DR_DATABASE_URL}" \
    --from-literal=SQS_QUEUE_URL="${DR_SQS_URL}" \
    --dry-run=client -o yaml | kubectl --context "${DR_CLUSTER}" apply -f -
log_ok "Secrets DR criados"

# ArgoCD minimo no DR
kubectl --context "${DR_CLUSTER}" create namespace argocd 2>/dev/null || true
kubectl --context "${DR_CLUSTER}" apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "Aguardando ArgoCD DR ficar pronto..."
kubectl --context "${DR_CLUSTER}" wait --for=condition=available deployment/argocd-server \
    -n argocd --timeout=300s

kubectl --context "${DR_CLUSTER}" scale deployment argocd-dex-server -n argocd --replicas=0 2>/dev/null || true
kubectl --context "${DR_CLUSTER}" scale deployment argocd-notifications-controller -n argocd --replicas=0 2>/dev/null || true
kubectl --context "${DR_CLUSTER}" scale deployment argocd-applicationset-controller -n argocd --replicas=0 2>/dev/null || true
log_ok "ArgoCD DR instalado (componentes nao-essenciais desligados)"

# Monitoring minimo no DR
kubectl --context "${DR_CLUSTER}" create namespace monitoring 2>/dev/null || true
if ! kubectl --context "${DR_CLUSTER}" get secret grafana-admin-secret -n monitoring 2>/dev/null; then
    DR_GRAFANA_PASS=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    kubectl --context "${DR_CLUSTER}" create secret generic grafana-admin-secret \
        --from-literal=admin-password="${DR_GRAFANA_PASS}" \
        -n monitoring
fi
kubectl --context "${DR_CLUSTER}" apply -f "${K8S_DIR}/monitoring/" 2>/dev/null || log_warn "Alguns recursos de monitoring falharam no DR (esperado)"

# Apps via ArgoCD no DR
kubectl --context "${DR_CLUSTER}" apply -f "${K8S_DIR}/argocd/" 2>/dev/null || true
log_ok "Aplicacoes DR configuradas"

# Restaurar kubectl para producao
aws eks update-kubeconfig \
    --name "${CLUSTER_NAME}" \
    --region "${REGION}"
log_ok "kubectl restaurado para cluster de producao (${CLUSTER_NAME})"

DR_ARGOCD_PASSWORD=$(kubectl --context "${DR_CLUSTER}" -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")

# Limpar variaveis sensiveis do ambiente
unset TF_VAR_db_password TF_VAR_db_username

# ════════════════════════════════════════════════════════
#  Resumo (credenciais salvas em arquivo seguro, nao no log)
# ════════════════════════════════════════════════════════

CRED_FILE="${PROJECT_ROOT}/logs/.credentials-${TIMESTAMP}"
{
    echo "═══════════════════════════════════════════════"
    echo "  SolidaryTech — Credenciais de Deploy"
    echo "  Gerado em: $(date +'%Y-%m-%d %H:%M:%S %Z')"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "Producao (${REGION}):"
    echo "  ArgoCD:  admin / ${ARGOCD_PASSWORD}"
    echo "  Grafana: admin / ${GRAFANA_PASSWORD}"
    echo "  DB User: ${DB_USERNAME}"
    echo ""
    echo "DR Warm Standby (${DR_REGION}):"
    echo "  ArgoCD:  admin / ${DR_ARGOCD_PASSWORD}"
    echo ""
    echo "IMPORTANTE: Delete este arquivo apos anotar as credenciais."
} > "${CRED_FILE}"
chmod 600 "${CRED_FILE}"

echo ""
echo -e "${GREEN}"
echo "============================================="
echo "  Deploy Completo (Producao + DR)"
echo "============================================="
echo -e "${NC}"
echo ""
echo "Producao (${REGION}):"
echo "  EKS: ${CLUSTER_NAME}"
echo "  Grafana: kubectl port-forward svc/grafana -n monitoring 3000:3000"
echo ""
echo "DR Warm Standby (${DR_REGION}):"
echo "  EKS: 1 node (workload minimo)"
echo "  RDS: Standalone (em producao real seria Read Replica)"
echo "  RTO estimado: 3-5 minutos"
echo ""
echo -e "${YELLOW}Credenciais salvas em: ${CRED_FILE}${NC}"
echo -e "${YELLOW}(chmod 600 — somente seu usuario pode ler)${NC}"
echo ""
echo "Para failover: ./scripts/dr-failover.sh"
