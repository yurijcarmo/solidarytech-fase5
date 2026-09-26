# FinOps - Analise de Custos Mensais e Forecast

## SolidaryTech - Otimizacao Financeira da Infraestrutura Cloud

---

## 1. Estrategia de Tagging (FinOps)

Todos os recursos de nuvem provisionados via Terraform possuem tags obrigatorias para rastreabilidade de custos e governanca.

### Tags Obrigatorias

| Tag | Valor | Proposito |
|-----|-------|-----------|
| `Project` | `SolidaryTech` | Identificar o projeto para alocacao de custos |
| `Environment` | `Production` / `DR` | Diferenciar ambientes |
| `CostCenter` | `NGO-Core` | Centro de custo para faturamento |
| `ManagedBy` | `Terraform` | Identificar recursos gerenciados via IaC |
| `Service` | `ngo-service` / `donation-service` / `volunteer-service` | Atribuir custo por microsservico |
| `Team` | `DevOps` | Equipe responsavel |

### Implementacao no Terraform

```hcl
locals {
  common_tags = {
    Project     = "SolidaryTech"
    Environment = var.environment
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
    Team        = "DevOps"
  }
}

# Exemplo: todo recurso herda as tags
resource "aws_instance" "example" {
  # ...
  tags = merge(local.common_tags, {
    Service = "ngo-service"
    Name    = "ngo-service-node"
  })
}
```

### Politica de Enforcement

- **Terraform**: `default_tags` no provider AWS garante tags em todos os recursos
- **AWS Config Rule**: Regra para detectar recursos sem tags obrigatorias
- **CI/CD**: Checkov valida presenca de tags nos arquivos Terraform

---

## 2. Analise de Custos - AWS Academy Learner Lab

> **Budget disponivel: $50 USD (creditos do Learner Lab)**
>
> A estrategia e otimizada para uso temporario: subir o ambiente, testar, gravar o video e destruir.

### Custo por Hora (Producao - 1 node)

| Recurso | Tipo/Especificacao | Custo/Hora (USD) | Custo/Dia (USD) |
|---------|--------------------|-----------------:|----------------:|
| **EKS Control Plane** | 1 cluster | $0.100 | $2.40 |
| **EC2 (EKS Node)** | 1x t3.medium (On-Demand) | $0.042 | $1.00 |
| **NAT Gateway** | 1x (us-east-1) | $0.045 | $1.08 |
| **RDS PostgreSQL** | 1x db.t3.micro (Single-AZ) | $0.018 | $0.43 |
| **ElastiCache Redis** | 1x cache.t3.micro | $0.017 | $0.41 |
| **S3 / SQS / ECR** | Uso minimo | ~$0.001 | ~$0.02 |
| | | | |
| **TOTAL PRODUCAO** | | **~$0.22/h** | **~$5.34/dia** |

### Custo DR (Warm Standby - us-west-2) - Sempre Ativo

O ambiente DR roda **permanentemente** com workload minimo para garantir RTO de 3-5 minutos (em teste de lab, o RTO medido foi de 58 segundos). Esta decisao foi tomada porque o custo incremental ($0.205/h) e muito menor que o impacto financeiro de downtime no donation-service (~R$ 7.100 por evento de failover).

| Recurso | Tipo/Especificacao | Custo/Hora (USD) | Custo/Dia (USD) |
|---------|--------------------|-----------------:|----------------:|
| **EKS Control Plane** | 1 cluster | $0.100 | $2.40 |
| **EC2 (EKS Node)** | 1x t3.medium | $0.042 | $1.00 |
| **NAT Gateway** | 1x (us-west-2) | $0.045 | $1.08 |
| **RDS Read Replica** | 1x db.t3.micro (sync continuo) | $0.018 | $0.43 |
| | | | |
| **TOTAL DR** | | **~$0.205/h** | **~$4.91/dia** |

### Justificativa Warm Standby vs Cold DR

| Abordagem | Custo DR/mes | RTO | Risco de falha no failover |
|-----------|------------:|----:|---------------------------|
| Cold DR (provisionar sob demanda) | $0 | 30-45 min | Alto (Terraform pode falhar) |
| **Warm Standby (workload minimo)** | **$148** | **3-5 min** | **Baixo (apenas API calls)** |
| Active-Active (copia completa) | $400 | ~0 min | Baixo |

**O Warm Standby custa 37% do Active-Active e entrega 90% do beneficio de RTO.**

### Estimativa de Uso com $50

| Cenario | Custo/Dia | Dias Disponiveis |
|---------|-----------|-----------------|
| Somente producao | ~$5.34 | **~9 dias** |
| **Producao + DR Warm Standby** | **~$10.25** | **~4 dias** |

### Plano de Uso Recomendado (Budget $50)

| Fase | Duracao | Custo Estimado |
|------|---------|---------------|
| 1. Deploy producao + testes | 1 dia | ~$5.34 |
| 2. Deploy DR + validacao | 1 dia | ~$10.25 |
| 3. Drill de failover + ajustes | 1 dia | ~$10.25 |
| 4. Gravacao do video | 1 dia | ~$10.25 |
| 5. Margem de seguranca | - | ~$13.91 |
| **TOTAL ESTIMADO** | ~4 dias (Prod + DR) | **~$36.09** |

> **IMPORTANTE:** O deploy de producao e DR e feito em um unico comando (`bash scripts/deploy.sh` — Step 10 provisiona o DR automaticamente). Sempre execute `bash scripts/stop-environment.sh` ao parar de usar (pausa nodes mas mantem control planes e RDS replica). Execute `bash scripts/destroy.sh` quando terminar o projeto.

---

## 3. Rightsizing - Analise de Utilizacao

### Metricas Atuais dos Pods (Kubernetes)

| Servico | CPU Request | CPU Limit | CPU Real (avg) | Mem Request | Mem Limit | Mem Real (avg) | Status |
|---------|-------------|-----------|----------------|-------------|-----------|----------------|--------|
| ngo-service | 100m | 250m | ~60m (60%) | 128Mi | 256Mi | ~90Mi (70%) | Adequado |
| donation-service | 200m | 500m | ~150m (75%) | 256Mi | 512Mi | ~200Mi (78%) | Adequado |
| volunteer-service | 100m | 250m | ~40m (40%) | 128Mi | 256Mi | ~70Mi (55%) | Otimizavel |

### Recomendacoes de Rightsizing

| Servico | Acao | Request Atual | Request Recomendado | Economia |
|---------|------|---------------|---------------------|----------|
| volunteer-service | Reduzir CPU request | 100m | 75m | ~25% CPU |
| volunteer-service | Reduzir Mem request | 128Mi | 96Mi | ~25% Mem |
| donation-service | Manter | 200m / 256Mi | Sem alteracao | - |
| ngo-service | Manter | 100m / 128Mi | Sem alteracao | - |

**Meta de utilizacao:** 60-80% dos requests (equilibrio entre eficiencia e headroom para picos).

---

## 4. Recomendacoes de Otimizacao

### Recomendacao 1: Spot Instances para Workloads Nao-Criticos

> **Nota AWS Academy:** Spot Instances nao estao disponiveis no Learner Lab (On-Demand only). Esta recomendacao aplica-se ao ambiente de producao real.

**Economia estimada: ~40% nos nodes nao-criticos**

O volunteer-service nao e time-sensitive e pode tolerar interrupcoes. Em producao, utilizar Spot Instances para seus nodes dedicados.

| Tipo | On-Demand (USD/h) | Spot (USD/h) | Economia |
|------|--------------------|--------------|---------:|
| t3.medium | $0.0416 | $0.0125 | **70%** |

**Economia mensal estimada:** ~$18/mes por node spot

### Recomendacao 2: Savings Plans (Compromisso de 1 Ano)

**Economia estimada: ~30% no compute**

Para workloads que serao executados continuamente (donation-service, ngo-service), contratar Compute Savings Plans de 1 ano.

| Plano | Sem Savings Plan | Com Savings Plan (1y) | Economia |
|-------|------------------|-----------------------|---------:|
| EC2 Compute | $60.74/mes | $42.52/mes | **30%** |

**Economia anual estimada:** ~$218/ano

### Recomendacao 3: S3 Intelligent-Tiering para Backups

**Economia estimada: ~40% no storage de backup**

Backups antigos (> 30 dias) sao raramente acessados. O Intelligent-Tiering move automaticamente para classes mais baratas.

| Classe | Custo/GB/mes | Uso |
|--------|-------------|-----|
| S3 Standard | $0.023 | Backups recentes (< 30 dias) |
| S3 IA | $0.0125 | Backups antigos (30-90 dias) |
| S3 Glacier | $0.004 | Backups arquivados (> 90 dias) |

### Recomendacao 4: Escalar DR Nodes para 0 Fora de Horario Critico

**Economia estimada: ~50% no custo de compute DR**

O Warm Standby exige que a infra exista, mas os **nodes** podem ser escalados para 0 fora do horario comercial (18h-08h) e finais de semana. O control plane, NAT Gateway e RDS continuam ativos — ao escalar o node de volta, os pods sobem em poucos minutos.

**Economia mensal estimada:** ~$18/mes (node t3.medium desligado ~60% do tempo)

> Isso aumenta o RTO fora do horario comercial de ~1 min para ~8 min (tempo para node subir + pods inicializarem), o que e aceitavel para horarios de baixo volume.

### Recomendacao 5: Karpenter para Autoscaling Inteligente

**Economia estimada: ~20% no compute**

Substituir o Cluster Autoscaler pelo Karpenter para provisionamento mais rapido e eficiente de nodes, escolhendo automaticamente o tipo de instancia mais barato disponivel.

---

## 5. Projecao de Custos (Producao Real vs Lab)

### Cenario Producao Real (12 Meses - Sem Otimizacoes)

| Periodo | Producao | DR Warm Standby | Total/Mes |
|---------|----------|-----------------|-----------|
| Mes 1-6 | $160.00 | $148.00 | $308.00 |
| Mes 7-12 | $180.00 | $148.00 | $328.00 |
| **Total Anual** | | | **$3,816.00** |

### Cenario Producao Real (12 Meses - Com Otimizacoes)

| Periodo | Producao | DR (nodes off fora horario) | Total/Mes |
|---------|----------|-----------------------------|-----------|
| Mes 1-6 | $120.00 | $130.00 | $250.00 |
| Mes 7-12 | $135.00 | $130.00 | $265.00 |
| **Total Anual** | | | **$3,090.00** |

### Economia Total Estimada (Producao Real)

| Metrica | Valor |
|---------|-------|
| Custo anual sem otimizacao | $3,816.00 |
| Custo anual otimizado | $3,090.00 |
| **Economia anual** | **$726.00 (19%)** |

### Custo do Warm Standby vs Impacto de Downtime

| Metrica | Valor |
|---------|-------|
| Custo mensal do DR Warm Standby | $148.00 |
| RTO com Cold DR | 30-45 min |
| RTO com Warm Standby | 3-5 min (teste: 58s) |
| **Tempo de downtime evitado por incidente** | **~29-44 min** |
| Perda por failover (estimativa honesta) | ~R$ 7.100 (~4 transacoes in-flight) |
| Perda evitada vs Cold DR (por incidente) | **~R$ 50.000+** |

Um unico incidente de queda de regiao ja paga **5+ meses** de DR Warm Standby.

### Cenario AWS Academy Learner Lab

| Metrica | Valor |
|---------|-------|
| Budget disponivel | $50.00 |
| Custo/dia (producao + DR) | ~$10.25 |
| Dias disponiveis | ~4 dias |
| Uso planejado | 4 dias (Prod + DR Warm Standby) |
| **Custo estimado** | **~$36.09** |
| **Margem restante** | **~$13.91 (28%)** |

---

## 6. Dashboard de Custos

### AWS Cost Explorer - Filtros Recomendados

Para acompanhamento financeiro, configurar os seguintes filtros no AWS Cost Explorer:

1. **Por Projeto:** Filtrar tag `Project = SolidaryTech`
2. **Por Servico:** Filtrar tag `Service` para ver custo por microsservico
3. **Por Ambiente:** Filtrar tag `Environment` para comparar Production vs DR
4. **Por Centro de Custo:** Filtrar tag `CostCenter = NGO-Core`

### Alertas de Budget (AWS Budgets)

| Alerta | Threshold | Acao |
|--------|-----------|------|
| Alerta de custo Lab | 50% do budget ($25) | Verificar se ja gravou o video |
| Alerta de custo Lab | 80% do budget ($40) | Destruir ambiente DR se ativo |
| Alerta critico Lab | 90% do budget ($45) | Executar `destroy.sh` imediatamente |

**Producao real (recomendado):**

| Alerta | Threshold | Acao |
|--------|-----------|------|
| Alerta de custo mensal | 80% do budget ($220) | Email para equipe DevOps |
| Alerta de custo mensal | 100% do budget ($280) | Email para gerencia |
| Alerta de forecast | Projecao > 120% do budget | Email para equipe + Slack |
| Alerta de anomalia | Custo diario > 2x da media | Email + Slack imediato |
