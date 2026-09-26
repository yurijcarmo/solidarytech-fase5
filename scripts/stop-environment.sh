#!/bin/bash
set -euo pipefail

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
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  PAUSAR AMBIENTE - Economia de Custos           ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Esta acao vai PAUSAR (nao destruir) os recursos mais caros:"
echo "  - Deployments: escalar para 0 replicas"
echo "  - PDBs: remover para nao bloquear drain dos nodes"
echo "  - EKS Node Group: escalar para 0 nodes (para EC2)"
echo "  - Lifecycle Hooks: completar para nao travar terminacao"
echo "  - RDS PostgreSQL: parar instancia (para cobranca)"
echo ""
echo "Recursos que continuam ativos (custo minimo):"
echo "  - EKS Control Plane: \$0.10/h (nao pode ser pausado)"
echo "  - NAT Gateway: \$0.045/h"
echo "  - S3, SQS: desprezivel"
echo ""
read -p "Deseja pausar o ambiente? (y/N) " -n 1 -r
echo ""
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Operacao cancelada."; exit 0; }

echo ""
log "Iniciando parada ordenada..."
echo ""

# ─── FASE 1: Escalar deployments para 0 replicas ───
scale_down_workloads() {
    log "FASE 1/5: Escalando workloads para 0 replicas..."

    for ns in solidarytech monitoring argocd; do
        local deployments
        deployments=$(kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
        if [ -n "$deployments" ]; then
            for dep in $deployments; do
                kubectl scale deployment "$dep" --replicas=0 -n "$ns" 2>/dev/null && \
                    success "Deployment $ns/$dep escalado para 0" || \
                    warn "Falha ao escalar $ns/$dep"
            done
        fi

        local statefulsets
        statefulsets=$(kubectl get statefulsets -n "$ns" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
        if [ -n "$statefulsets" ]; then
            for sts in $statefulsets; do
                kubectl scale statefulset "$sts" --replicas=0 -n "$ns" 2>/dev/null && \
                    success "StatefulSet $ns/$sts escalado para 0" || \
                    warn "Falha ao escalar $ns/$sts"
            done
        fi
    done

    local daemonsets
    daemonsets=$(kubectl get daemonsets -n monitoring --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
    if [ -n "$daemonsets" ]; then
        for ds in $daemonsets; do
            kubectl patch daemonset "$ds" -n monitoring -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}' 2>/dev/null && \
                success "DaemonSet monitoring/$ds desativado" || \
                warn "Falha ao desativar monitoring/$ds"
        done
    fi

    log "Aguardando pods terminarem (max 30s)..."
    kubectl wait --for=delete pods --all -n solidarytech --timeout=30s 2>/dev/null || true
    kubectl wait --for=delete pods --all -n monitoring --timeout=15s 2>/dev/null || true
    kubectl wait --for=delete pods --all -n argocd --timeout=15s 2>/dev/null || true

    success "Workloads parados"
}

# ─── FASE 2: Remover PDBs que bloqueiam drain ───
remove_pdbs() {
    log "FASE 2/5: Removendo PDBs (evita travamento no drain dos nodes)..."

    for ns in solidarytech kube-system monitoring argocd; do
        local pdbs
        pdbs=$(kubectl get pdb -n "$ns" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
        if [ -n "$pdbs" ]; then
            for pdb in $pdbs; do
                kubectl delete pdb "$pdb" -n "$ns" 2>/dev/null && \
                    success "PDB $ns/$pdb removido" || \
                    warn "PDB $ns/$pdb nao encontrado"
            done
        fi
    done

    success "PDBs removidos"
}

# ─── FASE 3: Escalar nodes para 0 e completar lifecycle hooks ───
scale_down_eks() {
    log "FASE 3/5: Escalando EKS nodes para 0..."

    local nodegroup
    nodegroup=$(aws eks list-nodegroups \
        --cluster-name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'nodegroups[0]' --output text 2>/dev/null)

    if [ -z "$nodegroup" ] || [ "$nodegroup" = "None" ]; then
        warn "Node group nao encontrado"
        return
    fi

    aws eks update-nodegroup-config \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$nodegroup" \
        --scaling-config minSize=0,maxSize=4,desiredSize=0 \
        --region "$AWS_REGION" 2>/dev/null

    success "Node Group '$nodegroup' desiredSize=0"

    log "Aguardando ASG iniciar terminacao (15s)..."
    sleep 15

    local asg_name
    asg_name=$(aws autoscaling describe-auto-scaling-groups \
        --region "$AWS_REGION" \
        --query "AutoScalingGroups[?contains(AutoScalingGroupName, '${CLUSTER_NAME}') || contains(AutoScalingGroupName, '${nodegroup}')].AutoScalingGroupName | [0]" \
        --output text 2>/dev/null || true)

    if [ -n "$asg_name" ] && [ "$asg_name" != "None" ]; then
        local hook_instances
        hook_instances=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$asg_name" \
            --region "$AWS_REGION" \
            --query 'AutoScalingGroups[0].Instances[?LifecycleState==`Terminating:Wait`].InstanceId' \
            --output text 2>/dev/null || true)

        if [ -n "$hook_instances" ] && [ "$hook_instances" != "None" ]; then
            log "Completando lifecycle hooks para destravar terminacao..."
            for instance_id in $hook_instances; do
                aws autoscaling complete-lifecycle-action \
                    --lifecycle-hook-name "Terminate-LC-Hook" \
                    --auto-scaling-group-name "$asg_name" \
                    --instance-id "$instance_id" \
                    --lifecycle-action-result CONTINUE \
                    --region "$AWS_REGION" 2>/dev/null && \
                    success "Lifecycle hook completado: $instance_id" || \
                    warn "Hook nao encontrado para $instance_id (pode ja ter terminado)"
            done
        fi
    fi

    log "Aguardando instancias terminarem (max 60s)..."
    local attempts=0
    while [ $attempts -lt 6 ]; do
        local running
        running=$(aws ec2 describe-instances \
            --filters "Name=tag:eks:nodegroup-name,Values=$nodegroup" "Name=instance-state-name,Values=running,shutting-down" \
            --region "$AWS_REGION" \
            --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

        if [ -z "$running" ] || [ "$running" = "None" ]; then
            success "Todas as instancias EC2 terminadas"
            return
        fi

        attempts=$((attempts + 1))
        sleep 10
    done

    warn "Algumas instancias ainda terminando (ASG completara em breve)"
}

# ─── FASE 4: Parar RDS ───
stop_rds() {
    log "FASE 4/5: Parando RDS..."

    local db_instance="${PROJECT_NAME}-postgres"

    local db_status
    db_status=$(aws rds describe-db-instances \
        --db-instance-identifier "$db_instance" \
        --region "$AWS_REGION" \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "not-found")

    if [ "$db_status" = "available" ]; then
        aws rds stop-db-instance \
            --db-instance-identifier "$db_instance" \
            --region "$AWS_REGION" 2>/dev/null

        success "RDS '$db_instance' sendo parado"
        echo -e "  ${YELLOW}AVISO: RDS reinicia automaticamente apos 7 dias se nao for retomado${NC}"
    elif [ "$db_status" = "stopped" ] || [ "$db_status" = "stopping" ]; then
        success "RDS ja esta ${db_status}"
    else
        warn "RDS status: $db_status"
    fi
}

# ─── FASE 5: Parar DR ───
stop_dr_environment() {
    log "FASE 5/5: Verificando ambiente DR..."

    local dr_cluster="${PROJECT_NAME}-eks-dr"
    local dr_region="us-west-2"

    local dr_nodegroup
    dr_nodegroup=$(aws eks list-nodegroups \
        --cluster-name "$dr_cluster" \
        --region "$dr_region" \
        --query 'nodegroups[0]' --output text 2>/dev/null || echo "")

    if [ -n "$dr_nodegroup" ] && [ "$dr_nodegroup" != "None" ]; then
        aws eks update-nodegroup-config \
            --cluster-name "$dr_cluster" \
            --nodegroup-name "$dr_nodegroup" \
            --scaling-config minSize=0,maxSize=4,desiredSize=0 \
            --region "$dr_region" 2>/dev/null
        success "DR EKS escalado para 0 nodes"

        sleep 10

        local dr_asg_name
        dr_asg_name=$(aws autoscaling describe-auto-scaling-groups \
            --region "$dr_region" \
            --query "AutoScalingGroups[?contains(AutoScalingGroupName, '${dr_cluster}') || contains(AutoScalingGroupName, '${dr_nodegroup}')].AutoScalingGroupName | [0]" \
            --output text 2>/dev/null || true)

        if [ -n "$dr_asg_name" ] && [ "$dr_asg_name" != "None" ]; then
            local dr_hook_instances
            dr_hook_instances=$(aws autoscaling describe-auto-scaling-groups \
                --auto-scaling-group-names "$dr_asg_name" \
                --region "$dr_region" \
                --query 'AutoScalingGroups[0].Instances[?LifecycleState==`Terminating:Wait`].InstanceId' \
                --output text 2>/dev/null || true)

            if [ -n "$dr_hook_instances" ] && [ "$dr_hook_instances" != "None" ]; then
                for instance_id in $dr_hook_instances; do
                    aws autoscaling complete-lifecycle-action \
                        --lifecycle-hook-name "Terminate-LC-Hook" \
                        --auto-scaling-group-name "$dr_asg_name" \
                        --instance-id "$instance_id" \
                        --lifecycle-action-result CONTINUE \
                        --region "$dr_region" 2>/dev/null && \
                        success "DR lifecycle hook completado: $instance_id" || true
                done
            fi
        fi
    else
        warn "DR EKS nao encontrado (pode nao estar provisionado)"
    fi

    local dr_db="${PROJECT_NAME}-dr-postgres"
    local dr_db_status
    dr_db_status=$(aws rds describe-db-instances \
        --db-instance-identifier "$dr_db" \
        --region "$dr_region" \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "not-found")

    if [ "$dr_db_status" = "available" ]; then
        aws rds stop-db-instance \
            --db-instance-identifier "$dr_db" \
            --region "$dr_region" 2>/dev/null
        success "DR RDS sendo parado"
    elif [ "$dr_db_status" = "not-found" ]; then
        warn "DR RDS nao encontrado"
    else
        success "DR RDS ja esta ${dr_db_status}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  AMBIENTE PAUSADO                               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Ordem de parada executada:"
    echo "    1. Deployments/StatefulSets escalados para 0 replicas"
    echo "    2. PDBs removidos (desbloqueiam drain dos nodes)"
    echo "    3. Nodes terminados (lifecycle hooks completados)"
    echo "    4. RDS parado"
    echo "    5. DR parado (se existente)"
    echo ""
    echo "  Recursos que continuam cobrando:"
    echo "    - EKS Control Plane (Prod + DR): \$0.20/h"
    echo "    - NAT Gateway (Prod + DR): \$0.09/h"
    echo "    - S3 + SQS: desprezivel"
    echo ""
    echo "  DICA: Para economia total, execute './scripts/destroy.sh'"
    echo ""
    echo "  Para retomar: ./scripts/start-environment.sh"
    echo ""
}

main() {
    scale_down_workloads
    echo ""
    remove_pdbs
    echo ""
    scale_down_eks
    echo ""
    stop_rds
    echo ""
    stop_dr_environment
    echo ""
    print_summary
}

main "$@"
