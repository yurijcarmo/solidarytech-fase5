#!/usr/bin/env bash
set -euo pipefail

ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-$(git config --get remote.origin.url 2>/dev/null || true)}"
if [[ -z "$ARGOCD_REPO_URL" ]]; then
  echo "[ERRO] Defina ARGOCD_REPO_URL com a URL do repositorio GitHub"
  exit 1
fi
if [[ "$ARGOCD_REPO_URL" =~ ^git@github.com:(.*)$ ]]; then
  ARGOCD_REPO_URL="https://github.com/${BASH_REMATCH[1]}"
fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

cp kubernetes/argocd/project.yaml "$TMP_DIR/project.yaml"
cp kubernetes/argocd/application-platform.yaml "$TMP_DIR/application-platform.yaml"
cp kubernetes/argocd/application-monitoring.yaml "$TMP_DIR/application-monitoring.yaml"

for f in "$TMP_DIR"/*.yaml; do
  sed -i.bak "s#https://github.com/CHANGE_ME/solidarytech.git#${ARGOCD_REPO_URL}#g" "$f"
  rm -f "$f.bak"
done

kubectl apply -f "$TMP_DIR/project.yaml"
kubectl apply -f "$TMP_DIR/application-platform.yaml"
kubectl apply -f "$TMP_DIR/application-monitoring.yaml"

echo "Aguardando reconciliacao..."
sleep 15
kubectl get applications -n argocd

echo
echo "ArgoCD: kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "Senha:  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
