#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/lib/logging.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_NAME="solidarytech"
AWS_REGION="${AWS_REGION:-us-east-1}"
DR_REGION="us-west-2"
CLUSTER_NAME="${PROJECT_NAME}-eks-production"
DR_CLUSTER_NAME="${PROJECT_NAME}-eks-dr"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")

log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  ATENCAO: DESTRUICAO TOTAL DA INFRAESTRUTURA    ║${NC}"
echo -e "${RED}║  Esta acao e IRREVERSIVEL!                      ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Os seguintes recursos serao DELETADOS:"
echo "  - Cluster EKS + Node Group"
echo "  - Banco de dados RDS PostgreSQL"
echo "  - Filas SQS e DLQ"
echo "  - Repositorios ECR e imagens"
echo "  - Buckets S3"
echo "  - VPC, subnets, NAT Gateway, Internet Gateway, Security Groups"
echo "  - Ambiente DR (${DR_REGION})"
echo ""
read -p "Digite 'DESTRUIR' para confirmar: " CONFIRM
if [ "$CONFIRM" != "DESTRUIR" ]; then
    echo "Operacao cancelada."
    exit 0
fi
echo ""

# ============================================================
# Step 1: Kubernetes resources
# ============================================================
delete_k8s_resources() {
    log "Step 1/8: Removendo recursos Kubernetes..."

    if kubectl cluster-info &>/dev/null; then
        # Remover finalizers do ArgoCD antes de deletar namespace (evita travamento)
        for app in $(kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null); do
            kubectl patch "$app" -n argocd --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        done
        kubectl delete applications.argoproj.io --all -n argocd --force --grace-period=0 2>/dev/null || true

        for proj in $(kubectl get appprojects.argoproj.io -n argocd -o name 2>/dev/null); do
            kubectl patch "$proj" -n argocd --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        done
        kubectl delete appprojects.argoproj.io --all -n argocd --force --grace-period=0 2>/dev/null || true

        # Remover CRDs do ArgoCD (desbloqueia namespace se ainda travar)
        kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io 2>/dev/null || true

        # Remover APIService do metrics-server (trava namespace se metrics-server ja foi deletado)
        kubectl delete apiservice v1beta1.metrics.k8s.io 2>/dev/null || true

        kubectl delete namespace argocd --timeout=90s 2>/dev/null || true
        kubectl delete namespace monitoring --timeout=90s 2>/dev/null || true
        kubectl delete namespace solidarytech --timeout=90s 2>/dev/null || true
        success "Recursos Kubernetes removidos"
    else
        warn "kubectl nao conectado ao cluster - pulando limpeza K8s"
    fi
}

# ============================================================
# Step 2: EKS Node Group (must be deleted before cluster)
# ============================================================
delete_eks_nodegroups() {
    local cluster="$1"
    local region="$2"
    log "Deletando node groups do cluster ${cluster}..."

    NODEGROUPS=$(aws eks list-nodegroups \
        --cluster-name "$cluster" \
        --region "$region" \
        --query 'nodegroups[*]' --output text 2>/dev/null || echo "")

    if [ -z "$NODEGROUPS" ] || [ "$NODEGROUPS" = "None" ]; then
        warn "Nenhum node group encontrado em ${cluster}"
        return 0
    fi

    for ng in $NODEGROUPS; do
        log "  Deletando node group: ${ng}..."
        aws eks delete-nodegroup \
            --cluster-name "$cluster" \
            --nodegroup-name "$ng" \
            --region "$region" 2>/dev/null || { warn "  Falha ao deletar ${ng}"; continue; }

        log "  Aguardando node group ${ng} ser deletado (5-10 min)..."
        aws eks wait nodegroup-deleted \
            --cluster-name "$cluster" \
            --nodegroup-name "$ng" \
            --region "$region" 2>/dev/null || warn "  Timeout aguardando ${ng}"
        success "  Node group ${ng} deletado"
    done
}

# ============================================================
# Step 3: EKS Cluster (after node groups)
# ============================================================
delete_eks_cluster() {
    local cluster="$1"
    local region="$2"
    log "Deletando cluster EKS: ${cluster}..."

    STATUS=$(aws eks describe-cluster --name "$cluster" --region "$region" \
        --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$STATUS" = "NOT_FOUND" ]; then
        warn "Cluster ${cluster} nao encontrado"
        return 0
    fi

    aws eks delete-cluster --name "$cluster" --region "$region" 2>/dev/null || {
        warn "Falha ao deletar cluster ${cluster}"
        return 1
    }

    log "  Aguardando cluster ${cluster} ser deletado (2-5 min)..."
    aws eks wait cluster-deleted --name "$cluster" --region "$region" 2>/dev/null || warn "  Timeout aguardando cluster"
    success "Cluster ${cluster} deletado"
}

# ============================================================
# Step 4: RDS
# ============================================================
delete_rds() {
    local db_id="$1"
    local region="$2"
    log "Deletando RDS: ${db_id}..."

    DB_STATUS=$(aws rds describe-db-instances \
        --db-instance-identifier "$db_id" \
        --region "$region" \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "not-found")

    if [ "$DB_STATUS" = "not-found" ]; then
        warn "RDS ${db_id} nao encontrado"
        return 0
    fi

    if [ "$DB_STATUS" = "stopped" ]; then
        log "  RDS parado, iniciando para poder deletar..."
        aws rds start-db-instance --db-instance-identifier "$db_id" --region "$region" 2>/dev/null || true
        aws rds wait db-instance-available --db-instance-identifier "$db_id" --region "$region" 2>/dev/null || true
    fi

    # Desabilitar deletion protection antes de deletar
    log "  Desabilitando deletion protection..."
    aws rds modify-db-instance \
        --db-instance-identifier "$db_id" \
        --no-deletion-protection \
        --apply-immediately \
        --region "$region" 2>/dev/null || true
    sleep 5

    aws rds delete-db-instance \
        --db-instance-identifier "$db_id" \
        --skip-final-snapshot \
        --delete-automated-backups \
        --region "$region" 2>/dev/null || { warn "Falha ao deletar RDS ${db_id}"; return 1; }

    log "  Aguardando RDS ${db_id} ser deletado (3-5 min)..."
    aws rds wait db-instance-deleted --db-instance-identifier "$db_id" --region "$region" 2>/dev/null || warn "  Timeout aguardando RDS"
    success "RDS ${db_id} deletado"
}

# ============================================================
# Step 5: RDS Subnet Group
# ============================================================
delete_rds_subnet_groups() {
    local region="$1"
    log "Deletando RDS subnet groups em ${region}..."

    GROUPS=$(aws rds describe-db-subnet-groups --region "$region" \
        --query "DBSubnetGroups[?contains(DBSubnetGroupName,'${PROJECT_NAME}')].DBSubnetGroupName" \
        --output text 2>/dev/null || echo "")

    for grp in $GROUPS; do
        aws rds delete-db-subnet-group --db-subnet-group-name "$grp" --region "$region" 2>/dev/null && \
            success "  Subnet group ${grp} deletado" || warn "  Falha ao deletar ${grp}"
    done
}

# ============================================================
# Step 5b: RDS Parameter Group
# ============================================================
delete_rds_parameter_groups() {
    local region="$1"
    log "Deletando RDS parameter groups em ${region}..."

    GROUPS=$(aws rds describe-db-parameter-groups --region "$region" \
        --query "DBParameterGroups[?contains(DBParameterGroupName,'${PROJECT_NAME}')].DBParameterGroupName" \
        --output text 2>/dev/null || echo "")

    for grp in $GROUPS; do
        aws rds delete-db-parameter-group --db-parameter-group-name "$grp" --region "$region" 2>/dev/null && \
            success "  Parameter group ${grp} deletado" || warn "  Falha ao deletar ${grp}"
    done
}

# ============================================================
# Step 6: SQS
# ============================================================
delete_sqs() {
    local region="$1"
    log "Deletando filas SQS em ${region}..."

    QUEUES=$(aws sqs list-queues --region "$region" \
        --queue-name-prefix "${PROJECT_NAME}" \
        --query 'QueueUrls[*]' --output text 2>/dev/null || echo "")

    if [ -z "$QUEUES" ]; then
        warn "Nenhuma fila SQS encontrada"
        return 0
    fi

    for queue_url in $QUEUES; do
        aws sqs delete-queue --queue-url "$queue_url" --region "$region" 2>/dev/null && \
            success "  SQS deletada: $(basename "$queue_url")" || warn "  Falha ao deletar $(basename "$queue_url")"
    done
}

# ============================================================
# Step 7: ECR
# ============================================================
delete_ecr() {
    local region="$1"
    log "Deletando repositorios ECR em ${region}..."

    for svc in ngo-service donation-service volunteer-service; do
        REPO_NAME="${PROJECT_NAME}/${svc}"
        aws ecr delete-repository \
            --repository-name "$REPO_NAME" \
            --region "$region" \
            --force 2>/dev/null && \
            success "  ECR ${REPO_NAME} deletado" || warn "  ECR ${REPO_NAME} nao encontrado"
    done
}

# ============================================================
# Step 8: S3
# ============================================================
delete_s3() {
    log "Deletando buckets S3..."

    ACCOUNT_ID_FULL=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    BUCKETS_TO_DELETE=(
        "${PROJECT_NAME}-terraform-state-${ACCOUNT_ID_FULL}"
        "${PROJECT_NAME}-terraform-state"
        "${PROJECT_NAME}-backups-production"
        "${PROJECT_NAME}-backups-dr"
    )

    for bucket in "${BUCKETS_TO_DELETE[@]}"; do
        if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
            log "  Esvaziando ${bucket}..."
            aws s3 rm "s3://${bucket}" --recursive 2>/dev/null || true

            aws s3api list-object-versions --bucket "$bucket" --output json 2>/dev/null | \
                python3 -c "
import sys, json
data = json.load(sys.stdin)
versions = data.get('Versions', []) + data.get('DeleteMarkers', [])
if versions:
    objects = [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in versions]
    print(json.dumps({'Objects': objects, 'Quiet': True}))
" 2>/dev/null | while read -r DELETE_JSON; do
                    if [ -n "$DELETE_JSON" ]; then
                        aws s3api delete-objects --bucket "$bucket" --delete "$DELETE_JSON" 2>/dev/null || true
                    fi
                done

            aws s3api delete-bucket --bucket "$bucket" --region "$AWS_REGION" 2>/dev/null && \
                success "  Bucket ${bucket} deletado" || warn "  Falha ao deletar bucket ${bucket}"
        else
            warn "  Bucket ${bucket} nao encontrado"
        fi
    done
}

# ============================================================
# Step 9: VPC (security groups, subnets, IGW, NAT, VPC)
# ============================================================
delete_vpc() {
    local region="$1"
    log "Deletando VPC e recursos de rede em ${region}..."

    VPC_ID=$(aws ec2 describe-vpcs --region "$region" \
        --filters "Name=tag:Project,Values=SolidaryTech" \
        --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")

    if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
        warn "VPC SolidaryTech nao encontrada em ${region}"
        return 0
    fi

    log "  VPC encontrada: ${VPC_ID}"

    # Delete NAT Gateways
    log "  Deletando NAT Gateways..."
    NAT_GWS=$(aws ec2 describe-nat-gateways --region "$region" \
        --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" \
        --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null || echo "")
    for nat in $NAT_GWS; do
        aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$region" 2>/dev/null && \
            success "    NAT Gateway ${nat} deletado" || warn "    Falha ao deletar NAT ${nat}"
    done
    if [ -n "$NAT_GWS" ]; then
        log "  Aguardando NAT Gateways serem deletados..."
        local nat_wait=0
        while [ $nat_wait -lt 180 ]; do
            local pending=$(aws ec2 describe-nat-gateways --region "$region" \
                --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=deleting,pending" \
                --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null || echo "")
            [ -z "$pending" ] && break
            sleep 10
            nat_wait=$((nat_wait + 10))
        done
        [ $nat_wait -ge 180 ] && warn "  Timeout aguardando NAT Gateways" || success "    NAT Gateways removidos"
    fi

    # Release Elastic IPs
    log "  Liberando Elastic IPs..."
    EIPS=$(aws ec2 describe-addresses --region "$region" \
        --filters "Name=tag:Project,Values=SolidaryTech" \
        --query 'Addresses[*].AllocationId' --output text 2>/dev/null || echo "")
    for eip in $EIPS; do
        aws ec2 release-address --allocation-id "$eip" --region "$region" 2>/dev/null && \
            success "    EIP ${eip} liberado" || warn "    Falha ao liberar EIP ${eip}"
    done

    # Delete Load Balancers
    log "  Deletando Load Balancers..."
    LBS=$(aws elbv2 describe-load-balancers --region "$region" \
        --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text 2>/dev/null || echo "")
    for lb in $LBS; do
        aws elbv2 delete-load-balancer --load-balancer-arn "$lb" --region "$region" 2>/dev/null && \
            success "    LB deletado" || warn "    Falha ao deletar LB"
    done
    CLBs=$(aws elb describe-load-balancers --region "$region" \
        --query "LoadBalancerDescriptions[?VPCId=='${VPC_ID}'].LoadBalancerName" --output text 2>/dev/null || echo "")
    for clb in $CLBs; do
        aws elb delete-load-balancer --load-balancer-name "$clb" --region "$region" 2>/dev/null && \
            success "    Classic LB ${clb} deletado" || warn "    Falha ao deletar CLB ${clb}"
    done
    if [ -n "$LBS" ] || [ -n "$CLBs" ]; then
        sleep 15
    fi

    # Delete ENIs (network interfaces not attached)
    log "  Deletando ENIs orfas..."
    ENIS=$(aws ec2 describe-network-interfaces --region "$region" \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null || echo "")
    for eni in $ENIS; do
        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$region" 2>/dev/null || true
    done

    # Delete Security Groups (except default)
    log "  Deletando Security Groups..."
    SGS=$(aws ec2 describe-security-groups --region "$region" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || echo "")
    # First remove all ingress/egress rules referencing other SGs
    for sg in $SGS; do
        aws ec2 revoke-security-group-ingress --group-id "$sg" --region "$region" \
            --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --region "$region" \
            --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" 2>/dev/null || true
        aws ec2 revoke-security-group-egress --group-id "$sg" --region "$region" \
            --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$sg" --region "$region" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)" 2>/dev/null || true
    done
    # Now delete them
    for sg in $SGS; do
        aws ec2 delete-security-group --group-id "$sg" --region "$region" 2>/dev/null && \
            success "    SG ${sg} deletado" || warn "    Falha ao deletar SG ${sg} (pode ter dependencias)"
    done

    # Delete Subnets
    log "  Deletando subnets..."
    SUBNETS=$(aws ec2 describe-subnets --region "$region" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query 'Subnets[*].SubnetId' --output text 2>/dev/null || echo "")
    for subnet in $SUBNETS; do
        aws ec2 delete-subnet --subnet-id "$subnet" --region "$region" 2>/dev/null && \
            success "    Subnet ${subnet} deletada" || warn "    Falha ao deletar subnet ${subnet}"
    done

    # Delete Route Tables (except main)
    log "  Deletando route tables..."
    RTS=$(aws ec2 describe-route-tables --region "$region" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null || echo "")
    for rt in $RTS; do
        ASSOCS=$(aws ec2 describe-route-tables --route-table-ids "$rt" --region "$region" \
            --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text 2>/dev/null || echo "")
        for assoc in $ASSOCS; do
            aws ec2 disassociate-route-table --association-id "$assoc" --region "$region" 2>/dev/null || true
        done
        aws ec2 delete-route-table --route-table-id "$rt" --region "$region" 2>/dev/null || true
    done

    # Detach and delete Internet Gateway
    log "  Deletando Internet Gateway..."
    IGWS=$(aws ec2 describe-internet-gateways --region "$region" \
        --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
        --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null || echo "")
    for igw in $IGWS; do
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$region" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$region" 2>/dev/null && \
            success "    IGW ${igw} deletado" || warn "    Falha ao deletar IGW ${igw}"
    done

    # Delete VPC (com retry — dependencias podem demorar para liberar)
    log "  Deletando VPC ${VPC_ID}..."
    local vpc_retry=0
    while [ $vpc_retry -lt 3 ]; do
        if aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$region" 2>/dev/null; then
            success "  VPC ${VPC_ID} deletada"
            break
        fi
        vpc_retry=$((vpc_retry + 1))
        if [ $vpc_retry -lt 3 ]; then
            warn "  VPC tem dependencias residuais — limpando e tentando novamente (${vpc_retry}/3)..."
            for sg in $(aws ec2 describe-security-groups --region "$region" \
                --filters "Name=vpc-id,Values=${VPC_ID}" \
                --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
                aws ec2 delete-security-group --group-id "$sg" --region "$region" 2>/dev/null || true
            done
            for subnet in $(aws ec2 describe-subnets --region "$region" \
                --filters "Name=vpc-id,Values=${VPC_ID}" \
                --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
                aws ec2 delete-subnet --subnet-id "$subnet" --region "$region" 2>/dev/null || true
            done
            sleep 10
        fi
    done
    [ $vpc_retry -ge 3 ] && warn "  Falha ao deletar VPC ${VPC_ID} apos 3 tentativas"
}

# ============================================================
# Step 10: ElastiCache
# ============================================================
delete_elasticache() {
    local region="$1"
    log "Deletando ElastiCache em ${region}..."

    CLUSTERS=$(aws elasticache describe-cache-clusters --region "$region" \
        --query "CacheClusters[?contains(CacheClusterId,'${PROJECT_NAME}')].CacheClusterId" \
        --output text 2>/dev/null || echo "")

    for cluster in $CLUSTERS; do
        aws elasticache delete-cache-cluster --cache-cluster-id "$cluster" --region "$region" 2>/dev/null && \
            success "  ElastiCache ${cluster} deletado" || warn "  Falha ao deletar ${cluster}"
    done

    SUBNET_GROUPS=$(aws elasticache describe-cache-subnet-groups --region "$region" \
        --query "CacheSubnetGroups[?contains(CacheSubnetGroupName,'${PROJECT_NAME}')].CacheSubnetGroupName" \
        --output text 2>/dev/null || echo "")

    if [ -n "$CLUSTERS" ]; then
        log "  Aguardando ElastiCache ser completamente deletado..."
        for cluster in $CLUSTERS; do
            local max_wait=300
            local elapsed=0
            while [ $elapsed -lt $max_wait ]; do
                local status=$(aws elasticache describe-cache-clusters --region "$region" \
                    --cache-cluster-id "$cluster" \
                    --query "CacheClusters[0].CacheClusterStatus" \
                    --output text 2>/dev/null || echo "gone")
                if [ "$status" = "gone" ] || [ "$status" = "None" ]; then
                    success "  ElastiCache ${cluster} completamente removido"
                    break
                fi
                sleep 15
                elapsed=$((elapsed + 15))
            done
            if [ $elapsed -ge $max_wait ]; then
                warn "  Timeout aguardando ${cluster} ser deletado"
            fi
        done
    fi

    for sg in $SUBNET_GROUPS; do
        local retry=0
        while [ $retry -lt 3 ]; do
            aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$sg" --region "$region" 2>/dev/null && \
                success "  Subnet group ${sg} deletado" && break
            retry=$((retry + 1))
            [ $retry -lt 3 ] && sleep 15
        done
        [ $retry -ge 3 ] && warn "  Falha ao deletar subnet group ${sg}"
    done
}

# ============================================================
# Step 11: DynamoDB
# ============================================================
delete_dynamodb() {
    local region="$1"
    log "Deletando DynamoDB em ${region}..."

    TABLES=$(aws dynamodb list-tables --region "$region" \
        --query "TableNames[?contains(@,'${PROJECT_NAME}')]" --output text 2>/dev/null || echo "")

    for table in $TABLES; do
        aws dynamodb delete-table --table-name "$table" --region "$region" 2>/dev/null && \
            success "  Tabela ${table} deletada" || warn "  Falha ao deletar ${table}"
    done
}

# ============================================================
# Step 12: CloudWatch Log Groups
# ============================================================
delete_cloudwatch_logs() {
    local region="$1"
    log "Deletando CloudWatch Log Groups em ${region}..."

    for prefix in "/aws/eks/${PROJECT_NAME}" "/aws/rds/${PROJECT_NAME}"; do
        LOG_GROUPS=$(aws logs describe-log-groups --region "$region" \
            --log-group-name-prefix "$prefix" \
            --query 'logGroups[*].logGroupName' --output text 2>/dev/null || echo "")

        for lg in $LOG_GROUPS; do
            aws logs delete-log-group --log-group-name "$lg" --region "$region" 2>/dev/null && \
                success "  Log group ${lg} deletado" || warn "  Falha ao deletar ${lg}"
        done
    done
}

# ============================================================
# Step 13: Verificacao final e limpeza de residuos
# ============================================================
verify_clean() {
    local region="$1"
    log "Verificacao final em ${region}..."
    local has_residue=false

    # Verificar VPC residual
    local vpc_id=$(aws ec2 describe-vpcs --region "$region" \
        --filters "Name=tag:Project,Values=SolidaryTech" \
        --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
    if [ "$vpc_id" != "None" ] && [ -n "$vpc_id" ]; then
        warn "VPC residual encontrada: ${vpc_id} em ${region} — tentando remover..."
        has_residue=true
        # Forcar limpeza de subnets e SGs residuais
        for sg in $(aws ec2 describe-security-groups --region "$region" \
            --filters "Name=vpc-id,Values=${vpc_id}" \
            --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
            aws ec2 delete-security-group --group-id "$sg" --region "$region" 2>/dev/null || true
        done
        for subnet in $(aws ec2 describe-subnets --region "$region" \
            --filters "Name=vpc-id,Values=${vpc_id}" \
            --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
            aws ec2 delete-subnet --subnet-id "$subnet" --region "$region" 2>/dev/null || true
        done
        aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$region" 2>/dev/null && \
            success "  VPC ${vpc_id} removida na verificacao final" || warn "  VPC ${vpc_id} ainda nao pode ser removida"
    fi

    # Verificar ElastiCache subnet groups residuais
    local ec_sgs=$(aws elasticache describe-cache-subnet-groups --region "$region" \
        --query "CacheSubnetGroups[?contains(CacheSubnetGroupName,'${PROJECT_NAME}')].CacheSubnetGroupName" \
        --output text 2>/dev/null || echo "")
    for sg in $ec_sgs; do
        has_residue=true
        aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$sg" --region "$region" 2>/dev/null && \
            success "  ElastiCache subnet group residual ${sg} removido" || warn "  Falha: ${sg}"
    done

    # Verificar RDS subnet groups e parameter groups residuais
    local rds_sgs=$(aws rds describe-db-subnet-groups --region "$region" \
        --query "DBSubnetGroups[?contains(DBSubnetGroupName,'${PROJECT_NAME}')].DBSubnetGroupName" \
        --output text 2>/dev/null || echo "")
    for sg in $rds_sgs; do
        has_residue=true
        aws rds delete-db-subnet-group --db-subnet-group-name "$sg" --region "$region" 2>/dev/null && \
            success "  RDS subnet group residual ${sg} removido" || warn "  Falha: ${sg}"
    done

    local rds_pgs=$(aws rds describe-db-parameter-groups --region "$region" \
        --query "DBParameterGroups[?contains(DBParameterGroupName,'${PROJECT_NAME}')].DBParameterGroupName" \
        --output text 2>/dev/null || echo "")
    for pg in $rds_pgs; do
        has_residue=true
        aws rds delete-db-parameter-group --db-parameter-group-name "$pg" --region "$region" 2>/dev/null && \
            success "  RDS parameter group residual ${pg} removido" || warn "  Falha: ${pg}"
    done

    # Verificar CloudWatch Alarms residuais (SQS DLQ)
    local alarms=$(aws cloudwatch describe-alarms --region "$region" \
        --alarm-name-prefix "${PROJECT_NAME}" \
        --query 'MetricAlarms[*].AlarmName' --output text 2>/dev/null || echo "")
    for alarm in $alarms; do
        has_residue=true
        aws cloudwatch delete-alarms --alarm-names "$alarm" --region "$region" 2>/dev/null && \
            success "  Alarm residual ${alarm} removido" || true
    done

    if [ "$has_residue" = false ]; then
        success "  ${region}: limpo — nenhum recurso residual"
    fi
}

# ============================================================
# Main: Ordem correta de destruicao (dependencias primeiro)
# ============================================================
main() {
    echo -e "${BLUE}=== Fase 1: Kubernetes ===${NC}"
    delete_k8s_resources

    echo ""
    echo -e "${BLUE}=== Fase 2: EKS (Production) ===${NC}"
    delete_eks_nodegroups "$CLUSTER_NAME" "$AWS_REGION"
    delete_eks_cluster "$CLUSTER_NAME" "$AWS_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 3: EKS (DR) ===${NC}"
    delete_eks_nodegroups "$DR_CLUSTER_NAME" "$DR_REGION"
    delete_eks_cluster "$DR_CLUSTER_NAME" "$DR_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 4: RDS ===${NC}"
    delete_rds "${PROJECT_NAME}-postgres" "$AWS_REGION"
    delete_rds "${PROJECT_NAME}-dr-postgres" "$DR_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 5: RDS Subnet Groups + Parameter Groups ===${NC}"
    delete_rds_subnet_groups "$AWS_REGION"
    delete_rds_subnet_groups "$DR_REGION"
    delete_rds_parameter_groups "$AWS_REGION"
    delete_rds_parameter_groups "$DR_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 6: SQS ===${NC}"
    delete_sqs "$AWS_REGION"
    delete_sqs "$DR_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 7: ECR ===${NC}"
    delete_ecr "$AWS_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 8: S3 ===${NC}"
    delete_s3

    echo ""
    echo -e "${BLUE}=== Fase 9: ElastiCache ===${NC}"
    delete_elasticache "$AWS_REGION"
    delete_elasticache "$DR_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 10: DynamoDB ===${NC}"
    delete_dynamodb "$AWS_REGION"
    delete_dynamodb "$DR_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 11: VPC e Rede ===${NC}"
    delete_vpc "$AWS_REGION"
    delete_vpc "$DR_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 12: CloudWatch Logs ===${NC}"
    delete_cloudwatch_logs "$AWS_REGION"
    delete_cloudwatch_logs "$DR_REGION"

    echo ""
    echo -e "${BLUE}=== Fase 13: Verificacao final ===${NC}"
    verify_clean "$AWS_REGION"
    verify_clean "$DR_REGION"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  DESTRUICAO COMPLETA                            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

main "$@"
