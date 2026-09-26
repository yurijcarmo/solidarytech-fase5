# SolidaryTech - Hackathon Fase 5

Ecossistema de microsserviços para a plataforma **SolidaryTech**, uma empresa global sem fins lucrativos que conecta ONGs, doadores e voluntários, recebendo doações em diversas moedas (BRL, USD, EUR, GBP, JPY).

## Arquitetura

```
                           ┌──────────────────────────────────────┐
                           │         AWS Cloud (us-east-1)         │
                           │                                       │
┌──────────┐  ┌──────────┐ │  ┌──────────────────────────────┐    │
│  GitHub   │─▶│ GitHub   │ │  │        EKS Cluster            │    │
│  Repo     │  │ Actions  │ │  │                                │    │
└──────────┘  │ CI/CD    │ │  │  ┌────────────┐ ┌────────────┐ │    │
              │ + Trivy  │ │  │  │ ngo-service │ │  donation   │ │    │
              └────┬─────┘ │  │  │ Python/Flask│ │  -service   │─┼──┐ │
                   │       │  │  │ + Redis     │ │ Python/Flask│ │  │ │
                   ▼       │  │  └────────────┘ │ + SQS Worker│ │  │ │
              ┌──────────┐ │  │                  │ + Payment GW│ │  │ │
              │  ArgoCD  │ │  │  ┌────────────┐ └────────────┘ │  │ │
              │ App of   │─┤  │  │ volunteer   │                │  │ │
              │  Apps    │ │  │  │  -service   │  ┌──────────┐ │  │ │
              └──────────┘ │  │  │   Python/Flask│  │Monitoring│ │  │ │
                           │  │  └────────────┘  │Prometheus│ │  │ │
                           │  │                   │Grafana   │ │  │ │
                           │  │                   │Loki+OTel │ │  │ │
                           │  │                   │AlertMgr  │ │  │ │
                           │  │                   └──────────┘ │  │ │
                           │  └──────────────────────────────┘  │ │
                           │                                     │ │
                           │  ┌──────┐ ┌─────┐ ┌────────┐ ┌───┐│ │
                           │  │ RDS  │ │ SQS │◀┘│DynamoDB│ │ECR││ │
                           │  │Postgr│ │     │  │ Audit  │ │   ││ │
                           │  └──────┘ └─────┘  └────────┘ └───┘│ │
                           │  ┌──────────┐  ┌───────────┐       │ │
                           │  │ElastiCache│  │ S3 Backup │       │ │
                           │  │  Redis    │  │(Versioned)│       │ │
                           │  └──────────┘  └─────┬─────┘       │ │
                           └───────────────────────┼─────────────┘ │
                                                   │ Cross-Region  │
                           ┌───────────────────────▼─────────────┐
                           │    DR Region (us-west-2)             │
                           │  EKS Standby + RDS Replica + S3     │
                           └──────────────────────────────────────┘
```

## Microsserviços

| Serviço | Linguagem | Porta | Banco | Cache | Descrição |
|---------|-----------|-------|-------|-------|-----------|
| ngo-service | Python/Flask | 8080 | PostgreSQL | Redis | Cadastro e gestão de ONGs parceiras |
| donation-service | Python/Flask | 8081 | PostgreSQL + DynamoDB | Redis | Processamento de doações multi-moeda (Hot Path) |
| volunteer-service | Python/Flask | 8082 | PostgreSQL | - | Match entre voluntários e campanhas |

## Estrutura do Projeto (~188 arquivos)

```
hackathon-solidarytech/
├── microservices/
│   ├── ngo-service/           # Python - CRUD ONGs + Redis cache
│   ├── donation-service/      # Python - Doações + SQS + Payment GW + DynamoDB
│   │   └── src/
│   │       ├── app.py         # API multi-moeda
│   │       ├── worker.py      # Consumer SQS
│   │       └── payment_gateway.py  # Simulador de pagamento
│   └── volunteer-service/     # Python - Matching voluntários/campanhas
│       └── src/
│           ├── app.py         # API de voluntários e campanhas
│           └── models.py      # Volunteer, Campaign, Match
├── terraform/
│   ├── modules/               # VPC, EKS, RDS, SQS, S3, ECR, DynamoDB, ElastiCache
│   └── environments/          # production (us-east-1), dr (us-west-2)
├── kubernetes/
│   ├── base/                  # Deployments, Services, HPA, PDB, NetworkPolicies
│   │   └── cluster/           # Metrics Server, Cluster Autoscaler
│   ├── monitoring/            # Prometheus, Grafana, Loki, OTel, AlertManager, AIOps CronJob
│   └── argocd/                # App of Apps + Application CRDs
├── .github/workflows/         # 5 pipelines CI/CD (test, trivy, build, gitops, terraform)
├── docs/
│   ├── SLO-SLI-SLA.md        # Definições formais SRE
│   ├── PCN.md                # Plano de Continuidade de Negócios
│   ├── ITSM-lifecycle.md     # Ciclo de vida de incidentes + AIOps
│   ├── finops-forecast.md    # Custos, tagging, rightsizing, forecast
│   ├── pitch-executivo.md    # Pitch de venda da solução
│   ├── evolucao-projeto.md   # Evolução Fases 1-5
│   └── decisoes-tecnicas.md  # Decisões arquiteturais (19 decisoes documentadas)
└── scripts/
    ├── deploy.sh              # Deploy completo (Producao + DR Warm Standby)
    ├── destroy.sh             # Destruir tudo (limpeza manual AWS CLI)
    ├── stop-environment.sh    # Pausar ambiente (escalar nodes para 0)
    ├── start-environment.sh   # Retomar ambiente (Prod + DR)
    ├── dr-failover.sh         # Failover para região DR (RTO target: 3-5 min)
    ├── dr-failback.sh         # Failback transparente DR → Prod (zero downtime)
    ├── dr-data-sync.sh        # Sync bidirecional de dados (prod↔DR, delta-only)
    ├── setup-monitoring.sh    # Instalar stack de monitoramento (ConfigMaps Grafana inclusos)
    ├── selfhealing-handler.sh # Remediacao automatica (AIOps) via webhook
    ├── aiops-remediation.sh   # AIOps proativa: 8 verificacoes com correcao automatica
    ├── automated-rca.sh       # RCA automatizado + Post-Mortem
    ├── dr-health-checker.sh   # Health checker + failover automatico DR
    ├── post-deploy-check.sh   # Health check pos-deploy com auto-correcao
    ├── validate-environment.sh # Validacao completa do ambiente
    └── load-test.sh           # Teste de carga (seed, light, medium, heavy, ramp)
```

## Quick Start

### Teste Local (Docker Compose)

```bash
cd hackathon-solidarytech

# Subir stack local (PostgreSQL, Redis, LocalStack, 3 serviços, Prometheus, Grafana)
docker-compose up -d

# Criar filas SQS e tabela DynamoDB no LocalStack
./scripts/create-sqs-queue.sh

# Testar uma doação multi-moeda
curl -X POST http://localhost:8081/api/v1/donations \
  -H "Content-Type: application/json" \
  -d '{"donor_name":"John","amount":100,"currency":"USD","payment_method":"credit_card","ngo_id":1}'

# Ver moedas suportadas
curl http://localhost:8081/api/v1/donations/currencies

# Acessar Grafana
open http://localhost:3000  # admin/admin
```

### Deploy na AWS Academy

```bash
# 1. Configurar credenciais (copiar do AWS Academy Learner Lab)
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
export AWS_DEFAULT_REGION="us-east-1"

# 2. Deploy completo (Producao + DR Warm Standby em us-west-2)
./scripts/deploy.sh

# 3. Acessar dashboards
kubectl port-forward svc/grafana -n monitoring 3000:3000
kubectl port-forward svc/argocd-server 8443:443 -n argocd

# 4. Testar failover (RTO target: 3-5 min)
./scripts/dr-failover.sh

# 5. Failback transparente (zero downtime para o cliente)
./scripts/dr-failback.sh
```

### Demo: Teste de Carga e Graficos no Grafana

Apos o deploy, siga estes passos para popular o Grafana com dados reais e demonstrar auto-scaling.

#### Passo 1: Port-Forward dos servicos

```bash
# Abrir port-forward para os 3 microsservicos + Grafana + Prometheus
kubectl port-forward svc/ngo-service -n solidarytech 8080:8080 &
kubectl port-forward svc/donation-service -n solidarytech 8081:8081 &
kubectl port-forward svc/volunteer-service -n solidarytech 8082:8082 &
kubectl port-forward svc/grafana -n monitoring 3000:3000 &
kubectl port-forward svc/prometheus -n monitoring 9091:9090 &
```

#### Passo 2: Criar dados iniciais (seed)

```bash
# Cria 5 ONGs, 10 voluntarios, 5 campanhas e 10 doacoes iniciais
./scripts/load-test.sh seed
```

#### Passo 3: Gerar carga e observar metricas no Grafana

```bash
# Abra o Grafana em http://localhost:3000 (admin/admin)
# Navegue ate o dashboard "SolidaryTech - Overview"
# Enquanto observa, execute um dos testes abaixo:

# Carga leve (5 req/s) — gera metricas basicas no Grafana
./scripts/load-test.sh light

# Carga media (20 req/s) — CPU sobe, HPA pode comecar a escalar
./scripts/load-test.sh medium

# Carga pesada (50 req/s) — HPA escala pods automaticamente
./scripts/load-test.sh heavy

# Rampa progressiva (5 -> 50 req/s) — demo completo de scaling
./scripts/load-test.sh ramp

# Demo completo: seed + rampa progressiva
./scripts/load-test.sh all
```

#### Passo 4: Verificar auto-scaling (HPA)

```bash
# Observar o HPA escalando pods em tempo real
watch kubectl get hpa -n solidarytech

# Exemplo de saida durante carga pesada:
# donation-service-hpa  cpu: 100%/60%  1  4  4    <- escalou de 1 para 4 replicas!
# ngo-service-hpa       cpu: 17%/70%   1  3  1
# volunteer-service-hpa cpu: 14%/70%   1  3  1
```

#### Passo 5: Escalar nodes (se necessario)

```bash
# No AWS Academy, o Cluster Autoscaler nao opera (limitacao IAM).
# Para escalar nodes manualmente:
aws eks update-nodegroup-config \
    --cluster-name solidarytech-eks-production \
    --nodegroup-name solidarytech-node-group \
    --scaling-config minSize=2,maxSize=5,desiredSize=3
```

#### Passo 6: Verificar estado geral

```bash
# Health check completo com auto-correcao
./scripts/post-deploy-check.sh

# Status rapido (pods, HPA, nodes)
./scripts/load-test.sh status
```

#### Dashboards Disponiveis no Grafana

| Dashboard | O que mostra |
|-----------|-------------|
| Platform Overview | Request rate, latencia p99, erros, pods, HPA, CPU/memoria + **Regiao Ativa** |
| Business Metrics - Doacoes | Doacoes processadas, total arrecadado, distribuicao por moeda + **Regiao Ativa** |
| SRE - Golden Metrics (Donation Service) | Latencia, trafego, erros, saturacao do Hot Path + **Regiao Ativa** |
| SLO/SLI Tracking - Donation Service | Error budget, SLO compliance, burn rate + **Regiao Ativa** |
| Infrastructure & Cluster | Nodes, pods, HPA, CPU/memoria por namespace + **Regiao Ativa** |
| Disaster Recovery - Status & Impacto | RTO/RPO, integridade de dados, perda estimada, timeline + **Regiao Ativa** |

#### Demo de DR Failover e Failback

```bash
# Modo dry-run (simula sem executar)
./scripts/dr-health-checker.sh --dry-run

# Failover manual (RTO target: 3-5 min)
./scripts/dr-failover.sh

# Sync bidirecional de dados (prod↔DR)
./scripts/dr-data-sync.sh bidirectional

# Failback transparente (zero downtime para o cliente)
./scripts/dr-failback.sh

# Verificar regiao ativa via API
curl http://localhost:8081/region

# Failover automatico real (requer DR deployado em us-west-2)
./scripts/dr-health-checker.sh --once --auto-failover
```

#### Limitacoes do AWS Academy

O AWS Academy Learner Lab impoe restricoes de IAM que afetam algumas funcionalidades:

| Funcionalidade | Restricao | Mitigacao |
|---------------|-----------|-----------|
| Cluster Autoscaler | LabEksNodeRole sem `autoscaling:DescribeAutoScalingGroups` | Node scaling via CLI (`aws eks update-nodegroup-config`) |
| SQS Worker | LabEksNodeRole sem `sqs:ReceiveMessage` | Worker escalado a 0; doacoes processadas sincronamente |
| RDS Read Replica cross-region | Sem `rds:CreateDBInstanceReadReplica` | DR usa RDS standalone; em producao seria Read Replica com RPO ~1s |
| EKS Managed Node Group SG | Pods usam SG auto-criado pelo EKS, diferente do Terraform | Modulo RDS aceita ambos os SGs (node + cluster) |
| IMDS hop limit | Padrao = 1, pods nao acessam credenciais | Corrigido via `modify-instance-metadata-options` |

Em producao real com IAM completo, todas as funcionalidades operam nativamente (Read Replica cross-region, Cluster Autoscaler, SQS Worker).
Documentacao detalhada: [`docs/decisoes-tecnicas.md` secao 10](docs/decisoes-tecnicas.md).

---

### Gerenciamento de Custos

```bash
# Pausar ambiente (escala nodes para 0, mantém control planes e RDS replica)
./scripts/stop-environment.sh

# Retomar ambiente (Produção + DR Warm Standby)
./scripts/start-environment.sh

# Destruir TUDO (polling ativo + verify_clean - ~36 minutos)
./scripts/destroy.sh

# AIOps - verificacao proativa manual (8 checks)
./scripts/aiops-remediation.sh           # Detecta e corrige
./scripts/aiops-remediation.sh --dry-run  # Apenas detecta
./scripts/aiops-remediation.sh --watch    # Loop continuo (60s)
```

## Cobertura dos 5 Eixos de Avaliação

### 0. Fundação DevOps (Fases 1-4) - Obrigatório

| Requisito | Implementação | Evidência |
|-----------|---------------|-----------|
| Docker | Dockerfiles multi-stage otimizados (Python) | `microservices/*/Dockerfile` |
| Kubernetes (EKS) | Deployments com HPA, probes, PDB, resource limits | `kubernetes/base/` |
| IaC (Terraform) | 8 módulos: VPC, EKS, RDS, SQS, S3, ECR, DynamoDB, ElastiCache | `terraform/modules/` |
| CI/CD (GitHub Actions) | 5 pipelines com testes, Trivy SAST/SCA, build/push ECR | `.github/workflows/` |
| GitOps (ArgoCD) | App of Apps com auto-sync e self-heal | `kubernetes/argocd/` |
| Observabilidade | Prometheus + Grafana + Loki + OTel + AlertManager | `kubernetes/monitoring/` |
| Segurança | NetworkPolicies (deny-all), SecurityContext hardened (non-root, drop ALL, readOnly), ECR IMMUTABLE, deletion_protection, automountServiceAccountToken:false | `kubernetes/base/network-policies.yaml` |

### 1. SRE: Golden Metrics e SLOs

- **SLI Latência**: p99 do donation-service < 500ms (SLO: 99.9%)
- **SLI Disponibilidade**: Taxa de erro < 0.1% (SLO: 99.9%)
- **Error Budget**: 43.2 min/mês - política de consumo documentada
- **MTTR**: Reduzido via selfhealing automático e RCA automatizado
- **Dashboard SRE**: 2 dashboards Grafana (Golden Metrics + SLO/Error Budget)
- **Alerting Rules**: 8 regras para detecção proativa
- Documentação: [`docs/SLO-SLI-SLA.md`](docs/SLO-SLI-SLA.md)

### 2. FinOps: Otimização Financeira

- **Tagging**: TODOS os recursos com Project, Environment, CostCenter, ManagedBy
- **Rightsizing**: Requests/limits calibrados (donation-service 2x por ser Hot Path)
- **Forecast**: ~$352/mês (produção + DR) com 5 recomendações de otimização
- **Scripts de economia**: stop/start para pausar quando não usar
- Documentação: [`docs/finops-forecast.md`](docs/finops-forecast.md)

### 3. ITSM e AIOps

- **SelfHealing**: PDB + AlertManager + webhook de remediação automática (Python)
- **AIOps Proativa**: CronJob com 8 verificações a cada 5 minutos (`aiops-remediation.sh`) — detecta e corrige automaticamente CrashLoopBackOff, capacidade de pods, monitoring stack, ArgoCD, services, health checks, AWS resources e namespaces travados
- **Auto-Scaling 3 camadas**:
  - **Pod**: HPA com CPU + memória — donation-service max 4 réplicas, ngo/volunteer max 3 (calibrados para capacidade t3.medium: 17 pods/node, 34 total com 2 nodes)
  - **Node**: node-autoscaler.sh (workaround Academy) + Metrics Server v0.7.2 — escala nodes de 1 a 3 via API EKS
  - **DR**: Health checker automático com failover em ~5 min após 3 falhas consecutivas
- **RCA Automatizado**: Script que coleta logs, eventos, métricas e gera relatório
- **Ciclo de Incidentes**: 6 fases (Detecção -> Post-Mortem)
- **Post-Mortem Blameless**: Template estruturado
- **Deploy/Destroy Idempotentes**: `clean_orphans()` pré-deploy + polling ativo no destroy + `verify_clean()` pós-destroy (deploy ~47min, destroy ~36min)
- Documentação: [`docs/ITSM-lifecycle.md`](docs/ITSM-lifecycle.md)

### 4. Multicloud, Segurança e DR

- **PCN**: RTO **3-5 minutos** (teste em lab: 58s) / RPO **0 para dados commitados** (sync bidirecional)
- **DR Warm Standby**: Workload mínimo **sempre ativo** em us-west-2 (1 node + RDS + apps com 1 replica)
- **Failover com sync**: `dr-failover.sh` sincroniza dados prod→DR antes do failover, garantindo integridade
- **Failback transparente**: `dr-failback.sh` com 8 etapas, dual-active transitorio, zero downtime para o cliente
- **Sync bidirecional**: `dr-data-sync.sh` com delta-only transfer, dedup por transaction_id/cnpj/email
- **Perda honesta no failover**: ~4 transacoes in-flight durante 58s de RTO (~R$ 7.100 de impacto)
- **Identificacao de regiao**: Grafana "Regiao Ativa" (PROD/DR) em todos os 6 dashboards + endpoint `/region` nos 3 microsservicos + Prometheus `external_labels`
- **Failover Automático**: `dr-health-checker.sh --daemon --auto-failover` monitora produção e dispara failover automaticamente após 3 falhas consecutivas
- **Segurança Hardened (4 camadas)**: credenciais mascaradas em scripts, ECR IMMUTABLE, deletion_protection no RDS, securityContext non-root com drop ALL em todos os pods, NetworkPolicies deny-all + regras explicitas, automountServiceAccountToken:false, validacao de entrada (paginacao max 100, valores monetarios), Grafana admin via secretKeyRef
- Documentação: [`docs/PCN.md`](docs/PCN.md), [`docs/decisoes-tecnicas.md`](docs/decisoes-tecnicas.md)

## Tecnologias Utilizadas

| Categoria | Tecnologia |
|-----------|------------|
| Linguagens | Python 3.13 |
| Frameworks | Flask, SQLAlchemy, Gunicorn |
| Bancos de Dados | PostgreSQL 15, DynamoDB, Redis |
| Container | Docker (multi-stage builds) |
| Orquestração | Kubernetes (EKS 1.36) |
| IaC | Terraform |
| CI/CD | GitHub Actions |
| GitOps | ArgoCD (App of Apps) |
| Observabilidade | Prometheus, Grafana, Loki, OpenTelemetry, AlertManager |
| Mensageria | Amazon SQS |
| Segurança | Trivy, NetworkPolicies, SecurityContext |
| AIOps | CronJob proativo (8 verificacoes/5min), self-healing webhook, RCA automatizado |
| DR | Warm Standby (us-west-2), sync bidirecional, RTO 3-5 min (teste: 58s), failback transparente |

## Equipe

Consulte o documento de entrega do projeto (PDF) para a lista completa de integrantes.
