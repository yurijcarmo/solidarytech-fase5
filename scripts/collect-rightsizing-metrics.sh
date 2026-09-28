#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-solidarytech}"
INTERVAL="${INTERVAL:-10}"
DURATION="${DURATION:-360}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-docs/evidence}"
METRICS_FILE="${OUT_DIR}/rightsizing-${TIMESTAMP}.csv"
HPA_FILE="${OUT_DIR}/rightsizing-hpa-${TIMESTAMP}.log"

mkdir -p "$OUT_DIR"

echo "Checking Kubernetes metrics API..."

if ! kubectl top pods -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: Kubernetes metrics are not available."
    echo "Check cluster connectivity and metrics-server before collecting."
    exit 1
fi

echo "timestamp,pod,container,cpu,memory" > "$METRICS_FILE"

echo "Collecting metrics every ${INTERVAL}s for ${DURATION}s"
echo "Metrics: $METRICS_FILE"
echo "HPA:     $HPA_FILE"

END_TIME=$(( $(date +%s) + DURATION ))

while [ "$(date +%s)" -lt "$END_TIME" ]; do
    NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    kubectl top pods \
        -n "$NAMESPACE" \
        --containers \
        --no-headers \
        2>/dev/null |
    awk -v ts="$NOW" '{
        printf "%s,%s,%s,%s,%s\n", ts, $1, $2, $3, $4
    }' >> "$METRICS_FILE"

    {
        echo "=== $NOW ==="
        kubectl get hpa -n "$NAMESPACE" 2>/dev/null || true
        echo
    } >> "$HPA_FILE"

    sleep "$INTERVAL"
done

echo
echo "Collection completed."
echo "Metrics: $METRICS_FILE"
echo "HPA:     $HPA_FILE"
