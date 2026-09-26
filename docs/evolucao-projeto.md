# Evolucao do Projeto - Fases 1 a 5

## SolidaryTech: Da Fundacao a Maturidade Operacional

---

## Timeline do Projeto

```
Fase 1          Fase 2          Fase 3          Fase 4          Fase 5
Fundacao        Containers      Automacao        Observabilidade Maturidade
   |               |               |               |               |
   v               v               v               v               v
[Docker]       [K8s Avancado]  [Terraform]     [Prometheus]    [SRE/FinOps]
[K8s Basics]   [Microservicos] [CI/CD]         [Grafana]       [ITSM/AIOps]
[AWS Basics]   [Networking]    [DevSecOps]     [APM/Tracing]   [DR/PCN]
[Arquitetura]  [Storage]       [GitOps]        [Alertas]       [Seguranca]
```

---

## Fase 1 - Fundacao (Docker, Kubernetes e AWS)

### O que foi aprendido

- Conceitos fundamentais de **containers**: imagens, layers, Dockerfile, Docker Hub
- Introducao ao **Kubernetes**: Pods, Deployments, Services, Namespaces
- Fundamentos de **arquitetura cloud**: regioes, AZs, VPC, subnets
- Servicos AWS basicos: EC2, S3, IAM, VPC
- Cultura **DevOps**: colaboracao, automacao, feedback continuo

### O que foi aplicado no projeto

| Tecnologia | Aplicacao na SolidaryTech |
|------------|--------------------------|
| Docker | Dockerfiles multi-stage para os 3 microsservicos |
| Kubernetes | Deployments com 2 replicas, Services ClusterIP |
| AWS VPC | Rede isolada com subnets publicas e privadas |
| AWS EKS | Cluster gerenciado Kubernetes 1.36 (t3.medium, 2 nodes) |
| Namespaces | `solidarytech` (apps) e `monitoring` (observabilidade) |

### Diferencial entregue

> Capacidade de empacotar qualquer aplicacao em container e orquestra-la em um cluster Kubernetes gerenciado na AWS.

---

## Fase 2 - Containerizacao Avancada

### O que foi aprendido

- Dockerfiles **otimizados**: multi-stage builds, cache de layers, imagens slim
- Orquestracao K8s avancada: **HPA**, liveness/readiness probes, resource limits
- Networking Kubernetes: Ingress, NetworkPolicies, DNS interno
- Persistencia: Volumes, PVCs, StatefulSets
- Padrao de **microsservicos**: decomposicao, comunicacao entre servicos

### O que foi aplicado no projeto

| Tecnologia | Aplicacao na SolidaryTech |
|------------|--------------------------|
| Multi-stage builds | Imagens finais ~80MB (python:3.13-slim) |
| Non-root user | Seguranca: containers rodam sem privilegio root |
| HPA | Auto-scaling baseado em capacidade t3.medium (17 pods/node): donation-service 1-4 (CPU 60%), ngo-service 1-3 (CPU 70%), volunteer-service 1-3 (CPU 70%) |
| Probes | Liveness (/health) e Readiness (/ready) em todos os servicos |
| Resource limits | CPU e memoria calibrados por servico (rightsizing) |
| Ingress | Roteamento por path para cada microsservico |
| Pod Anti-Affinity | Pods distribuidos em nodes diferentes para HA |

### Diferencial entregue

> Microsservicos otimizados com auto-scaling inteligente, alta disponibilidade e uso eficiente de recursos.

---

## Fase 3 - Automacao (IaC, CI/CD, DevSecOps, GitOps)

### O que foi aprendido

- **Terraform**: modules, state, workspaces, remote backend
- **CI/CD**: GitHub Actions, pipelines multi-stage, gates de qualidade
- **DevSecOps**: SAST, SCA, scans de imagem, seguranca no pipeline
- **GitOps**: ArgoCD, FluxCD, reconciliacao automatica
- **Seguranca na Cloud**: IAM, Security Groups, encryption at rest

### O que foi aplicado no projeto

| Tecnologia | Aplicacao na SolidaryTech |
|------------|--------------------------|
| Terraform | 8 modulos (VPC, EKS, RDS, SQS, S3, ECR, DynamoDB, ElastiCache), 2 ambientes (prod, DR) |
| GitHub Actions | 5 pipelines (3 servicos + seguranca + terraform) |
| Trivy | Scan SAST/SCA em cada build - bloqueia HIGH/CRITICAL |
| ArgoCD | App of Apps com auto-sync e self-heal |
| Remote State | S3 + DynamoDB para state locking |
| GitOps Flow | Push no main -> CI build -> Atualiza manifesto -> ArgoCD sync |

### Pipeline CI/CD Completa

```
   Git Push
      |
      v
  [Test + Lint]
      |
      v
  [Security Scan]  -> Trivy (imagem) + Safety (deps) + Checkov (IaC)
      |
      v
  [Build + Push ECR]
      |
      v
  [Update Manifests]  -> Altera tag da imagem no YAML
      |
      v
  [ArgoCD Sync]       -> Detecta mudanca e aplica no cluster
      |
      v
  [Producao!]
```

### Diferencial entregue

> Infraestrutura 100% como codigo, pipeline com seguranca integrada e entrega continua automatizada via GitOps.

---

## Fase 4 - Observabilidade (Monitoring, APM, Tracing)

### O que foi aprendido

- Stack de observabilidade: **Prometheus** (metricas), **Grafana** (visualizacao), **Loki** (logs)
- **APM** e distributed tracing com OpenTelemetry
- Alertas e notificacoes: regras Prometheus, Alertmanager
- Instrumentacao de codigo: metricas customizadas, spans, trace propagation
- **Golden Signals**: Latencia, Trafego, Erros, Saturacao

### O que foi aplicado no projeto

| Tecnologia | Aplicacao na SolidaryTech |
|------------|--------------------------|
| Prometheus | Scraping de metricas de todos os servicos + K8s, `external_labels` para identificacao de regiao |
| Grafana | 6 dashboards: Platform Overview, Business Metrics, SRE Golden Metrics, SLO Tracking, Infrastructure & Cluster, DR Status — todos com panel "Regiao Ativa" |
| Loki | Agregacao centralizada de logs |
| OpenTelemetry | Collector como DaemonSet + instrumentacao Flask |
| Distributed Tracing | Propagacao de contexto entre donation-service e worker |
| Metricas SLI | donation_request_duration_seconds, donation_errors_total |
| ServiceMonitor | CRD Prometheus para auto-discovery de endpoints |

### Metricas Customizadas do donation-service

```python
DONATION_DURATION = Histogram("donation_request_duration_seconds", ...)
DONATION_ERRORS = Counter("donation_errors_total", ...)
DONATION_PROCESSED = Counter("donation_processed_total", ...)
DONATION_SLO_LATENCY = Histogram("donation_slo_latency_seconds", ...)
```

### Diferencial entregue

> Visibilidade completa do ecossistema com metricas, logs e traces correlacionados - nenhum "voo cego".

---

## Fase 5 - Maturidade Operacional (SRE, FinOps, ITSM/AIOps, DR)

### O que foi aprendido

- **SRE**: SLI, SLO, SLA, Error Budget, Runbooks, Post-Mortem
- **FinOps**: Tagging, Rightsizing, Forecast, otimizacao de custos
- **ITSM**: ITIL, gestao de incidentes, ciclo de vida, classificacao SEV1-4
- **AIOps**: Deteccao de anomalias, self-healing, RCA automatizado
- **DR**: PCN, RTO, RPO, estrategias (Active-Active vs Warm Standby)
- **Multicloud e Seguranca**: cross-region, NetworkPolicies, security contexts

### O que foi aplicado no projeto

| Tecnologia | Aplicacao na SolidaryTech |
|------------|--------------------------|
| SLI/SLO | 2 SLIs formais para donation-service (latencia + disponibilidade) |
| Error Budget | 0.1% = 43.2 min/mes, com politica de consumo |
| Tagging FinOps | Todos os recursos com Project, Environment, CostCenter, ManagedBy |
| Rightsizing | Requests/limits calibrados + HPA |
| Forecast | Projecao de $352/mes com 5 recomendacoes de otimizacao |
| ITSM | Ciclo completo: Deteccao -> Classificacao -> Escalonamento -> Resolucao -> Post-Mortem |
| AIOps | Alertas preditivos + self-healing K8s + RCA automatizado + CronJob de remediacao proativa (8 verificacoes a cada 5 min) |
| DR | Warm Standby em us-west-2, deploy unificado, RTO 3-5 min (teste: 58s), sync bidirecional (`dr-data-sync.sh`), failback transparente (`dr-failback.sh`), identificacao de regiao em 3 camadas |
| PCN | Documento executivo com RTO 3-5 min (teste: 58s), RPO=0 para dados commitados, analise honesta de perda (~4 transacoes/~R$7.100 por failover) |
| Seguranca | Private subnets, SecurityContext hardened (non-root, readOnly, drop ALL), NetworkPolicies deny-all, ECR IMMUTABLE, deletion_protection, automountServiceAccountToken:false |

### Diferencial entregue

> Maturidade operacional enterprise: a plataforma nao apenas funciona - ela se auto-monitora, se auto-recupera, justifica seus custos e sobrevive a desastres.

---

## Quadro Consolidado de Tecnologias

| Categoria | Tecnologia | Fase Introduzida | Onde Aparece no Projeto |
|-----------|------------|-------------------|------------------------|
| **Container** | Docker | Fase 1 | `microservices/*/Dockerfile` |
| **Orquestracao** | Kubernetes (EKS) | Fase 1 | `kubernetes/base/` |
| **Cloud** | AWS (VPC, EC2, RDS, SQS, S3) | Fase 1 | `terraform/modules/` |
| **IaC** | Terraform | Fase 3 | `terraform/` (8 modulos, 2 ambientes) |
| **CI/CD** | GitHub Actions | Fase 3 | `.github/workflows/` (5 pipelines) |
| **DevSecOps** | Trivy, Checkov | Fase 3 | `.github/workflows/security-scan.yml` |
| **GitOps** | ArgoCD | Fase 3 | `kubernetes/argocd/` (App of Apps) |
| **Metricas** | Prometheus | Fase 4 | `kubernetes/monitoring/prometheus/` |
| **Visualizacao** | Grafana (6 dashboards + Regiao Ativa) | Fase 4 | `kubernetes/monitoring/grafana/dashboards/` |
| **Logs** | Loki | Fase 4 | `kubernetes/monitoring/loki/` |
| **Tracing** | OpenTelemetry | Fase 4 | Instrumentacao nos 3 microsservicos |
| **SRE** | SLI/SLO/Error Budget | Fase 5 | `docs/SLO-SLI-SLA.md` + dashboards |
| **FinOps** | Tagging + Forecast | Fase 5 | `terraform/main.tf` + `docs/finops-forecast.md` |
| **ITSM** | Gestao de Incidentes | Fase 5 | `docs/ITSM-lifecycle.md` |
| **AIOps** | Self-healing + Alertas + Remediacao Proativa | Fase 5 | Prometheus rules + K8s probes + `aiops-remediation.sh` (CronJob 5min) |
| **DR** | Warm Standby + Sync Bidirecional + Failback | Fase 5 | `terraform/environments/dr/` + `scripts/dr-*.sh` |
| **PCN** | Continuidade de Negocios | Fase 5 | `docs/PCN.md` |
| **Auto-scaling** | HPA + node-autoscaler.sh (Cluster Autoscaler inoperante no Academy) | Fase 2 | `kubernetes/base/*/hpa.yaml` + `scripts/node-autoscaler.sh` |
| **Banco de Dados** | PostgreSQL (RDS) | Fase 1 | `terraform/modules/rds/` |
| **Mensageria** | SQS | Fase 3 | `terraform/modules/sqs/` + donation-worker |
| **Registry** | ECR | Fase 3 | `terraform/modules/ecr/` |
| **Python** | Flask + SQLAlchemy | Fase 1 | `microservices/*/src/app.py` |

---

## Visao de Maturidade

```
                    Maturidade Operacional
                          ^
Fase 5: SRE/FinOps/DR     |  ████████████████████████████  Autonomo
                          |
Fase 4: Observabilidade   |  █████████████████████         Proativo
                          |
Fase 3: Automacao/IaC     |  ██████████████                Automatizado
                          |
Fase 2: Containers K8s    |  ████████                      Orquestrado
                          |
Fase 1: Fundacao           |  ████                          Manual
                          └──────────────────────────────> Tempo
```

Cada fase construiu sobre a anterior, criando uma base solida para a proxima evolucao. O resultado e uma plataforma que opera com maturidade enterprise, apesar de ser mantida por uma equipe enxuta.
