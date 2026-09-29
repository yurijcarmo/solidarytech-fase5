#!/usr/bin/env bash
set -euo pipefail

REQUESTS="${REQUESTS:-120}"
CONCURRENCY="${CONCURRENCY:-8}"
NGO_URL="${NGO_URL:-http://localhost:8080}"
DONATION_URL="${DONATION_URL:-http://localhost:8081}"
VOLUNTEER_URL="${VOLUNTEER_URL:-http://localhost:8082}"
AUTO_PORT_FORWARD="${AUTO_PORT_FORWARD:-true}"
PF_PIDS=()

cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

if [[ "$AUTO_PORT_FORWARD" == "true" ]] && ! curl -fsS "$DONATION_URL/health" >/dev/null 2>&1; then
  echo "[INFO] Abrindo port-forwards Kubernetes..."
  kubectl port-forward svc/ngo-service -n solidarytech 8080:8080 >/tmp/solidarytech-pf-ngo.log 2>&1 & PF_PIDS+=("$!")
  kubectl port-forward svc/donation-service -n solidarytech 8081:8081 >/tmp/solidarytech-pf-donation.log 2>&1 & PF_PIDS+=("$!")
  kubectl port-forward svc/volunteer-service -n solidarytech 8082:8082 >/tmp/solidarytech-pf-volunteer.log 2>&1 & PF_PIDS+=("$!")
  sleep 5
fi

for url in "$NGO_URL/health" "$DONATION_URL/health" "$VOLUNTEER_URL/health"; do
  curl -fsS "$url" >/dev/null || { echo "[ERRO] Endpoint indisponivel: $url"; exit 1; }
done

echo "[1/4] Criando dados base..."
STAMP="$(date +%s)"
NGO_PAYLOAD=$(printf '{"name":"ONG Demo %s","cnpj":"%014d","contact_email":"demo%s@solidarytech.org"}' "$STAMP" "$((STAMP % 100000000000000))" "$STAMP")
NGO_JSON="$(curl -fsS -X POST "$NGO_URL/api/v1/ngos" -H 'Content-Type: application/json' -d "$NGO_PAYLOAD")"
NGO_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$NGO_JSON")"

for i in $(seq 1 5); do
  curl -fsS -X POST "$VOLUNTEER_URL/api/v1/volunteers" -H 'Content-Type: application/json' \
    -d "{\"name\":\"Volunteer Demo $i\",\"email\":\"vol${STAMP}_${i}@example.com\",\"skills\":[\"python\",\"cloud\"],\"city\":\"Rio de Janeiro\",\"state\":\"RJ\"}" >/dev/null
  curl -fsS -X POST "$VOLUNTEER_URL/api/v1/campaigns" -H 'Content-Type: application/json' \
    -d "{\"title\":\"Campaign Demo ${STAMP}-$i\",\"ngo_id\":$NGO_ID,\"required_skills\":[\"python\"]}" >/dev/null
done

echo "[2/4] Gerando $REQUESTS doacoes com concorrencia $CONCURRENCY..."
export DONATION_URL NGO_ID STAMP
batch_start=1

while [ "$batch_start" -le "$REQUESTS" ]; do
  batch_end=$((batch_start + CONCURRENCY - 1))

  if [ "$batch_end" -gt "$REQUESTS" ]; then
    batch_end="$REQUESTS"
  fi

  for i in $(seq "$batch_start" "$batch_end"); do
    (
      currencies=(BRL USD EUR GBP JPY)
      c=${currencies[$(( i % 5 ))]}

      curl -fsS -X POST "$DONATION_URL/api/v1/donations" \
        -H "Content-Type: application/json" \
        -d "{\"donor_name\":\"Demo Donor ${i}\",\"donor_email\":\"demo_${STAMP}_${i}@example.com\",\"ngo_id\":${NGO_ID},\"amount\":\"$((10 + i % 90)).00\",\"currency\":\"${c}\",\"payment_method\":\"pix\"}" >/dev/null
    ) &
  done

  wait
  batch_start=$((batch_end + 1))
done

echo "[3/4] Gerando leituras para traces e metricas..."
for i in $(seq 1 30); do
  curl -fsS "$NGO_URL/api/v1/ngos" >/dev/null
  curl -fsS "$VOLUNTEER_URL/api/v1/volunteers" >/dev/null
  curl -fsS "$DONATION_URL/api/v1/donations" >/dev/null
  curl -fsS "$DONATION_URL/api/v1/donations/stats" >/dev/null
  sleep 0.2
done

echo "[4/4] Resumo"
echo "  NGO criada:       $NGO_ID"
echo "  Doacoes enviadas: $REQUESTS"
echo "  Volunteers:       5"
echo "  Campaigns:        5"
echo "  Status:            OK"
echo
echo "Aguarde 30-60s e abra Grafana/New Relic para as evidencias."
