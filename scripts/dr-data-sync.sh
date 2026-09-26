#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/logging.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT="solidarytech"
NAMESPACE="solidarytech"
PROD_CONTEXT="arn:aws:eks:us-east-1:617261142320:cluster/${PROJECT}-eks-production"
DR_CONTEXT="dr-cluster"

DIRECTION="${1:-prod-to-dr}"  # prod-to-dr | dr-to-prod | bidirectional
DRY_RUN="${2:-false}"

log_step() { echo -e "${BLUE}[SYNC]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_data() { echo -e "${CYAN}[DATA]${NC} $1"; }

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  DATA SYNC - Sincronizacao entre Regioes        ║"
echo "║                                                  ║"
echo "║  Estrategia: INSERT ON CONFLICT (idempotente)    ║"
echo "║  Dedup Key:  transaction_id (UUID) / cnpj / email║"
echo "║  Direcao:    ${DIRECTION}                        "
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

get_db_url() {
    local context="$1"
    kubectl --context "$context" get secret solidarytech-secrets \
        -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | base64 -d
}

count_records() {
    local context="$1"
    local service="$2"
    local table="$3"
    kubectl --context "$context" exec deploy/"$service" -n "$NAMESPACE" -- \
        python3 -c "
import os, psycopg2
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute('SELECT count(*) FROM $table')
print(cur.fetchone()[0])
conn.close()
" 2>/dev/null
}

sync_donations() {
    local src_ctx="$1"
    local dst_ctx="$2"
    local src_label="$3"
    local dst_label="$4"

    log_step "Sincronizando donations: ${src_label} -> ${dst_label}"

    local src_count=$(count_records "$src_ctx" "donation-service" "donations")
    local dst_count=$(count_records "$dst_ctx" "donation-service" "donations")
    log_data "  ${src_label}: ${src_count} registros | ${dst_label}: ${dst_count} registros"

    if [ "$src_count" -eq 0 ]; then
        log_warn "  Origem sem dados, pulando"
        return
    fi

    # Get transaction_ids already in destination to export only delta
    log_step "  Coletando transaction_ids do destino (${dst_label})..."
    local dst_txids
    dst_txids=$(kubectl --context "$dst_ctx" exec deploy/donation-service -n "$NAMESPACE" -- \
        python3 -c "
import os, psycopg2, json
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute('SELECT transaction_id FROM donations WHERE transaction_id IS NOT NULL')
print(json.dumps([r[0] for r in cur.fetchall()]))
conn.close()
" 2>/dev/null)

    log_step "  Exportando delta de ${src_label} (apenas registros novos)..."
    local export_data
    export_data=$(echo "$dst_txids" | kubectl --context "$src_ctx" exec -i deploy/donation-service -n "$NAMESPACE" -- \
        python3 -c "
import os, psycopg2, json, sys
existing_ids = set(json.load(sys.stdin))
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute('''
    SELECT donor_name, donor_email, ngo_id, amount, original_amount,
           original_currency, currency, payment_method, status,
           transaction_id, created_at, processed_at
    FROM donations
    WHERE transaction_id IS NOT NULL
    ORDER BY id
''')
rows = []
for r in cur.fetchall():
    if r[9] not in existing_ids:
        rows.append({
            'donor_name': r[0], 'donor_email': r[1], 'ngo_id': r[2],
            'amount': float(r[3]) if r[3] else 0,
            'original_amount': float(r[4]) if r[4] else None,
            'original_currency': r[5], 'currency': r[6],
            'payment_method': r[7], 'status': r[8],
            'transaction_id': r[9],
            'created_at': str(r[10]) if r[10] else None,
            'processed_at': str(r[11]) if r[11] else None
        })
print(json.dumps(rows))
conn.close()
" 2>/dev/null)

    local export_count=$(echo "$export_data" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    log_data "  Delta: ${export_count} registros novos para sincronizar"

    if [ "$DRY_RUN" = "true" ]; then
        log_warn "  DRY RUN - nao importando"
        return
    fi

    log_step "  Importando para ${dst_label} (ON CONFLICT DO NOTHING)..."
    local imported
    imported=$(echo "$export_data" | kubectl --context "$dst_ctx" exec -i deploy/donation-service -n "$NAMESPACE" -- \
        python3 -c "
import os, psycopg2, json, sys
data = json.load(sys.stdin)
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
inserted = 0
skipped = 0
for r in data:
    try:
        cur.execute('''
            INSERT INTO donations (donor_name, donor_email, ngo_id, amount,
                original_amount, original_currency, currency, payment_method,
                status, transaction_id, created_at, processed_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (transaction_id) DO NOTHING
        ''', (
            r['donor_name'], r['donor_email'], r['ngo_id'], r['amount'],
            r['original_amount'], r['original_currency'], r['currency'],
            r['payment_method'], r['status'], r['transaction_id'],
            r['created_at'], r['processed_at']
        ))
        if cur.rowcount > 0:
            inserted += 1
        else:
            skipped += 1
    except Exception as e:
        skipped += 1
conn.commit()
print(f'{inserted}|{skipped}')
conn.close()
" 2>/dev/null)

    local new_count=$(echo "$imported" | cut -d'|' -f1)
    local skip_count=$(echo "$imported" | cut -d'|' -f2)
    log_ok "  Inseridos: ${new_count} novos | Duplicados ignorados: ${skip_count}"

    local final_dst=$(count_records "$dst_ctx" "donation-service" "donations")
    log_data "  ${dst_label} agora tem: ${final_dst} registros"
}

sync_ngos() {
    local src_ctx="$1"
    local dst_ctx="$2"
    local src_label="$3"
    local dst_label="$4"

    log_step "Sincronizando NGOs: ${src_label} -> ${dst_label}"

    local src_count=$(count_records "$src_ctx" "ngo-service" "ngos")
    local dst_count=$(count_records "$dst_ctx" "ngo-service" "ngos")
    log_data "  ${src_label}: ${src_count} registros | ${dst_label}: ${dst_count} registros"

    if [ "$src_count" -eq 0 ]; then
        log_warn "  Origem sem dados, pulando"
        return
    fi

    local export_data
    export_data=$(kubectl --context "$src_ctx" exec deploy/ngo-service -n "$NAMESPACE" -- \
        python3 -c "
import os, psycopg2, json
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute('''
    SELECT name, cnpj, description, category, contact_email, phone,
           address, city, state, created_at, updated_at, active
    FROM ngos WHERE cnpj IS NOT NULL
    ORDER BY id
''')
rows = []
for r in cur.fetchall():
    rows.append({
        'name': r[0], 'cnpj': r[1], 'description': r[2],
        'category': r[3], 'contact_email': r[4], 'phone': r[5],
        'address': r[6], 'city': r[7], 'state': r[8],
        'created_at': str(r[9]) if r[9] else None,
        'updated_at': str(r[10]) if r[10] else None,
        'active': r[11]
    })
print(json.dumps(rows))
conn.close()
" 2>/dev/null)

    if [ "$DRY_RUN" = "true" ]; then
        local count=$(echo "$export_data" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
        log_warn "  DRY RUN - ${count} registros nao importados"
        return
    fi

    local imported
    imported=$(echo "$export_data" | kubectl --context "$dst_ctx" exec -i deploy/ngo-service -n "$NAMESPACE" -- \
        python3 -c "
import os, psycopg2, json, sys
data = json.load(sys.stdin)
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
# Ensure unique constraint on cnpj
cur.execute('''
    DO \$\$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ngos_cnpj_unique') THEN
            ALTER TABLE ngos ADD CONSTRAINT ngos_cnpj_unique UNIQUE (cnpj);
        END IF;
    END \$\$;
''')
conn.commit()
inserted = 0
skipped = 0
for r in data:
    try:
        cur.execute('''
            INSERT INTO ngos (name, cnpj, description, category, contact_email,
                phone, address, city, state, created_at, updated_at, active)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (cnpj) DO UPDATE SET
                name = EXCLUDED.name,
                description = EXCLUDED.description,
                updated_at = EXCLUDED.updated_at
        ''', (
            r['name'], r['cnpj'], r['description'], r['category'],
            r['contact_email'], r['phone'], r['address'], r['city'],
            r['state'], r['created_at'], r['updated_at'],
            r['active'] if r['active'] is not None else True
        ))
        if cur.statusmessage.startswith('INSERT'):
            inserted += 1
        else:
            skipped += 1
    except Exception as e:
        skipped += 1
conn.commit()
print(f'{inserted}|{skipped}')
conn.close()
" 2>/dev/null)

    local new_count=$(echo "$imported" | cut -d'|' -f1)
    local skip_count=$(echo "$imported" | cut -d'|' -f2)
    log_ok "  Novos/Atualizados: ${new_count} | Conflitos: ${skip_count}"
}

sync_volunteers() {
    local src_ctx="$1"
    local dst_ctx="$2"
    local src_label="$3"
    local dst_label="$4"

    log_step "Sincronizando Volunteers: ${src_label} -> ${dst_label}"

    local src_count=$(count_records "$src_ctx" "volunteer-service" "volunteers")
    local dst_count=$(count_records "$dst_ctx" "volunteer-service" "volunteers")
    log_data "  ${src_label}: ${src_count} registros | ${dst_label}: ${dst_count} registros"

    if [ "$src_count" -eq 0 ]; then
        log_warn "  Origem sem dados, pulando"
        return
    fi

    local export_data
    export_data=$(kubectl --context "$src_ctx" exec deploy/volunteer-service -n "$NAMESPACE" -- \
        python3 -c "
import os, psycopg2, json
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute('''
    SELECT name, email, phone, skills, city, state, available, created_at
    FROM volunteers WHERE email IS NOT NULL
    ORDER BY id
''')
rows = []
for r in cur.fetchall():
    rows.append({
        'name': r[0], 'email': r[1], 'phone': r[2], 'skills': r[3],
        'city': r[4], 'state': r[5],
        'available': r[6] if r[6] is not None else True,
        'created_at': str(r[7]) if r[7] else None
    })
print(json.dumps(rows))
conn.close()
" 2>/dev/null)

    if [ "$DRY_RUN" = "true" ]; then
        local count=$(echo "$export_data" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
        log_warn "  DRY RUN - ${count} registros nao importados"
        return
    fi

    local imported
    imported=$(echo "$export_data" | kubectl --context "$dst_ctx" exec -i deploy/volunteer-service -n "$NAMESPACE" -- \
        python3 -c "
import os, psycopg2, json, sys
data = json.load(sys.stdin)
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute('SELECT name, email FROM volunteers')
existing = set((r[0], r[1]) for r in cur.fetchall())
inserted = 0
skipped = 0
for r in data:
    key = (r['name'], r['email'])
    if key in existing:
        skipped += 1
        continue
    try:
        cur.execute('''
            INSERT INTO volunteers (name, email, phone, skills, city, state, available, created_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        ''', (
            r['name'], r['email'], r['phone'], r['skills'],
            r['city'], r['state'], r['available'], r['created_at']
        ))
        inserted += 1
        existing.add(key)
    except Exception as e:
        skipped += 1
        conn.rollback()
conn.commit()
print(f'{inserted}|{skipped}')
conn.close()
" 2>/dev/null)

    local new_count=$(echo "$imported" | cut -d'|' -f1)
    local skip_count=$(echo "$imported" | cut -d'|' -f2)
    log_ok "  Novos: ${new_count} | Duplicados ignorados: ${skip_count}"
}

START_TIME=$(date +%s)

case "$DIRECTION" in
    prod-to-dr)
        echo -e "${BLUE}Direcao: Producao (us-east-1) --> DR (us-west-2)${NC}"
        echo ""
        sync_donations "$PROD_CONTEXT" "$DR_CONTEXT" "Producao" "DR"
        echo ""
        sync_ngos "$PROD_CONTEXT" "$DR_CONTEXT" "Producao" "DR"
        echo ""
        sync_volunteers "$PROD_CONTEXT" "$DR_CONTEXT" "Producao" "DR"
        ;;
    dr-to-prod)
        echo -e "${BLUE}Direcao: DR (us-west-2) --> Producao (us-east-1)${NC}"
        echo ""
        sync_donations "$DR_CONTEXT" "$PROD_CONTEXT" "DR" "Producao"
        echo ""
        sync_ngos "$DR_CONTEXT" "$PROD_CONTEXT" "DR" "Producao"
        echo ""
        sync_volunteers "$DR_CONTEXT" "$PROD_CONTEXT" "DR" "Producao"
        ;;
    bidirectional)
        echo -e "${BLUE}Direcao: Bidirecional (merge completo)${NC}"
        echo ""
        echo "=== Fase 1: Producao --> DR ==="
        sync_donations "$PROD_CONTEXT" "$DR_CONTEXT" "Producao" "DR"
        echo ""
        sync_ngos "$PROD_CONTEXT" "$DR_CONTEXT" "Producao" "DR"
        echo ""
        sync_volunteers "$PROD_CONTEXT" "$DR_CONTEXT" "Producao" "DR"
        echo ""
        echo "=== Fase 2: DR --> Producao ==="
        sync_donations "$DR_CONTEXT" "$PROD_CONTEXT" "DR" "Producao"
        echo ""
        sync_ngos "$DR_CONTEXT" "$PROD_CONTEXT" "DR" "Producao"
        echo ""
        sync_volunteers "$DR_CONTEXT" "$PROD_CONTEXT" "DR" "Producao"
        ;;
    *)
        echo "Uso: $0 [prod-to-dr|dr-to-prod|bidirectional] [true|false (dry-run)]"
        echo ""
        echo "Exemplos:"
        echo "  $0 prod-to-dr         # Sync producao para DR"
        echo "  $0 dr-to-prod         # Sync DR para producao (failback)"
        echo "  $0 bidirectional      # Merge completo bidirecional"
        echo "  $0 prod-to-dr true    # Dry run (sem alteracoes)"
        exit 1
        ;;
esac

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║  SINCRONIZACAO CONCLUIDA                        ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Direcao: ${DIRECTION}                          "
echo "║  Duracao: ${DURATION}s                          "
echo "║  Dry Run: ${DRY_RUN}                            "
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

echo "Contagem final:"
echo "  Producao: donations=$(count_records "$PROD_CONTEXT" "donation-service" "donations")"
echo "  DR:       donations=$(count_records "$DR_CONTEXT" "donation-service" "donations")"
