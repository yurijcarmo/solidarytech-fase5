#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

###############################################################################
# SolidaryTech - Automated Root Cause Analysis (RCA)
#
# Triggered after an incident is detected. Collects all relevant diagnostics
# and generates a structured RCA report in Markdown format.
#
# Usage:
#   ./automated-rca.sh [pod_name] [output_file]
#
# If output_file is not specified, prints to stdout.
###############################################################################

NAMESPACE="solidarytech"
POD_NAME="${1:-}"
OUTPUT_FILE="${2:-}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
INCIDENT_ID="INC-$(date +%s | tail -c 7)"

collect_to() {
    local section="$1"
    shift
    echo ""
    echo "### $section"
    echo '```'
    "$@" 2>&1 || echo "(comando falhou)"
    echo '```'
    echo ""
}

generate_report() {
cat << HEADER
# Root Cause Analysis (RCA) - Automatizado

| Campo | Valor |
|-------|-------|
| **Incident ID** | $INCIDENT_ID |
| **Data/Hora** | $TIMESTAMP |
| **Namespace** | $NAMESPACE |
| **Pod Afetado** | ${POD_NAME:-N/A} |
| **Gerado por** | AIOps Self-Healing System |

---

## 1. Estado Atual do Cluster

HEADER

collect_to "Pods no namespace $NAMESPACE" \
    kubectl get pods -n "$NAMESPACE" -o wide

collect_to "Eventos recentes (ultimos 30 min)" \
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' --field-selector type!=Normal

collect_to "Status dos Deployments" \
    kubectl get deployments -n "$NAMESPACE" -o wide

collect_to "Status dos HPAs" \
    kubectl get hpa -n "$NAMESPACE"

echo "## 2. Diagnostico do Pod Afetado"

if [ -n "$POD_NAME" ]; then
    collect_to "Describe do Pod" \
        kubectl describe pod "$POD_NAME" -n "$NAMESPACE"

    collect_to "Logs do Pod (ultimas 100 linhas)" \
        kubectl logs "$POD_NAME" -n "$NAMESPACE" --tail=100

    collect_to "Logs anteriores (se houve restart)" \
        kubectl logs "$POD_NAME" -n "$NAMESPACE" --previous --tail=50
else
    echo ""
    echo "_(Nenhum pod especifico informado. Coletando logs de todos os pods.)_"
    echo ""
    for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        collect_to "Logs: $pod (ultimas 30 linhas)" \
            kubectl logs "$pod" -n "$NAMESPACE" --tail=30
    done
fi

echo "## 3. Uso de Recursos"

collect_to "Top Pods (CPU e Memoria)" \
    kubectl top pods -n "$NAMESPACE"

collect_to "Top Nodes" \
    kubectl top nodes

echo "## 4. Deploys Recentes"

collect_to "Historico de Rollout - donation-service" \
    kubectl rollout history deployment/donation-service -n "$NAMESPACE"

collect_to "Historico de Rollout - ngo-service" \
    kubectl rollout history deployment/ngo-service -n "$NAMESPACE"

collect_to "Historico de Rollout - volunteer-service" \
    kubectl rollout history deployment/volunteer-service -n "$NAMESPACE"

echo "## 5. Network e Services"

collect_to "Services" \
    kubectl get svc -n "$NAMESPACE"

collect_to "Endpoints" \
    kubectl get endpoints -n "$NAMESPACE"

echo "## 6. Alertas Ativos"

collect_to "Alertas no Prometheus" \
    kubectl exec -n monitoring deploy/prometheus -- \
    wget -q -O- 'http://localhost:9090/api/v1/alerts' 2>/dev/null | \
    python3 -m json.tool 2>/dev/null || echo "(prometheus indisponivel)"

cat << FOOTER

---

## 7. Analise Preliminar (Automatizada)

### Possiveis Causas Raiz

Com base nos dados coletados, as seguintes causas devem ser investigadas:

1. **Exaustao de recursos**: Verificar se CPU/Memoria estao proximo dos limites
2. **Erro de aplicacao**: Analisar logs em busca de stack traces ou erros repetidos
3. **Deploy recente**: Correlacionar horario do incidente com ultimo deploy
4. **Dependencia externa**: Verificar conectividade com RDS, SQS e servicos externos
5. **Carga excessiva**: Verificar metricas de throughput e fila SQS

### Acoes Recomendadas

- [ ] Revisar logs de erro do pod afetado
- [ ] Verificar metricas de Golden Signals no Grafana
- [ ] Correlacionar com deploys recentes
- [ ] Verificar health das dependencias (RDS, SQS)
- [ ] Se deploy recente, considerar rollback via ArgoCD

---

## 8. Template de Post-Mortem

### Titulo: [Preencher apos investigacao]

**Severidade:** [SEV1/SEV2/SEV3/SEV4]
**Duracao:** [HH:MM de inicio a resolucao]
**Impacto:** [Numero de usuarios/doacoes afetadas]
**MTTR:** [Tempo entre deteccao e resolucao]

### Timeline
| Horario | Evento |
|---------|--------|
| $TIMESTAMP | Incidente detectado pelo AIOps |
| $TIMESTAMP | RCA automatizado iniciado |
| | [Preencher demais eventos] |

### O que aconteceu?
[Descricao objetiva do incidente]

### Por que aconteceu? (5 Whys)
1. Por que? ...
2. Por que? ...
3. Por que? ...
4. Por que? ...
5. Por que? ...

### O que foi feito para resolver?
[Descrever acoes de remediacao]

### O que vamos fazer para prevenir?
| Acao | Responsavel | Prazo | Status |
|------|-------------|-------|--------|
| | | | |

### Licoes Aprendidas
- [Item 1]
- [Item 2]

---
_Relatorio gerado automaticamente pelo AIOps Self-Healing System da SolidaryTech._
_Incident ID: ${INCIDENT_ID} | Timestamp: ${TIMESTAMP}_
FOOTER
}

report=$(generate_report)

if [ -n "$OUTPUT_FILE" ]; then
    echo "$report" > "$OUTPUT_FILE"
    echo "[RCA] Relatorio salvo em: $OUTPUT_FILE"
else
    echo "$report"
fi

echo "[RCA] Relatorio RCA gerado com sucesso. Incident ID: $INCIDENT_ID" >&2
