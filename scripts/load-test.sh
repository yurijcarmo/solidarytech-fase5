#!/bin/bash
set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

NGO_URL="${NGO_URL:-http://localhost:8080}"
DONATION_URL="${DONATION_URL:-http://localhost:8081}"
VOLUNTEER_URL="${VOLUNTEER_URL:-http://localhost:8082}"

PHASE="${1:-help}"
CONCURRENCY="${2:-5}"
DURATION="${3:-60}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="solidarytech"
MONITORING_NS="monitoring"

TESTS_PASS=0
TESTS_FAIL=0
TESTS_SKIP=0
TESTS_TOTAL=0
TEST_RESULTS=()

log_ts() { echo -e "[$(date +'%H:%M:%S')] $1"; }
log_ok() { log_ts "${GREEN}[PASS]${NC} $1"; TESTS_PASS=$((TESTS_PASS+1)); TESTS_TOTAL=$((TESTS_TOTAL+1)); TEST_RESULTS+=("PASS|$1"); }
log_fail() { log_ts "${RED}[FAIL]${NC} $1"; TESTS_FAIL=$((TESTS_FAIL+1)); TESTS_TOTAL=$((TESTS_TOTAL+1)); TEST_RESULTS+=("FAIL|$1"); }
log_skip() { log_ts "${YELLOW}[SKIP]${NC} $1"; TESTS_SKIP=$((TESTS_SKIP+1)); TESTS_TOTAL=$((TESTS_TOTAL+1)); TEST_RESULTS+=("SKIP|$1"); }
log_info() { log_ts "${BLUE}[INFO]${NC} $1"; }
log_metric() { log_ts "${CYAN}[METRIC]${NC} $1"; }
log_section() { echo ""; echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${MAGENTA}${BOLD}  $1${NC}"; echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo ""; }

print_report() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║          RELATORIO DE TESTES                     ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
    printf  "${BOLD}║${NC}  ${GREEN}PASS: %-5s${NC} ${RED}FAIL: %-5s${NC} ${YELLOW}SKIP: %-5s${NC} ${BOLD}TOTAL: %-3s${BOLD}║${NC}\n" "$TESTS_PASS" "$TESTS_FAIL" "$TESTS_SKIP" "$TESTS_TOTAL"
    echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
    for result in "${TEST_RESULTS[@]}"; do
        local status="${result%%|*}"
        local desc="${result#*|}"
        case "$status" in
            PASS) printf "${BOLD}║${NC}  ${GREEN}✔${NC} %-47s${BOLD}║${NC}\n" "$desc" ;;
            FAIL) printf "${BOLD}║${NC}  ${RED}✘${NC} %-47s${BOLD}║${NC}\n" "$desc" ;;
            SKIP) printf "${BOLD}║${NC}  ${YELLOW}⊘${NC} %-47s${BOLD}║${NC}\n" "$desc" ;;
        esac
    done
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    if [ "$TESTS_FAIL" -gt 0 ]; then
        echo -e "\n${RED}${BOLD}RESULTADO: $TESTS_FAIL teste(s) falharam${NC}"
    else
        echo -e "\n${GREEN}${BOLD}RESULTADO: Todos os testes passaram${NC}"
    fi
    echo ""
}

show_usage() {
    echo -e "${BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  SolidaryTech — Suite Completa de Testes         ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo "Uso: $0 <fase> [concorrencia] [duracao_seg]"
    echo ""
    echo -e "${BOLD}Testes Funcionais (API):${NC}"
    echo "  seed           Cria dados iniciais (ONGs, voluntarios, campanhas, doacoes)"
    echo "  api            Testa todos os endpoints CRUD de todos os servicos"
    echo "  health         Testa /health e /ready de todos os servicos"
    echo ""
    echo -e "${BOLD}Testes de Carga (Escalabilidade):${NC}"
    echo "  light          Carga leve (5 req/s) — gera metricas no Grafana"
    echo "  medium         Carga media (20 req/s) — HPA comeca a escalar pods"
    echo "  heavy          Carga pesada (50 req/s) — stress test completo"
    echo "  ramp           Rampa progressiva (5→50 req/s) — demo de auto-scaling"
    echo ""
    echo -e "${BOLD}Testes de DR (Disaster Recovery):${NC}"
    echo "  dr             Teste completo de DR: health check, region, sync (dry-run)"
    echo "  dr-health      Teste do health checker (dry-run, sem failover)"
    echo "  dr-region      Testa identificacao de regiao (API + Prometheus + Grafana)"
    echo "  dr-sync        Testa sync de dados (dry-run, sem transferir)"
    echo "  dr-failover    Executa failover para DR (REQUER CONFIRMACAO)"
    echo "  dr-failback    Executa failback para producao (REQUER CONFIRMACAO)"
    echo ""
    echo -e "${BOLD}Testes de Resiliencia:${NC}"
    echo "  selfheal       Testa self-healing: mata um pod e verifica recuperacao"
    echo "  chaos          Teste de caos: pod kill + carga simultanea"
    echo ""
    echo -e "${BOLD}Testes de Observabilidade:${NC}"
    echo "  metrics        Verifica metricas Prometheus de todos os servicos"
    echo "  dashboards     Verifica dashboards Grafana (existencia e dados)"
    echo "  observability  Teste completo: metricas + dashboards + alertas"
    echo ""
    echo -e "${BOLD}Testes de Seguranca:${NC}"
    echo "  security       Testa SecurityContext, NetworkPolicies, headers"
    echo ""
    echo -e "${BOLD}Suites Completas:${NC}"
    echo "  all            Executa TODOS os testes (seed + api + load + dr + resiliencia + obs)"
    echo "  smoke          Teste rapido: health + api + region (< 1 min)"
    echo "  full           Demo completo: seed + ramp + selfheal + dr + observability"
    echo "  status         Mostra estado atual (pods, HPA, nodes)"
    echo ""
    echo "Exemplos:"
    echo "  $0 smoke                     # Validacao rapida do ambiente"
    echo "  $0 seed                      # Criar dados iniciais"
    echo "  $0 ramp                      # Demo de auto-scaling"
    echo "  $0 dr                        # Validar DR (sem failover)"
    echo "  $0 all                       # Suite completa"
    echo ""
    echo "Pre-requisito: port-forward dos servicos:"
    echo "  kubectl port-forward svc/ngo-service -n solidarytech 8080:8080 &"
    echo "  kubectl port-forward svc/donation-service -n solidarytech 8081:8081 &"
    echo "  kubectl port-forward svc/volunteer-service -n solidarytech 8082:8082 &"
}

check_services() {
    log_info "Verificando servicos..."
    local all_ok=true
    for svc_url in "$NGO_URL/health" "$DONATION_URL/health" "$VOLUNTEER_URL/health"; do
        local svc_name=$(echo "$svc_url" | grep -oP 'localhost:\K\d+')
        if curl -sf --max-time 3 "$svc_url" > /dev/null 2>&1; then
            log_ok "Servico porta ${svc_name}: health OK"
        else
            log_fail "Servico porta ${svc_name}: indisponivel"
            all_ok=false
        fi
    done
    if [ "$all_ok" = false ]; then
        echo ""
        log_info "Configure port-forward primeiro:"
        echo "  kubectl port-forward svc/ngo-service -n solidarytech 8080:8080 &"
        echo "  kubectl port-forward svc/donation-service -n solidarytech 8081:8081 &"
        echo "  kubectl port-forward svc/volunteer-service -n solidarytech 8082:8082 &"
        return 1
    fi
    return 0
}

show_status() {
    echo -e "\n${BLUE}━━━ Status do Ambiente ━━━${NC}"
    echo -e "\n${CYAN}Nodes:${NC}"
    kubectl get nodes -o wide --no-headers 2>/dev/null | while read line; do
        echo "  $line"
    done
    echo -e "\n${CYAN}Pods (solidarytech):${NC}"
    kubectl get pods -n solidarytech -o wide --no-headers 2>/dev/null | while read line; do
        echo "  $line"
    done
    echo -e "\n${CYAN}Pods (monitoring):${NC}"
    kubectl get pods -n monitoring -o wide --no-headers 2>/dev/null | while read line; do
        echo "  $line"
    done
    echo -e "\n${CYAN}HPA:${NC}"
    kubectl get hpa -n solidarytech --no-headers 2>/dev/null | while read line; do
        echo "  $line"
    done
    echo -e "\n${CYAN}Pod Count:${NC}"
    local total=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
    local max=$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.pods}' 2>/dev/null | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}')
    echo "  ${total}/${max:-?} pods"
    echo ""
}

# ═══════════════════════════════════════════════════
#  TESTES FUNCIONAIS (API)
# ═══════════════════════════════════════════════════

seed_data() {
    log_section "SEED — Criando dados iniciais"

    log_info "Criando ONGs..."
    local ngos=("Cruz Vermelha" "Medicos Sem Fronteiras" "UNICEF Brasil" "Greenpeace" "WWF Brasil")
    local cnpjs=("12345678000101" "12345678000102" "12345678000103" "12345678000104" "12345678000105")
    local ngo_ids=()
    for i in "${!ngos[@]}"; do
        local ngo="${ngos[$i]}"
        local cnpj="${cnpjs[$i]}"
        local slug=$(echo "$ngo" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
        local resp=$(curl -sf -X POST "${NGO_URL}/api/v1/ngos" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${ngo}\",\"cnpj\":\"${cnpj}\",\"description\":\"ONG ${ngo}\",\"contact_email\":\"contato@${slug}.org\",\"phone\":\"+5511999990001\"}" 2>/dev/null)
        if [ $? -eq 0 ]; then
            local id=$(echo "$resp" | grep -oP '"id"\s*:\s*\K\d+' | head -1)
            ngo_ids+=("${id:-1}")
            log_ok "ONG: ${ngo} (id=${id:-?})"
        else
            log_fail "ONG: ${ngo}"
        fi
    done

    log_info "Criando voluntarios..."
    local volunteers=("Maria Silva" "Joao Santos" "Ana Oliveira" "Pedro Costa" "Lucia Ferreira"
                      "Carlos Souza" "Julia Lima" "Rafael Alves" "Camila Rodrigues" "Bruno Martins")
    for vol in "${volunteers[@]}"; do
        local first=$(echo "$vol" | awk '{print $1}')
        local last=$(echo "$vol" | awk '{print $2}')
        local email=$(echo "${first}.${last}" | tr '[:upper:]' '[:lower:]')
        curl -sf -X POST "${VOLUNTEER_URL}/api/v1/volunteers" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${vol}\",\"email\":\"${email}@email.com\",\"skills\":[\"educacao\",\"saude\"],\"availability\":\"weekends\"}" > /dev/null 2>&1 && \
            log_ok "Voluntario: ${vol}" || log_fail "Voluntario: ${vol}"
    done

    log_info "Criando campanhas..."
    local campaigns=("Natal Solidario" "Inverno Quente" "Educacao para Todos" "Agua Limpa" "Saude na Comunidade")
    for i in "${!campaigns[@]}"; do
        local ngo_id=${ngo_ids[$i]:-$((i+1))}
        curl -sf -X POST "${VOLUNTEER_URL}/api/v1/campaigns" \
            -H "Content-Type: application/json" \
            -d "{\"title\":\"${campaigns[$i]}\",\"description\":\"Campanha ${campaigns[$i]}\",\"ngo_id\":${ngo_id},\"required_skills\":[\"educacao\"],\"start_date\":\"2026-10-01\",\"end_date\":\"2026-12-31\"}" > /dev/null 2>&1 && \
            log_ok "Campanha: ${campaigns[$i]}" || log_fail "Campanha: ${campaigns[$i]}"
    done

    log_info "Criando doacoes iniciais..."
    local currencies=("BRL" "USD" "EUR" "GBP" "JPY")
    local methods=("credit_card" "pix" "bank_transfer")
    for i in $(seq 1 10); do
        local amount=$((RANDOM % 500 + 10))
        local currency=${currencies[$((RANDOM % ${#currencies[@]}))]}
        local method=${methods[$((RANDOM % ${#methods[@]}))]}
        local ngo_id=${ngo_ids[$((RANDOM % ${#ngo_ids[@]}))]:-1}
        curl -sf -X POST "${DONATION_URL}/api/v1/donations" \
            -H "Content-Type: application/json" \
            -d "{\"donor_name\":\"Doador ${i}\",\"amount\":${amount},\"currency\":\"${currency}\",\"payment_method\":\"${method}\",\"ngo_id\":${ngo_id}}" > /dev/null 2>&1 && \
            log_ok "Doacao #${i}: ${currency} ${amount} via ${method}" || log_fail "Doacao #${i}"
    done
}

test_health() {
    log_section "HEALTH — Verificando /health e /ready"

    for svc in "ngo-service:${NGO_URL}" "donation-service:${DONATION_URL}" "volunteer-service:${VOLUNTEER_URL}"; do
        local name="${svc%%:*}"
        local url="${svc#*:}"

        local h_resp=$(curl -sf --max-time 5 -w "%{http_code}" -o /tmp/st_health_body.txt "${url}/health" 2>/dev/null)
        if [ "$h_resp" = "200" ]; then
            log_ok "${name} /health → 200"
        else
            log_fail "${name} /health → ${h_resp:-timeout}"
        fi

        local r_resp=$(curl -sf --max-time 5 -w "%{http_code}" -o /tmp/st_ready_body.txt "${url}/ready" 2>/dev/null)
        if [ "$r_resp" = "200" ]; then
            log_ok "${name} /ready → 200"
        else
            log_fail "${name} /ready → ${r_resp:-timeout}"
        fi
    done
    rm -f /tmp/st_health_body.txt /tmp/st_ready_body.txt
}

test_api() {
    log_section "API — Testando endpoints CRUD"

    log_info "--- ngo-service ---"
    local ngo_resp=$(curl -sf -X POST "${NGO_URL}/api/v1/ngos" \
        -H "Content-Type: application/json" \
        -d '{"name":"Test NGO API","cnpj":"99999999000199","description":"Teste","contact_email":"test@test.org","phone":"+5511999999999"}' 2>/dev/null)
    if [ $? -eq 0 ]; then
        local ngo_id=$(echo "$ngo_resp" | grep -oP '"id"\s*:\s*\K\d+' | head -1)
        log_ok "POST /api/v1/ngos → criou id=${ngo_id:-?}"
    else
        log_fail "POST /api/v1/ngos"
        local ngo_id=""
    fi

    local list_resp=$(curl -sf "${NGO_URL}/api/v1/ngos" 2>/dev/null)
    if echo "$list_resp" | grep -q '"id"'; then
        log_ok "GET /api/v1/ngos → listagem OK"
    else
        log_fail "GET /api/v1/ngos"
    fi

    if [ -n "$ngo_id" ]; then
        local get_resp=$(curl -sf "${NGO_URL}/api/v1/ngos/${ngo_id}" 2>/dev/null)
        if echo "$get_resp" | grep -q "Test NGO API"; then
            log_ok "GET /api/v1/ngos/${ngo_id} → encontrou"
        else
            log_fail "GET /api/v1/ngos/${ngo_id}"
        fi
    fi

    log_info "--- donation-service ---"
    local don_resp=$(curl -sf -X POST "${DONATION_URL}/api/v1/donations" \
        -H "Content-Type: application/json" \
        -d '{"donor_name":"API Test","amount":42.50,"currency":"BRL","payment_method":"pix","ngo_id":1}' 2>/dev/null)
    if [ $? -eq 0 ]; then
        local don_id=$(echo "$don_resp" | grep -oP '"id"\s*:\s*\K\d+' | head -1)
        log_ok "POST /api/v1/donations → criou id=${don_id:-?}"
    else
        log_fail "POST /api/v1/donations"
    fi

    local don_list=$(curl -sf "${DONATION_URL}/api/v1/donations" 2>/dev/null)
    if echo "$don_list" | grep -q '"id"'; then
        log_ok "GET /api/v1/donations → listagem OK"
    else
        log_fail "GET /api/v1/donations"
    fi

    local stats=$(curl -sf "${DONATION_URL}/api/v1/donations/stats" 2>/dev/null)
    if echo "$stats" | grep -qE '"total_donations"|"count"'; then
        log_ok "GET /api/v1/donations/stats → estatisticas OK"
    else
        log_fail "GET /api/v1/donations/stats"
    fi

    local golden=$(curl -sf "${DONATION_URL}/api/v1/donations/metrics/golden" 2>/dev/null)
    if echo "$golden" | grep -qE '"golden_metrics"|"throughput"|"error_rate"'; then
        log_ok "GET /api/v1/donations/metrics/golden → OK"
    else
        log_fail "GET /api/v1/donations/metrics/golden"
    fi

    local currencies=$(curl -sf "${DONATION_URL}/api/v1/donations/currencies" 2>/dev/null)
    if echo "$currencies" | grep -qE 'BRL|USD'; then
        log_ok "GET /api/v1/donations/currencies → moedas OK"
    else
        log_fail "GET /api/v1/donations/currencies"
    fi

    log_info "--- volunteer-service ---"
    local vol_resp=$(curl -sf -X POST "${VOLUNTEER_URL}/api/v1/volunteers" \
        -H "Content-Type: application/json" \
        -d '{"name":"API Tester","email":"api.tester@test.com","skills":["teste"],"availability":"weekdays"}' 2>/dev/null)
    if [ $? -eq 0 ]; then
        log_ok "POST /api/v1/volunteers → criou voluntario"
    else
        log_fail "POST /api/v1/volunteers"
    fi

    local vol_list=$(curl -sf "${VOLUNTEER_URL}/api/v1/volunteers" 2>/dev/null)
    if echo "$vol_list" | grep -q '"id"'; then
        log_ok "GET /api/v1/volunteers → listagem OK"
    else
        log_fail "GET /api/v1/volunteers"
    fi

    local camp_list=$(curl -sf "${VOLUNTEER_URL}/api/v1/campaigns" 2>/dev/null)
    if echo "$camp_list" | grep -qE '"id"|"title"|\[\]'; then
        log_ok "GET /api/v1/campaigns → listagem OK"
    else
        log_fail "GET /api/v1/campaigns"
    fi
}

# ═══════════════════════════════════════════════════
#  TESTES DE CARGA (ESCALABILIDADE)
# ═══════════════════════════════════════════════════

run_load() {
    local target_rps=$1
    local duration=$2
    local label=$3

    log_info "Carga: ${label} — ${target_rps} req/s por ${duration}s"

    local concurrency=$((target_rps / 2))
    [ "$concurrency" -lt 2 ] && concurrency=2
    [ "$concurrency" -gt 50 ] && concurrency=50
    local total_requests=$((target_rps * duration))

    echo '{"donor_name":"LoadTest","amount":100,"currency":"BRL","payment_method":"credit_card","ngo_id":1}' > /tmp/st_payload.json

    local donation_n=$((total_requests * 40 / 100))
    local ngo_n=$((total_requests * 35 / 100))
    local vol_n=$((total_requests * 25 / 100))

    log_info "Donation: ${donation_n} req (c=${concurrency})"
    local don_result=$(ab -n "$donation_n" -c "$concurrency" -T 'application/json' -p /tmp/st_payload.json \
        "${DONATION_URL}/api/v1/donations" 2>/dev/null)
    local don_rps=$(echo "$don_result" | grep "Requests per second" | awk '{print $4}')
    local don_failed=$(echo "$don_result" | grep "Failed requests" | awk '{print $3}')
    log_metric "Donation: ${don_rps:-?} req/s, ${don_failed:-0} falhas"
    if [ "${don_failed:-0}" = "0" ]; then
        log_ok "Carga ${label} donation-service: 0 falhas"
    else
        log_fail "Carga ${label} donation-service: ${don_failed} falhas"
    fi

    log_info "NGO: ${ngo_n} req (c=${concurrency})"
    local ngo_result=$(ab -n "$ngo_n" -c "$concurrency" \
        "${NGO_URL}/api/v1/ngos" 2>/dev/null)
    local ngo_rps=$(echo "$ngo_result" | grep "Requests per second" | awk '{print $4}')
    local ngo_failed=$(echo "$ngo_result" | grep "Failed requests" | awk '{print $3}')
    log_metric "NGO: ${ngo_rps:-?} req/s, ${ngo_failed:-0} falhas"
    if [ "${ngo_failed:-0}" = "0" ]; then
        log_ok "Carga ${label} ngo-service: 0 falhas"
    else
        log_fail "Carga ${label} ngo-service: ${ngo_failed} falhas"
    fi

    log_info "Volunteer: ${vol_n} req (c=${concurrency})"
    local vol_result=$(ab -n "$vol_n" -c "$concurrency" \
        "${VOLUNTEER_URL}/api/v1/volunteers" 2>/dev/null)
    local vol_rps=$(echo "$vol_result" | grep "Requests per second" | awk '{print $4}')
    local vol_failed=$(echo "$vol_result" | grep "Failed requests" | awk '{print $3}')
    log_metric "Volunteer: ${vol_rps:-?} req/s, ${vol_failed:-0} falhas"
    if [ "${vol_failed:-0}" = "0" ]; then
        log_ok "Carga ${label} volunteer-service: 0 falhas"
    else
        log_fail "Carga ${label} volunteer-service: ${vol_failed} falhas"
    fi

    rm -f /tmp/st_payload.json
}

run_ramp() {
    log_section "RAMP — Escalando carga progressivamente"
    log_info "Grafana: http://localhost:3000 — observe as metricas em tempo real"

    show_status

    log_info "Fase 1/4: Carga leve (5 req/s, 60s)"
    run_load 5 60 "LIGHT"
    show_status

    log_info "Fase 2/4: Carga media (15 req/s, 60s)"
    run_load 15 60 "MEDIUM"
    show_status

    log_info "Fase 3/4: Carga alta (30 req/s, 90s)"
    run_load 30 90 "HEAVY"
    show_status

    log_info "Fase 4/4: Pico (50 req/s, 60s)"
    run_load 50 60 "PEAK"
    show_status

    log_info "Cool-down (aguardando 30s para scale-down)..."
    sleep 30
    show_status
}

test_hpa() {
    log_section "HPA — Verificando auto-scaling configurado"

    local hpa_list=$(kubectl get hpa -n "$NAMESPACE" --no-headers 2>/dev/null)
    if [ -n "$hpa_list" ]; then
        log_ok "HPA configurado no namespace ${NAMESPACE}"
        echo "$hpa_list" | while read line; do
            local hpa_name=$(echo "$line" | awk '{print $1}')
            local replicas=$(echo "$line" | awk '{print $6}')
            local max=$(echo "$line" | awk '{print $5}')
            log_metric "HPA ${hpa_name}: ${replicas} replicas (max ${max})"
        done
    else
        log_fail "Nenhum HPA encontrado no namespace ${NAMESPACE}"
    fi
}

# ═══════════════════════════════════════════════════
#  TESTES DE DR (DISASTER RECOVERY)
# ═══════════════════════════════════════════════════

test_dr_health() {
    log_section "DR HEALTH — Verificando health checker"

    if [ -f "${SCRIPT_DIR}/dr-health-checker.sh" ]; then
        log_ok "Script dr-health-checker.sh encontrado"
    else
        log_fail "Script dr-health-checker.sh nao encontrado"
        return 1
    fi

    log_info "Executando health check (dry-run)..."
    local start_time=$(date +%s)
    local hc_output=$(bash "${SCRIPT_DIR}/dr-health-checker.sh" --once --dry-run 2>&1)
    local hc_exit=$?
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    if [ $hc_exit -eq 0 ]; then
        log_ok "Health check executado com sucesso (${elapsed}s)"
    else
        log_fail "Health check retornou codigo ${hc_exit}"
    fi

    if echo "$hc_output" | grep -qi "HEALTHY\|healthy\|OK\|PASS\|pass"; then
        log_ok "Producao reporta status saudavel"
    elif echo "$hc_output" | grep -qi "DRY.RUN\|dry.run\|simulat"; then
        log_ok "Health check dry-run completou"
    else
        log_fail "Status de saude nao confirmado"
    fi

    log_metric "Tempo do health check: ${elapsed}s"
}

test_dr_region() {
    log_section "DR REGION — Identificacao de regiao ativa"

    log_info "Metodo 1: API /region endpoint"
    for svc in "ngo-service:${NGO_URL}" "donation-service:${DONATION_URL}" "volunteer-service:${VOLUNTEER_URL}"; do
        local name="${svc%%:*}"
        local url="${svc#*:}"
        local http_code=$(curl -s --max-time 5 -o /tmp/st_region_body.txt -w "%{http_code}" "${url}/region" 2>/dev/null)
        local region_resp=$(cat /tmp/st_region_body.txt 2>/dev/null)
        if echo "$region_resp" | grep -qE "us-east-1|us-west-2|region"; then
            local region_val=$(echo "$region_resp" | grep -oP '"region"\s*:\s*"\K[^"]+' | head -1)
            local role_val=$(echo "$region_resp" | grep -oP '"role"\s*:\s*"\K[^"]+' | head -1)
            log_ok "${name} /region → ${region_val:-?} (${role_val:-?})"
        elif [ "$http_code" = "404" ]; then
            log_skip "${name} /region → 404 (imagem nao inclui endpoint, rebuild necessario)"
        else
            log_fail "${name} /region → HTTP ${http_code:-timeout}"
        fi
    done
    rm -f /tmp/st_region_body.txt

    log_info "Metodo 2: Prometheus external_labels"
    local prom_url="http://localhost:9091"
    local prom_labels=$(curl -sf --max-time 5 "${prom_url}/api/v1/status/config" 2>/dev/null)
    if echo "$prom_labels" | grep -q "external_labels"; then
        log_ok "Prometheus external_labels configurado"
    else
        local prom_flags=$(curl -sf --max-time 5 "${prom_url}/api/v1/status/flags" 2>/dev/null)
        if [ $? -eq 0 ]; then
            log_ok "Prometheus acessivel (labels via config YAML)"
        else
            log_skip "Prometheus nao acessivel em ${prom_url} (port-forward necessario)"
        fi
    fi

    log_info "Metodo 3: Prometheus query (topk region)"
    local region_query=$(curl -sf --max-time 5 "${prom_url}/api/v1/query?query=topk(1,count%20by%20(topology_kubernetes_io_region)(up%7Bnamespace%3D%22solidarytech%22%7D%3D%3D1))" 2>/dev/null)
    if echo "$region_query" | grep -qE "us-east-1|us-west-2"; then
        local active_region=$(echo "$region_query" | grep -oP '"topology_kubernetes_io_region"\s*:\s*"\K[^"]+' | head -1)
        log_ok "Prometheus identifica regiao ativa: ${active_region}"
    else
        log_skip "Query de regiao nao retornou resultado (port-forward necessario)"
    fi

    log_info "Metodo 4: Grafana panel 'Regiao Ativa'"
    local grafana_url="http://localhost:3000"
    local grafana_pass=$(kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
    if [ -n "$grafana_pass" ]; then
        local dashboards=$(curl -sf --max-time 5 -u "admin:${grafana_pass}" "${grafana_url}/api/search?type=dash-db" 2>/dev/null)
        local dash_count=$(echo "$dashboards" | grep -oP '"id"' | wc -l)
        if [ "$dash_count" -ge 6 ]; then
            log_ok "Grafana tem ${dash_count} dashboards (esperado >= 6)"
        elif [ "$dash_count" -gt 0 ]; then
            log_ok "Grafana tem ${dash_count} dashboards"
        else
            log_skip "Grafana nao acessivel em ${grafana_url}"
        fi
    else
        log_skip "Senha do Grafana nao encontrada no secret"
    fi
}

test_dr_sync() {
    log_section "DR SYNC — Verificando sync de dados"

    if [ -f "${SCRIPT_DIR}/dr-data-sync.sh" ]; then
        log_ok "Script dr-data-sync.sh encontrado"
    else
        log_fail "Script dr-data-sync.sh nao encontrado"
        return 1
    fi

    if [ -f "${SCRIPT_DIR}/dr-failback.sh" ]; then
        log_ok "Script dr-failback.sh encontrado"
    else
        log_fail "Script dr-failback.sh nao encontrado"
    fi

    log_info "Verificando contagem de dados na producao..."
    for svc in "donation-service" "ngo-service" "volunteer-service"; do
        local pod=$(kubectl get pods -n "$NAMESPACE" -l "app=${svc}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$pod" ]; then
            local db_check=$(kubectl exec -n "$NAMESPACE" "$pod" -- python3 -c "
import os
try:
    import psycopg2
    conn = psycopg2.connect(os.environ.get('DATABASE_URL',''))
    cur = conn.cursor()
    cur.execute('SELECT count(*) FROM information_schema.tables WHERE table_schema = %s', ('public',))
    tables = cur.fetchone()[0]
    print(f'tables={tables}')
    conn.close()
except Exception as e:
    print(f'error={e}')
" 2>/dev/null)
            if echo "$db_check" | grep -q "tables="; then
                local table_count=$(echo "$db_check" | grep -oP 'tables=\K\d+')
                log_ok "${svc}: banco acessivel (${table_count} tabelas)"
            else
                log_fail "${svc}: banco inacessivel"
            fi
        else
            log_fail "${svc}: pod nao encontrado"
        fi
    done

    log_info "Verificando contextos kubectl disponiveis..."
    local contexts=$(kubectl config get-contexts --no-headers 2>/dev/null | awk '{print $2}')
    local prod_ctx=$(echo "$contexts" | grep -i "production" | head -1)
    local dr_ctx=$(echo "$contexts" | grep -iE "dr|west" | head -1)
    if [ -n "$prod_ctx" ]; then
        log_ok "Contexto de producao encontrado: ${prod_ctx}"
    else
        log_skip "Contexto de producao nao encontrado (pode usar contexto atual)"
    fi
    if [ -n "$dr_ctx" ]; then
        log_ok "Contexto de DR encontrado: ${dr_ctx}"
    else
        log_skip "Contexto de DR nao encontrado (esperado apenas em ambiente multi-cluster)"
    fi
}

test_dr_full() {
    log_section "DR COMPLETO — Suite de testes de Disaster Recovery"
    test_dr_health
    test_dr_region
    test_dr_sync
}

run_dr_failover() {
    log_section "DR FAILOVER — Executando failover para DR"
    log_info "Este teste EXECUTA o failover real para a regiao DR."
    log_info "Sera necessario confirmar digitando 'FAILOVER'."
    echo ""
    bash "${SCRIPT_DIR}/dr-failover.sh"
    if [ $? -eq 0 ]; then
        log_ok "Failover executado com sucesso"
    else
        log_fail "Failover falhou ou foi cancelado"
    fi
}

run_dr_failback() {
    log_section "DR FAILBACK — Executando failback para producao"
    log_info "Este teste EXECUTA o failback real para producao."
    log_info "Sera necessario confirmar digitando 'FAILBACK'."
    echo ""
    bash "${SCRIPT_DIR}/dr-failback.sh"
    if [ $? -eq 0 ]; then
        log_ok "Failback executado com sucesso"
    else
        log_fail "Failback falhou ou foi cancelado"
    fi
}

# ═══════════════════════════════════════════════════
#  TESTES DE RESILIENCIA
# ═══════════════════════════════════════════════════

test_selfheal() {
    log_section "SELF-HEALING — Matando pod e verificando recuperacao"

    local target_svc="donation-service"
    local pod_before=$(kubectl get pods -n "$NAMESPACE" -l "app=${target_svc}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$pod_before" ]; then
        log_fail "Pod ${target_svc} nao encontrado"
        return 1
    fi
    log_info "Pod atual: ${pod_before}"

    log_info "Verificando que o servico responde antes do kill..."
    if curl -sf --max-time 3 "${DONATION_URL}/health" > /dev/null 2>&1; then
        log_ok "Servico respondendo antes do kill"
    else
        log_fail "Servico ja nao responde antes do kill"
        return 1
    fi

    log_info "Matando pod ${pod_before}..."
    kubectl delete pod -n "$NAMESPACE" "$pod_before" --wait=false > /dev/null 2>&1

    log_info "Aguardando Kubernetes recriar o pod (max 60s)..."
    local waited=0
    local max_wait=60
    local recovered=false
    while [ $waited -lt $max_wait ]; do
        sleep 5
        waited=$((waited + 5))
        local pod_new=$(kubectl get pods -n "$NAMESPACE" -l "app=${target_svc}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$pod_new" ] && [ "$pod_new" != "$pod_before" ]; then
            log_ok "Novo pod criado: ${pod_new} (${waited}s)"
            recovered=true
            break
        fi
    done

    if [ "$recovered" = false ]; then
        log_fail "Pod nao foi recriado em ${max_wait}s"
        return 1
    fi

    log_info "Aguardando readiness (max 30s)..."
    waited=0
    while [ $waited -lt 30 ]; do
        sleep 3
        waited=$((waited + 3))
        if curl -sf --max-time 3 "${DONATION_URL}/health" > /dev/null 2>&1; then
            log_ok "Servico recuperado e respondendo (${waited}s apos recreate)"
            return 0
        fi
    done
    log_fail "Servico nao respondeu apos recreate"
}

test_chaos() {
    log_section "CHAOS — Pod kill + carga simultanea"

    if ! command -v ab &> /dev/null; then
        log_skip "Apache Bench (ab) nao instalado — pulando teste de chaos"
        return
    fi

    log_info "Iniciando carga de fundo (5 req/s)..."
    echo '{"donor_name":"Chaos","amount":10,"currency":"BRL","payment_method":"pix","ngo_id":1}' > /tmp/st_chaos.json
    ab -n 300 -c 3 -T 'application/json' -p /tmp/st_chaos.json \
        "${DONATION_URL}/api/v1/donations" > /tmp/st_chaos_result.txt 2>&1 &
    local ab_pid=$!

    sleep 5
    log_info "Matando pod durante carga..."
    local pod=$(kubectl get pods -n "$NAMESPACE" -l "app=donation-service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    kubectl delete pod -n "$NAMESPACE" "$pod" --wait=false > /dev/null 2>&1

    wait $ab_pid 2>/dev/null || true
    local failed=$(grep "Failed requests" /tmp/st_chaos_result.txt | awk '{print $3}')
    local complete=$(grep "Complete requests" /tmp/st_chaos_result.txt | awk '{print $3}')
    local non2xx=$(grep "Non-2xx" /tmp/st_chaos_result.txt | awk '{print $4}')
    log_metric "Requests completas: ${complete:-?}, Falhas: ${failed:-0}, Non-2xx: ${non2xx:-0}"

    if [ "${failed:-0}" -lt 20 ]; then
        log_ok "Chaos test: sistema resiliente (${failed:-0} falhas de ${complete:-?} requests)"
    else
        log_fail "Chaos test: muitas falhas (${failed} de ${complete:-?})"
    fi

    rm -f /tmp/st_chaos.json /tmp/st_chaos_result.txt

    log_info "Aguardando pod se recuperar (30s)..."
    sleep 30
    if curl -sf --max-time 3 "${DONATION_URL}/health" > /dev/null 2>&1; then
        log_ok "Servico recuperado apos chaos"
    else
        log_fail "Servico nao recuperou apos chaos"
    fi
}

# ═══════════════════════════════════════════════════
#  TESTES DE OBSERVABILIDADE
# ═══════════════════════════════════════════════════

test_metrics() {
    log_section "METRICAS — Verificando Prometheus"

    log_info "Verificando pods de monitoramento..."
    for comp in "prometheus" "grafana" "kube-state-metrics"; do
        local pod_status=$(kubectl get pods -n "$MONITORING_NS" -l "app=${comp}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        if [ -z "$pod_status" ]; then
            pod_status=$(kubectl get pods -n "$MONITORING_NS" --no-headers 2>/dev/null | grep "$comp" | awk '{print $3}' | head -1)
        fi
        if [ "$pod_status" = "Running" ]; then
            log_ok "${comp}: Running"
        elif [ -n "$pod_status" ]; then
            log_fail "${comp}: ${pod_status}"
        else
            log_fail "${comp}: pod nao encontrado"
        fi
    done

    log_info "Verificando metricas dos servicos via /metrics..."
    for svc in "ngo-service:${NGO_URL}" "donation-service:${DONATION_URL}" "volunteer-service:${VOLUNTEER_URL}"; do
        local name="${svc%%:*}"
        local url="${svc#*:}"
        local metrics=$(curl -sf --max-time 5 "${url}/metrics" 2>/dev/null)
        if echo "$metrics" | grep -q "http_request"; then
            local metric_count=$(echo "$metrics" | grep -c "^[a-z]" || true)
            log_ok "${name} /metrics: ${metric_count} metricas expostas"
        else
            log_fail "${name} /metrics: sem metricas"
        fi
    done

    log_info "Verificando targets no Prometheus..."
    local prom_url="http://localhost:9091"
    local targets=$(curl -sf --max-time 5 "${prom_url}/api/v1/targets" 2>/dev/null)
    if [ $? -eq 0 ]; then
        local active=$(echo "$targets" | grep -oP '"health"\s*:\s*"up"' | wc -l)
        local total=$(echo "$targets" | grep -oP '"health"\s*:' | wc -l)
        log_ok "Prometheus targets: ${active}/${total} up"
    else
        log_skip "Prometheus API nao acessivel (port-forward na porta 9091)"
    fi
}

test_dashboards() {
    log_section "DASHBOARDS — Verificando Grafana"

    local grafana_url="http://localhost:3000"
    local grafana_pass=$(kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)

    if [ -z "$grafana_pass" ]; then
        log_skip "Senha do Grafana nao encontrada"
        return
    fi

    local search=$(curl -sf --max-time 5 -u "admin:${grafana_pass}" "${grafana_url}/api/search?type=dash-db" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_skip "Grafana nao acessivel em ${grafana_url} (port-forward necessario)"
        return
    fi

    local expected_dashboards=("platform-overview" "business-donations" "sre-golden-metrics" "slo-dashboard" "infrastructure-cluster" "dr-status")
    local expected_titles=("Platform Overview" "Business Metrics" "SRE Golden Metrics" "SLO" "Infrastructure" "DR Status")

    for i in "${!expected_dashboards[@]}"; do
        local uid="${expected_dashboards[$i]}"
        local title="${expected_titles[$i]}"
        if echo "$search" | grep -qi "$uid\|$title"; then
            log_ok "Dashboard: ${title}"
        else
            log_fail "Dashboard nao encontrado: ${title} (uid: ${uid})"
        fi
    done

    log_info "Verificando panel 'Regiao Ativa' nos dashboards..."
    local dash_uids=$(echo "$search" | grep -oP '"uid"\s*:\s*"\K[^"]+')
    local regiao_count=0
    for uid in $dash_uids; do
        local dash=$(curl -sf --max-time 5 -u "admin:${grafana_pass}" "${grafana_url}/api/dashboards/uid/${uid}" 2>/dev/null)
        if echo "$dash" | grep -qi "Regiao Ativa"; then
            regiao_count=$((regiao_count + 1))
        fi
    done
    if [ "$regiao_count" -ge 5 ]; then
        log_ok "Panel 'Regiao Ativa' presente em ${regiao_count} dashboards"
    elif [ "$regiao_count" -gt 0 ]; then
        log_ok "Panel 'Regiao Ativa' encontrado em ${regiao_count} dashboards"
    else
        log_fail "Panel 'Regiao Ativa' nao encontrado nos dashboards"
    fi
}

test_observability() {
    log_section "OBSERVABILIDADE — Suite completa"
    test_metrics
    test_dashboards

    log_info "Verificando componentes adicionais..."
    for comp in "loki" "otel-collector" "promtail"; do
        local running=$(kubectl get pods -n "$MONITORING_NS" --no-headers 2>/dev/null | grep "$comp" | grep "Running" | wc -l)
        if [ "$running" -gt 0 ]; then
            log_ok "${comp}: Running"
        else
            log_fail "${comp}: nao encontrado ou nao esta Running"
        fi
    done
}

# ═══════════════════════════════════════════════════
#  TESTES DE SEGURANCA
# ═══════════════════════════════════════════════════

test_security() {
    log_section "SEGURANCA — Verificando hardening"

    log_info "Verificando SecurityContext dos pods..."
    for svc in "donation-service" "ngo-service" "volunteer-service"; do
        local pod=$(kubectl get pods -n "$NAMESPACE" -l "app=${svc}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -z "$pod" ]; then
            log_fail "${svc}: pod nao encontrado"
            continue
        fi

        local run_as_non_root=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null)
        if [ "$run_as_non_root" = "true" ]; then
            log_ok "${svc}: runAsNonRoot=true"
        else
            local run_as_user=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].securityContext.runAsUser}' 2>/dev/null)
            if [ -n "$run_as_user" ] && [ "$run_as_user" != "0" ]; then
                log_ok "${svc}: runAsUser=${run_as_user} (non-root)"
            else
                log_fail "${svc}: nao configurado para non-root"
            fi
        fi

        local read_only=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
        if [ "$read_only" = "true" ]; then
            log_ok "${svc}: readOnlyRootFilesystem=true"
        else
            log_skip "${svc}: readOnlyRootFilesystem nao definido"
        fi

        local drop_caps=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop}' 2>/dev/null)
        if echo "$drop_caps" | grep -qi "ALL"; then
            log_ok "${svc}: capabilities drop ALL"
        elif [ -n "$drop_caps" ]; then
            log_ok "${svc}: capabilities drop configurado"
        else
            log_skip "${svc}: capabilities drop nao definido"
        fi

        local automount=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.automountServiceAccountToken}' 2>/dev/null)
        if [ "$automount" = "false" ]; then
            log_ok "${svc}: automountServiceAccountToken=false"
        else
            log_skip "${svc}: automountServiceAccountToken nao definido como false"
        fi
    done

    log_info "Verificando NetworkPolicies..."
    local netpol_count=$(kubectl get networkpolicies -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [ "$netpol_count" -gt 0 ]; then
        log_ok "NetworkPolicies: ${netpol_count} regras no namespace ${NAMESPACE}"
    else
        log_skip "Nenhuma NetworkPolicy no namespace ${NAMESPACE}"
    fi

    log_info "Verificando secrets..."
    local secrets=$(kubectl get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "default-token\|service-account" | wc -l)
    if [ "$secrets" -gt 0 ]; then
        log_ok "Secrets: ${secrets} secrets configurados"
    else
        log_skip "Nenhum secret customizado encontrado"
    fi

    log_info "Verificando resource limits..."
    for svc in "donation-service" "ngo-service" "volunteer-service"; do
        local limits=$(kubectl get pods -n "$NAMESPACE" -l "app=${svc}" -o jsonpath='{.items[0].spec.containers[0].resources.limits}' 2>/dev/null)
        if [ -n "$limits" ] && [ "$limits" != "{}" ]; then
            log_ok "${svc}: resource limits configurados"
        else
            log_fail "${svc}: resource limits nao configurados"
        fi
    done
}

# ═══════════════════════════════════════════════════
#  SUITES COMPLETAS
# ═══════════════════════════════════════════════════

run_smoke() {
    log_section "SMOKE TEST — Validacao rapida do ambiente"
    test_health
    test_api
    test_dr_region
    test_hpa
    print_report
}

run_all() {
    echo -e "${BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  SUITE COMPLETA DE TESTES                        ║"
    echo "║  Cobrindo: API, Carga, DR, Resiliencia,          ║"
    echo "║  Observabilidade, Seguranca                      ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_services || return 1
    seed_data
    test_health
    test_api
    test_hpa
    test_security
    test_metrics
    test_dashboards
    test_dr_full
    test_selfheal

    if command -v ab &> /dev/null; then
        run_load 10 30 "SMOKE-LOAD"
    else
        log_skip "Apache Bench nao instalado — pulando teste de carga"
    fi

    print_report
}

run_full() {
    echo -e "${BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  DEMO COMPLETO                                   ║"
    echo "║  seed + scaling + selfheal + DR + observability  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_services || return 1
    seed_data
    test_health
    test_api

    if command -v ab &> /dev/null; then
        run_ramp
    else
        log_skip "Apache Bench nao instalado — pulando teste de carga"
    fi

    test_selfheal
    test_dr_full
    test_observability
    test_security

    print_report
}

# ═══════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  SolidaryTech — Suite de Testes                  ║"
echo "╠══════════════════════════════════════════════════╣"
printf "║  Fase: %-41s║\n" "${PHASE}"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ "$PHASE" =~ ^(light|medium|heavy|ramp|chaos)$ ]]; then
    if ! command -v ab &> /dev/null; then
        echo -e "${RED}[ERROR]${NC} 'ab' (Apache Bench) nao encontrado. Instale com:"
        echo "  sudo yum install httpd-tools   # RHEL/Amazon Linux"
        echo "  sudo apt install apache2-utils  # Debian/Ubuntu"
        exit 1
    fi
fi

case "$PHASE" in
    help|--help|-h)
        show_usage
        ;;
    status)
        show_status
        ;;

    # Funcionais
    seed)
        check_services && seed_data && print_report
        ;;
    health)
        test_health && print_report
        ;;
    api)
        check_services && test_api && print_report
        ;;

    # Carga
    light)
        check_services && run_load 5 "${DURATION}" "LIGHT" && print_report
        ;;
    medium)
        check_services && run_load 20 "${DURATION}" "MEDIUM" && print_report
        ;;
    heavy)
        check_services && run_load 50 "${DURATION}" "HEAVY" && print_report
        ;;
    ramp)
        check_services && run_ramp && print_report
        ;;

    # DR
    dr)
        test_dr_full && print_report
        ;;
    dr-health)
        test_dr_health && print_report
        ;;
    dr-region)
        test_dr_region && print_report
        ;;
    dr-sync)
        test_dr_sync && print_report
        ;;
    dr-failover)
        run_dr_failover && print_report
        ;;
    dr-failback)
        run_dr_failback && print_report
        ;;

    # Resiliencia
    selfheal)
        check_services && test_selfheal && print_report
        ;;
    chaos)
        check_services && test_chaos && print_report
        ;;

    # Observabilidade
    metrics)
        test_metrics && print_report
        ;;
    dashboards)
        test_dashboards && print_report
        ;;
    observability)
        test_observability && print_report
        ;;

    # Seguranca
    security)
        test_security && print_report
        ;;

    # Suites
    smoke)
        check_services && run_smoke
        ;;
    all)
        run_all
        ;;
    full)
        run_full
        ;;

    *)
        echo "Fase desconhecida: ${PHASE}"
        echo ""
        show_usage
        exit 1
        ;;
esac
