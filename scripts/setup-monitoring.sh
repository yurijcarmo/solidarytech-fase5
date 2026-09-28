#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=monitoring

echo "[INFO] Monitoring is managed by ArgoCD. Validating resources..."
kubectl get pods -n "$NAMESPACE"
kubectl get svc -n "$NAMESPACE"

echo
echo "Grafana:    kubectl port-forward svc/grafana -n monitoring 3000:3000"
echo "Prometheus: kubectl port-forward svc/prometheus -n monitoring 9091:9090"
echo "ArgoCD:     kubectl port-forward svc/argocd-server -n argocd 8443:443"
