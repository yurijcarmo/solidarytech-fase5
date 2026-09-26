#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_NAME="solidarytech"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${PROJECT_NAME}-eks-production"

log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  RETOMAR AMBIENTE                               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

start_rds() {
    log "Iniciando instancia RDS..."

    DB_INSTANCE="${PROJECT_NAME}-postgres"

    DB_STATUS=$(aws rds describe-db-instances \
        --db-instance-identifier "$DB_INSTANCE" \
        --region "$AWS_REGION" \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "not-found")

    if [ "$DB_STATUS" = "stopped" ]; then
        aws rds start-db-instance \
            --db-instance-identifier "$DB_INSTANCE" \
            --region "$AWS_REGION"

        log "Aguardando RDS ficar disponivel (pode levar 5-10 minutos)..."
        aws rds wait db-instance-available \
            --db-instance-identifier "$DB_INSTANCE" \
            --region "$AWS_REGION"

        success "RDS '$DB_INSTANCE' disponivel"
    elif [ "$DB_STATUS" = "available" ]; then
        success "RDS ja esta disponivel"
    else
        warn "RDS status: $DB_STATUS"
    fi
}

scale_up_eks() {
    local DESIRED_NODES=2
    log "Escalando EKS nodes para ${DESIRED_NODES}..."

    NODEGROUP=$(aws eks list-nodegroups \
        --cluster-name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'nodegroups[0]' --output text 2>/dev/null)

    if [ -n "$NODEGROUP" ] && [ "$NODEGROUP" != "None" ]; then
        aws eks update-nodegroup-config \
            --cluster-name "$CLUSTER_NAME" \
            --nodegroup-name "$NODEGROUP" \
            --scaling-config minSize="${DESIRED_NODES}",maxSize=3,desiredSize="${DESIRED_NODES}" \
            --region "$AWS_REGION"

        log "Aguardando nodes ficarem prontos (pode levar 3-5 minutos)..."
        sleep 30

        READY=0
        for i in $(seq 1 20); do
            NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
            NODE_COUNT=${NODE_COUNT:-0}
            if [ "$NODE_COUNT" -ge "$DESIRED_NODES" ]; then
                READY=1
                break
            fi
            log "  Aguardando nodes... (${NODE_COUNT}/${DESIRED_NODES} prontos)"
            sleep 15
        done

        if [ "$READY" -eq 1 ]; then
            success "EKS com ${NODE_COUNT} node(s) pronto(s)"
        else
            warn "Timeout aguardando nodes - verifique manualmente: kubectl get nodes"
        fi
    else
        warn "Node group nao encontrado"
    fi
}

verify_pods() {
    log "Verificando pods..."

    kubectl get pods -n solidarytech 2>/dev/null || warn "Namespace solidarytech nao encontrado"
    echo ""

    READY_PODS=$(kubectl get pods -n solidarytech --no-headers 2>/dev/null | grep -c "Running" || true)
    READY_PODS=${READY_PODS:-0}
    TOTAL_PODS=$(kubectl get pods -n solidarytech --no-headers 2>/dev/null | wc -l | tr -d ' ')
    TOTAL_PODS=${TOTAL_PODS:-0}

    if [ "$READY_PODS" -eq "$TOTAL_PODS" ] && [ "$TOTAL_PODS" -gt 0 ]; then
        success "Todos os $READY_PODS pods estao rodando"
    else
        warn "$READY_PODS de $TOTAL_PODS pods rodando - aguarde mais tempo ou verifique logs"
        log "Dica: kubectl describe pods -n solidarytech"
    fi
}

verify_services() {
    log "Verificando servicos..."

    for SERVICE in ngo-service donation-service volunteer-service; do
        SVC_IP=$(kubectl get svc "$SERVICE" -n solidarytech -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        if [ -n "$SVC_IP" ]; then
            success "  $SERVICE: ClusterIP $SVC_IP"
        else
            warn "  $SERVICE: nao encontrado"
        fi
    done
}

start_dr_environment() {
    log "Retomando ambiente DR..."

    DR_CLUSTER="${PROJECT_NAME}-eks-dr"
    DR_REGION="us-west-2"

    DR_NODEGROUP=$(aws eks list-nodegroups \
        --cluster-name "$DR_CLUSTER" \
        --region "$DR_REGION" \
        --query 'nodegroups[0]' --output text 2>/dev/null || echo "")

    if [ -n "$DR_NODEGROUP" ] && [ "$DR_NODEGROUP" != "None" ]; then
        CURRENT_DESIRED=$(aws eks describe-nodegroup \
            --cluster-name "$DR_CLUSTER" \
            --nodegroup-name "$DR_NODEGROUP" \
            --region "$DR_REGION" \
            --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null || echo "0")

        if [ "$CURRENT_DESIRED" = "0" ]; then
            aws eks update-nodegroup-config \
                --cluster-name "$DR_CLUSTER" \
                --nodegroup-name "$DR_NODEGROUP" \
                --scaling-config minSize=1,maxSize=3,desiredSize=1 \
                --region "$DR_REGION" 2>/dev/null
            success "DR EKS escalado para 1 node (warm standby)"
        else
            success "DR EKS ja possui ${CURRENT_DESIRED} node(s)"
        fi
    else
        warn "DR EKS nao encontrado (pode nao estar provisionado)"
    fi
}

print_status() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  AMBIENTE RETOMADO                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Status:"
    echo "  - RDS Producao: disponivel"
    echo "  - EKS Producao: 2 nodes ativos"
    echo "  - EKS DR: 1 node (warm standby)"
    echo "  - RDS DR: Standalone (em producao real seria Read Replica)"
    echo "  - Pods: verificados"
    echo ""
    echo "Acessos:"
    echo "  Grafana:    kubectl port-forward svc/grafana 3000:3000 -n monitoring"
    echo "  Prometheus: kubectl port-forward svc/prometheus 9091:9090 -n monitoring"
    echo "  ArgoCD:     kubectl port-forward svc/argocd-server 8443:443 -n argocd"
    echo ""
    echo "Para pausar novamente: ./scripts/stop-environment.sh"
    echo ""
}

uncordon_nodes() {
    log "Desbloqueando nodes para scheduling..."
    for node in $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
        kubectl uncordon "$node" 2>/dev/null && \
            success "Node $node desbloqueado" || true
    done
}

restore_workloads() {
    log "Restaurando workloads..."

    # Restaurar DaemonSets (stop-environment desativa via nodeSelector)
    for ds in $(kubectl get daemonsets -n monitoring --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true); do
        kubectl patch daemonset "$ds" -n monitoring --type=json \
            -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/non-existing"}]' 2>/dev/null || true
    done

    # Restaurar deployments de monitoring
    for dep in $(kubectl get deployments -n monitoring --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true); do
        CURRENT=$(kubectl get deployment "$dep" -n monitoring -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "$CURRENT" = "0" ]; then
            kubectl scale deployment "$dep" -n monitoring --replicas=1 2>/dev/null || true
        fi
    done

    # Restaurar StatefulSets de monitoring
    for sts in $(kubectl get statefulsets -n monitoring --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true); do
        CURRENT=$(kubectl get statefulset "$sts" -n monitoring -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "$CURRENT" = "0" ]; then
            kubectl scale statefulset "$sts" -n monitoring --replicas=1 2>/dev/null || true
        fi
    done

    # Restaurar ArgoCD (server, repo-server, redis)
    for dep in argocd-server argocd-repo-server argocd-redis; do
        CURRENT=$(kubectl get deployment "$dep" -n argocd -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "$CURRENT" = "0" ]; then
            kubectl scale deployment "$dep" -n argocd --replicas=1 2>/dev/null || true
        fi
    done
    for sts in $(kubectl get statefulsets -n argocd --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true); do
        CURRENT=$(kubectl get statefulset "$sts" -n argocd -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "$CURRENT" = "0" ]; then
            kubectl scale statefulset "$sts" -n argocd --replicas=1 2>/dev/null || true
        fi
    done

    # Restaurar app services
    for dep in ngo-service donation-service volunteer-service; do
        CURRENT=$(kubectl get deployment "$dep" -n solidarytech -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "$CURRENT" = "0" ]; then
            kubectl scale deployment "$dep" -n solidarytech --replicas=1 2>/dev/null || true
        fi
    done

    # Reaplicar PDBs
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    for svc in ngo-service donation-service volunteer-service; do
        kubectl apply -f "${PROJECT_ROOT}/kubernetes/base/${svc}/pdb.yaml" 2>/dev/null || true
    done

    success "Workloads restaurados"
}

fix_imds_hop_limit() {
    log "Corrigindo IMDS hop limit nos nodes..."
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' --output text --region "${AWS_REGION}" 2>/dev/null || echo "")
    for iid in $INSTANCE_IDS; do
        aws ec2 modify-instance-metadata-options \
            --instance-id "$iid" \
            --http-put-response-hop-limit 2 \
            --region "${AWS_REGION}" > /dev/null 2>&1 || true
    done
    [ -n "$INSTANCE_IDS" ] && success "IMDS hop limit = 2 em $(echo $INSTANCE_IDS | wc -w) node(s)"
}

main() {
    start_rds
    scale_up_eks
    uncordon_nodes
    fix_imds_hop_limit
    restore_workloads
    start_dr_environment
    verify_pods
    verify_services
    print_status
}

main "$@"
