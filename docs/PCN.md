# Plano de Continuidade de Negocios (PCN)

## SolidaryTech - Plataforma de Conexao entre ONGs, Doadores e Voluntarios

**Versao:** 2.0
**Data:** Setembro/2026
**Classificacao:** Documento Executivo
**Responsavel:** Equipe DevOps / SRE

---

## 1. Objetivo e Escopo

Este Plano de Continuidade de Negocios (PCN) define as estrategias, procedimentos e responsabilidades para garantir a continuidade operacional da plataforma SolidaryTech em cenarios de desastre ou interrupcao grave.

**Escopo:** Todos os microsservicos da plataforma (ngo-service, donation-service, volunteer-service), bancos de dados, filas de mensageria e infraestrutura de suporte em nuvem AWS.

**Premissa fundamental:** O donation-service (caminho critico) nao pode parar. As doacoes representam a receita direta das ONGs parceiras e qualquer interrupcao prolongada compromete vidas.

---

## 2. Analise de Riscos

| # | Risco | Probabilidade | Impacto | Severidade | Mitigacao |
|---|-------|---------------|---------|------------|-----------|
| R1 | Queda de AZ (Availability Zone) | Media | Alto | **Critico** | Multi-AZ no EKS e RDS |
| R2 | Queda de Regiao AWS | Baixa | Critico | **Critico** | Warm Standby em us-west-2 |
| R3 | Corrupcao de banco de dados | Baixa | Critico | **Critico** | Sync bidirecional + backups (Read Replica em producao real) |
| R4 | Ataque DDoS | Media | Alto | **Alto** | AWS Shield + WAF + Rate Limiting |
| R5 | Falha de deploy (bug em producao) | Alta | Medio | **Alto** | Rollback via GitOps (ArgoCD) |
| R6 | Comprometimento de credenciais | Baixa | Critico | **Critico** | Rotacao automatica via Secrets Manager |
| R7 | Exaustao de recursos (CPU/Mem) | Media | Medio | **Medio** | HPA + Karpenter + Alertas |
| R8 | Falha no pipeline CI/CD | Media | Baixo | **Baixo** | Workflows redundantes + alertas |

---

## 3. RTO e RPO

### Recovery Time Objective (RTO)

O RTO define o tempo maximo aceitavel para restauracao de cada servico apos um desastre.

| Servico | Criticidade | RTO Target | RTO Medido | Justificativa |
|---------|-------------|------------|------------|---------------|
| **donation-service** | P0 (Critico) | 3-5 min | **58 segundos** | Apps ja rodam no DR; sync + restart pods |
| **ngo-service** | P1 (Alto) | 3-5 min | **58 segundos** | Mesmo mecanismo de failover automatizado |
| **volunteer-service** | P2 (Medio) | 3-5 min | **58 segundos** | Mesmo mecanismo de failover automatizado |
| **Banco de Dados (RDS)** | P0 (Critico) | 2-3 min | **~30 segundos** | RDS DR ja disponivel (standalone) |
| **Fila SQS** | P0 (Critico) | 0 min | **0 segundos** | SQS DR pre-criada e independente |
| **Monitoramento** | P1 (Alto) | 5 min | **~2 minutos** | Stack de monitoramento ja roda no DR |

### Recovery Point Objective (RPO)

O RPO define a quantidade maxima aceitavel de perda de dados.

| Tipo de dado | RPO | Mecanismo |
|-------------|-----|-----------|
| **Dados commitados (no DB)** | **0 (zero)** | Sync bidirecional via `dr-data-sync.sh` antes do failover |
| **Transacoes in-flight (nao commitadas)** | **~58 segundos** | Conexao cortada durante failover, sem WAL remoto |
| **Transacoes tentadas durante RTO** | **~58 segundos** | Nenhum servico disponivel, sem fila intermediaria |
| **Dados criados no DR** | **0 (zero)** | Sync bidirecional traz de volta no failback |
| **Configuracoes K8s** | **0 (zero)** | GitOps - todo estado esta no Git |
| **Logs e Metricas** | **24 horas** | Retencao configurada, nao critico para negocio |

### Analise Honesta de Perda no Failover

O failover **nao significa zero perda**. Durante a janela de RTO (3-5 min; teste em lab: 58s):

| Metrica | Valor |
|---------|-------|
| Throughput medio | ~0.07 req/s |
| Transacoes perdidas (estimativa) | **~4 transacoes** |
| Ticket medio | ~R$ 1.780 |
| Impacto financeiro estimado | **~R$ 7.100 por evento de failover** |

**Em producao real:** RDS Read Replica cross-region (RPO ~1s automatico) + SQS como buffer (retry de transacoes falhas) reduziria a perda significativamente.

---

## 4. Estrategia de Disaster Recovery

### Por que Warm Standby ao inves de Cold DR?

A decisao de manter um ambiente DR **sempre ativo** com workload minimo ao inves de um Cold DR (que provisiona tudo no momento do desastre) foi baseada em 3 fatores:

#### 1. RTO inaceitavel com Cold DR

| Abordagem | RTO | Risco |
|-----------|-----|-------|
| **Cold DR** (provisionar tudo) | 30-45 min | Terraform pode falhar; AMI pode nao estar disponivel; RDS leva 10+ min para criar |
| **Warm Standby** (escalar) | **3-5 min** | Infra ja existe; sync + restart pods (teste: 58s) |

Com Cold DR, 30 minutos de indisponibilidade no donation-service significa doacoes perdidas e ONGs sem recursos. Para uma plataforma que recebe doacoes 24/7 em 5 moedas diferentes, isso e inaceitavel.

#### 2. Custo incremental justificavel

| Componente | Cold DR (custo/h) | Warm Standby (custo/h) | Diferenca |
|------------|-------------------:|----------------------:|----------:|
| EKS Control Plane | $0.00 (nao existe) | $0.100 | +$0.100 |
| EC2 Node (1x t3.medium) | $0.00 | $0.042 | +$0.042 |
| NAT Gateway | $0.00 | $0.045 | +$0.045 |
| RDS Read Replica | $0.00 | $0.018 | +$0.018 |
| **Total adicional** | | | **+$0.205/h** |
| **Custo mensal adicional** | | | **~$148/mes** |

Para contexto: 30 minutos de downtime no donation-service em horario de pico pode significar milhares de dolares em doacoes perdidas. O custo de $148/mes e um seguro barato contra esse risco.

#### 3. Confiabilidade do failover

Com Cold DR, o failover depende de:
- Terraform plan + apply funcionando (ja falhou no Academy Lab)
- AMIs disponiveis na regiao DR
- RDS criar do zero (10-15 min)
- Imagens Docker disponíveis no ECR da regiao DR
- Configurar kubectl, secrets, ArgoCD do zero

Com Warm Standby, o failover depende apenas de:
- `aws rds promote-read-replica` (2-3 min)
- `kubectl rollout restart` (30s)

**Menos etapas = menos pontos de falha.**

### Arquitetura: Active-Passive (Warm Standby)

```
                    ┌──────────────────────────────────────────┐
                    │              ROUTE 53 (DNS)              │
                    │         solidarytech.com.br              │
                    └──────────┬──────────────────┬────────────┘
                               │   (ativo)        │  (standby)
                    ┌──────────▼──────────┐  ┌────▼──────────────────┐
                    │   us-east-1         │  │   us-west-2            │
                    │   (PRODUCAO)        │  │   (DR - WARM STANDBY)  │
                    │                     │  │                        │
                    │  ┌───────────────┐  │  │  ┌────────────────┐   │
                    │  │   EKS Cluster │  │  │  │   EKS Cluster  │   │
                    │  │   (1 node)    │  │  │  │   (1 node)     │   │
                    │  │   3 apps      │  │  │  │   3 apps       │   │
                    │  │   1 replica   │  │  │  │   1 replica    │   │
                    │  └───────────────┘  │  │  └────────────────┘   │
                    │                     │  │                        │
                    │  ┌───────────────┐  │  │  ┌────────────────┐   │
                    │  │  RDS Primary  │──┼──┼─▶│ RDS Read       │   │
                    │  │  (read/write) │  │  │  │ Replica        │   │
                    │  └───────────────┘  │  │  │ (sync continuo)│   │
                    │                     │  │  └────────────────┘   │
                    │  ┌───────────────┐  │  │  ┌────────────────┐   │
                    │  │   SQS Queue   │  │  │  │  SQS Queue DR  │   │
                    │  └───────────────┘  │  │  └────────────────┘   │
                    └─────────────────────┘  └────────────────────────┘
                                │                        │
                                │     FAILOVER (3-5 min)  │
                                │  1. Promover replica   │
                                │  2. Restart pods       │
                                │  3. Escalar nodes      │
                                └────────────────────────┘
```

### Componentes da Estrategia DR

| Componente | Producao (us-east-1) | DR (us-west-2) | Mecanismo |
|------------|---------------------|----------------|-----------|
| **EKS** | 2 nodes t3.medium (34 pods max), apps com HPA (donation max 4, ngo/volunteer max 3) | 1 node, apps com 1 replica (minimo) | Terraform modular |
| **RDS** | Primary (read/write) | Standalone + sync bidirecional (`dr-data-sync.sh`) | Em producao: `replicate_source_db` |
| **SQS** | Fila ativa | Fila pre-criada (ativada no failover) | Terraform modular |
| **Monitoring** | Stack completa | Stack minima | Mesmo manifesto K8s |
| **AIOps** | CronJob 5min (8 verificacoes proativas) | CronJob 5min (mesmas verificacoes) | `aiops-remediation.sh` + `cronjob-aiops.yaml` |
| **ArgoCD** | GitOps ativo | GitOps ativo (mesmas apps) | App of Apps |

**Camadas de auto-recuperacao ANTES do failover DR:**

| Camada | Mecanismo | Tempo de Resposta | Exemplos |
|--------|-----------|-------------------|----------|
| 1. Kubernetes | Liveness/Readiness probes, PDB | < 30s | Pod crashou → restart automatico |
| 2. HPA | Auto-scaling horizontal | < 60s | CPU alta → mais replicas (donation max 4, ngo/volunteer max 3) |
| 3. AIOps CronJob | 8 verificacoes proativas | < 5 min | CrashLoopBackOff → rollout restart; monitoring down → restart + ConfigMaps |
| 4. SelfHealing Webhook | AlertManager → webhook handler | < 2 min | Alerta Prometheus → acao automatica |
| 5. DR Failover | Health checker + failover | 3-5 min | 3 falhas consecutivas → troca de regiao |

O DR so e acionado quando **todas** as camadas automaticas anteriores falharem (ex: AZ inteira fora, node morto sem substituicao).

---

## 5. Procedimento de Failover

### Passo a passo (`scripts/dr-failover.sh`)

| Etapa | Acao | Tempo | Automatizado? |
|-------|------|-------|---------------|
| 1 | **Sync prod → DR** (preservar dados antes da migracao) | ~10s | **Sim** (`dr-data-sync.sh`) |
| 2 | Health checker detecta falha (ou acionamento manual) | 0-3 min | **Sim/Manual** |
| 3 | Atualizar kubeconfig para cluster DR | 5s | **Sim** |
| 4 | Reiniciar pods para reconectar ao banco DR | 30s | **Sim** |
| 5 | Escalar nodes (1 → 2) para capacidade de producao | background | **Sim** |
| 6 | Validar integridade de dados (contagem + total) | 10s | **Sim** |
| **RTO target (ate servicos ativos)** | | **3-5 min** | **100% automatizado** |

> **Resultado de teste (DR drill em lab):** RTO medido de **58 segundos**, bem abaixo do target de 3-5 minutos.

### Failover Automatico (dr-health-checker.sh)

O health checker monitora continuamente a producao via AWS APIs e dispara failover automaticamente apos 3 falhas consecutivas, **sem intervencao humana**.

```bash
# Monitoramento continuo com failover automatico
./scripts/dr-health-checker.sh --daemon --auto-failover

# Checks executados a cada 60s:
#   1. EKS cluster status = ACTIVE?
#   2. Nodes Ready > 0?
#   3. RDS primary = available?
# 3 falhas consecutivas -> failover automatico

# Teste sem impacto (dry-run)
./scripts/dr-health-checker.sh --daemon --dry-run

# Check unico (para CronJob ou validacao manual)
./scripts/dr-health-checker.sh --once
```

### Failover Manual (dr-failover.sh)

Para drills planejados ou quando o operador quer controle total:

```bash
./scripts/dr-failover.sh
# Digite 'FAILOVER' para confirmar
# Saida: tempo total e comparacao com RTO de 5 min
```

### Comparativo Cold DR vs Warm Standby

| Metrica | Cold DR (v1.0) | Warm Standby (v2.0) | Melhoria |
|---------|----------------|---------------------|----------|
| RTO | 30 min | **3-5 min** (teste: 58s) | **6x mais rapido** |
| RPO (dados commitados) | 5 min (backup) | **0** (sync bidirecional) | **Total** |
| Pontos de falha no failover | 8+ etapas | 6 etapas | **25% menos** |
| Custo mensal adicional | $0 | ~$148 | Justificado pelo RTO |
| Confiabilidade do failover | Baixa (depende de Terraform) | Alta (apenas AWS API + sync) | **Muito maior** |
| Perda por evento | Todas as transacoes | ~4 transacoes (~R$ 7.100) | **Minima** |

---

## 5.1. Procedimento de Failback (`scripts/dr-failback.sh`)

O failback e projetado para ser **transparente para o cliente** — zero downtime durante a transicao DR → Producao.

| Etapa | Acao | Tempo | Impacto no cliente |
|-------|------|-------|--------------------|
| 1 | Verificar infra producao (nodes Ready, RDS available) | 10s | Nenhum |
| 2 | Readiness gate — validar pods Running+Ready na producao | 10s | Nenhum |
| 3 | **Sync DR → Prod** (enquanto DR ainda serve trafego) | ~15s | Nenhum |
| 4 | Validar integridade (contagem + total iguais) | 5s | Nenhum |
| 5 | Freeze DR + delta sync final (scale donation-service a 0) | 10s | Nenhum (producao ja ativa) |
| 6 | Redirecionar trafego para producao (health check) | 5s | Nenhum |
| 7 | Connection draining (escalar todos servicos DR a 0) | 30s | Nenhum |
| 8 | Reduzir DR para warm standby (1 node, 1 replica) | 10s | Nenhum |
| **Total** | | **~2 minutos** | **Zero downtime** |

**Tecnicas de transparencia:**

| Tecnica | Problema que resolve |
|---------|---------------------|
| Dual-active transitorio | Ambas regioes operam simultaneamente durante sync |
| Readiness gate | Nao redireciona ate producao estar Running+Ready |
| Connection draining | Aguarda requests in-flight no DR completarem |
| Delta sync final | Captura escritas que ocorreram durante o sync principal |

### 5.2. Sincronizacao Bidirecional de Dados (`scripts/dr-data-sync.sh`)

| Modo | Direcao | Quando usar |
|------|---------|-------------|
| `prod-to-dr` | Producao → DR | Antes do failover |
| `dr-to-prod` | DR → Producao | Antes do failback |
| `bidirectional` | Ambas direcoes | Reconciliacao completa |

**Chaves de deduplicacao (INSERT ON CONFLICT DO NOTHING):**

| Tabela | Chave unica | Tipo |
|--------|-------------|------|
| donations | `transaction_id` (UUID) | UNIQUE INDEX |
| ngos | `cnpj` | UNIQUE CONSTRAINT |
| volunteers | `email` | UNIQUE CONSTRAINT |

### 5.3. Identificacao de Regiao Ativa

Em qualquer momento, e possivel identificar qual regiao esta servindo trafego:

| Metodo | Como verificar | Resultado Producao | Resultado DR |
|--------|----------------|-------------------|-------------|
| Grafana "Regiao Ativa" | Panel no topo de todos os 6 dashboards | **PROD** (verde) | **DR** (laranja) |
| API `/region` | `curl http://<service>/region` | `us-east-1`, role: `production` | `us-west-2`, role: `dr` |
| Prometheus | `external_labels` | `cluster: production, region: us-east-1` | `cluster: dr, region: us-west-2` |

---

## 6. Plano de Comunicacao

### Matriz de Comunicacao durante Incidentes

| Severidade | Quem Comunicar | Canal | Frequencia | Responsavel |
|------------|----------------|-------|------------|-------------|
| **SEV1 (Critico)** | Diretoria + ONGs + Equipe toda | Slack #incidents + Email | A cada 15 min | Incident Commander |
| **SEV2 (Alto)** | Gerencia + Equipe tecnica | Slack #incidents | A cada 30 min | On-Call SRE |
| **SEV3 (Medio)** | Equipe tecnica | Slack #sre-alerts | A cada 1h | On-Call SRE |
| **SEV4 (Baixo)** | Equipe tecnica | Slack #sre-weekly | Proximo standup | Engenheiro designado |

### Template de Comunicacao

```
[INCIDENTE] SolidaryTech - {SEVERIDADE}

Status: {Investigando | Identificado | Monitorando | Resolvido}
Impacto: {Descricao do impacto para as ONGs/Doadores}
Servicos afetados: {Lista de servicos}
Inicio: {Data/Hora UTC}
Proxima atualizacao: {Data/Hora UTC}

Acoes em andamento:
- {Acao 1}
- {Acao 2}
```

---

## 7. Calendario de Testes de DR

| Teste | Frequencia | Descricao | Participantes |
|-------|------------|-----------|---------------|
| **DR Drill Completo** | Trimestral | Simulacao completa de failover para regiao DR | Equipe SRE + DevOps |
| **Failover de Banco** | Mensal | Teste de promocao de Read Replica | DBA + SRE |
| **Restore de Backup** | Mensal | Restauracao de backup RDS em ambiente isolado | DBA |
| **Chaos Engineering** | Quinzenal | Injecao de falhas (pod kill, network partition) | SRE |
| **Teste de Runbook** | Mensal | Execucao de runbooks de incidente | On-Call rotation |

---

## 8. Matriz RACI

| Atividade | Incident Commander | SRE On-Call | DBA | DevOps | Gerencia |
|-----------|--------------------|-------------|-----|--------|----------|
| Declarar incidente | **R** | C | I | I | I |
| Failover de banco | A | C | **R** | I | I |
| Escalar infra DR | A | **R** | I | C | I |
| Atualizar DNS | A | **R** | I | C | I |
| Comunicar stakeholders | **R** | I | I | I | A |
| Conduzir Post-Mortem | **R** | C | C | C | A |
| Atualizar runbooks | A | **R** | C | C | I |
| Testar DR | A | **R** | **R** | C | I |

**Legenda:** R = Responsavel | A = Aprovador | C = Consultado | I = Informado
