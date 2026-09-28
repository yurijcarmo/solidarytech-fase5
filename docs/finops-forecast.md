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

### Politica de Tagging e Validacao

- **Terraform**: `default_tags` no provider AWS aplica as tags comuns aos recursos suportados pelo provider.
- **Modulos Terraform**: recursos com necessidade de identificacao adicional recebem tags especificas, como `Name` e `Service`.
- **CI/CD**: o pipeline executa Checkov sobre o diretorio `terraform/` para analise estatica da infraestrutura como codigo.
- **Governanca**: a estrategia de tagging permite segmentar custos por projeto, ambiente e centro de custo no AWS Cost Explorer.

> O projeto nao provisiona atualmente uma AWS Config Rule de `required-tags`; portanto, a validacao de tagging e realizada principalmente no codigo Terraform e no pipeline de IaC.

---

## 2. Analise de Custos - AWS Academy Learner Lab

> **Budget disponivel: $50 USD (creditos do Learner Lab)**
>
> A estrategia e otimizada para uso temporario: subir o ambiente, testar, gravar o video e destruir.

### Custo por Hora (Producao - capacidade inicial do Terraform)

| Recurso | Tipo/Especificacao | Custo/Hora (USD) | Custo/Dia (USD) |
|---------|--------------------|-----------------:|----------------:|
| **EKS Control Plane** | 1 cluster | $0.100 | $2.40 |
| **EC2 (EKS Nodes)** | 2x t3.medium (On-Demand) | $0.084 | $2.02 |
| **NAT Gateway** | 1x (us-east-1) | $0.045 | $1.08 |
| **RDS PostgreSQL** | 1x db.t3.micro (Single-AZ) | $0.018 | $0.43 |
| **ElastiCache Redis** | 1x cache.t3.micro | $0.017 | $0.41 |
| **S3 / SQS / ECR** | Uso minimo | ~$0.001 | ~$0.02 |
| | | | |
| **TOTAL PRODUCAO** | | **~$0.265/h** | **~$6.36/dia** |

### Custo DR (Warm Standby - us-west-2) - Sempre Ativo

O ambiente DR esta dimensionado no Terraform com workload minimo: um node `t3.medium`, com capacidade de escalar entre 1 e 3 nodes.

Na configuracao atual do laboratorio, o RDS do DR e provisionado como uma instancia `db.t3.micro` independente (`is_read_replica = false`). O modulo Terraform suporta Read Replica e o codigo documenta essa configuracao como a opcao indicada para um ambiente de producao real, mas a replicacao continua nao esta habilitada atualmente.

Os valores de RTO/RPO devem ser tratados como objetivos arquiteturais enquanto nao houver um novo DR drill com medicao reproduzivel.

| Recurso | Tipo/Especificacao | Custo/Hora (USD) | Custo/Dia (USD) |
|---------|--------------------|-----------------:|----------------:|
| **EKS Control Plane** | 1 cluster | $0.100 | $2.40 |
| **EC2 (EKS Node)** | 1x t3.medium | $0.042 | $1.00 |
| **NAT Gateway** | 1x (us-west-2) | $0.045 | $1.08 |
| **RDS PostgreSQL DR** | 1x db.t3.micro independente no lab | $0.018 | $0.43 |
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
| Somente producao | ~$6.36 | **~7 dias** |
| **Producao + DR** | **~$11.28** | **~4 dias** |

### Plano de Uso Recomendado (Budget $50)

| Fase | Duracao | Custo Estimado |
|------|---------|---------------|
| 1. Deploy producao + testes | 1 dia | ~$6.36 |
| 2. Deploy DR + validacao | 1 dia | ~$11.28 |
| 3. Drill de failover + ajustes | 1 dia | ~$11.28 |
| 4. Gravacao do video | 1 dia | ~$11.28 |
| 5. Margem de seguranca | - | calculada conforme dias efetivamente utilizados |
| **TOTAL ESTIMADO** | depende do tempo real de execucao | **monitorar via AWS Cost Explorer/Budgets** |

> **IMPORTANTE:** O deploy de producao e DR e feito em um unico comando (`bash scripts/deploy.sh` — Step 10 provisiona o DR automaticamente). Sempre execute `bash scripts/stop-environment.sh` ao parar de usar (reduz a capacidade de compute conforme configurado pelo script; recursos persistentes continuam sujeitos a custos). Execute `bash scripts/destroy.sh` quando terminar o projeto.

---

## 3. Rightsizing - Analise de Utilizacao

### Recursos Configurados nos Pods

| Servico | CPU Request | CPU Limit | Mem Request | Mem Limit | Medicao Runtime |
|---------|-------------|-----------|-------------|-----------|-----------------|
| ngo-service | 100m | 250m | 192Mi | 384Mi | Pendente |
| donation-service | 100m | 500m | 256Mi | 512Mi | Pendente |
| volunteer-service | 100m | 250m | 192Mi | 384Mi | Pendente |
| donation-worker | 100m | 400m | 192Mi | 384Mi | Pendente |

### Estrategia de Rightsizing

Os `requests` e `limits` acima refletem os manifests Kubernetes atuais.

O projeto possui:

- HPA para os workloads;
- teste de carga progressivo de 5, 15, 30 e 50 req/s;
- script `scripts/collect-rightsizing-metrics.sh` para capturar CPU e memoria durante os testes.

A medicao runtime no EKS esta pendente porque o cluster configurado atualmente nao esta acessivel. Por esse motivo, nao foi aplicada reducao adicional de CPU ou memoria sem evidencia de utilizacao real.

Quando o ambiente estiver disponivel, o processo sera:

1. executar o coletor de CPU/memoria;
2. executar o teste de carga progressivo;
3. comparar consumo medio e picos com os requests;
4. ajustar requests/limits somente quando houver margem comprovada;
5. repetir o teste para validar que a alteracao nao degrada SLOs.

**Objetivo de rightsizing:** manter capacidade suficiente para picos e HPA, evitando requests superdimensionados sem comprometer confiabilidade.

---

## 4. Recomendacoes de Otimizacao

As recomendacoes abaixo sao oportunidades a serem avaliadas com base em historico real de utilizacao. Elas nao representam economia ja obtida pelo projeto.

### 1. Rightsizing baseado em metricas

Executar o teste de carga progressivo junto ao `scripts/collect-rightsizing-metrics.sh` quando o EKS estiver disponivel.

Somente apos observar CPU, memoria, picos e comportamento do HPA devem ser alterados `requests` e `limits`.

### 2. Spot Instances para workloads tolerantes a interrupcao

Em um ambiente de producao real, workloads que suportem interrupcoes podem ser avaliados para execucao em capacidade Spot.

A economia depende do tipo de instancia, regiao, disponibilidade e preco Spot no momento da execucao; portanto, nao e adotado um percentual fixo neste forecast.

### 3. Savings Plans para carga previsivel

Caso o ambiente permaneça ativo continuamente e exista historico suficiente de consumo, avaliar Compute Savings Plans.

A decisao deve ser baseada em utilizacao real porque Savings Plans envolvem compromisso financeiro.

### 4. Otimizacao de storage de backups

Para backups com baixa frequencia de acesso, avaliar lifecycle policies, S3 Intelligent-Tiering ou classes de arquivamento.

A estrategia deve considerar periodo de retencao, frequencia de restore e custo de recuperacao.

### 5. Capacidade do ambiente DR

O Terraform atual mantem capacidade minima de compute no DR.

Scheduled scaling pode ser avaliado em periodos de baixa criticidade. Reduzir o node group para zero exigiria alterar a configuracao atual e aumentaria o RTO, portanto deve ser tratado como decisao arquitetural.

### 6. Autoscaling de nodes

Karpenter pode ser avaliado futuramente para provisionamento dinamico de capacidade, desde que o comportamento real dos workloads e os requisitos de disponibilidade justifiquem a mudanca.

---

## 5. Projecao de Custos - Baseline da Arquitetura Atual

A projecao abaixo representa um baseline mensal da infraestrutura descrita atualmente no Terraform.

### Premissas

- 730 horas por mes;
- 2 nodes `t3.medium` inicialmente em producao;
- 1 node `t3.medium` inicialmente no DR;
- 1 cluster EKS por regiao;
- 1 NAT Gateway por ambiente;
- 1 endereco IPv4 publico associado a cada NAT Gateway;
- RDS e ElastiCache utilizam os valores aproximados adotados pelo projeto;
- custos variaveis de transferencia, processamento do NAT, storage, I/O, logs e crescimento de carga nao estao incluidos.

### Baseline Mensal

| Componente | Producao | DR |
|------------|---------:|---:|
| EKS Control Plane | ~$73.00 | ~$73.00 |
| EC2 / EKS Nodes | ~$60.74 | ~$30.37 |
| NAT Gateway | ~$32.85 | ~$32.85 |
| IPv4 publico do NAT | ~$3.65 | ~$3.65 |
| RDS PostgreSQL | ~$13.14 | ~$13.14 |
| ElastiCache Redis | ~$12.41 | - |
| S3 / SQS / ECR (baseline) | ~$0.73 | - |
| **Total estimado** | **~$196.52/mes** | **~$153.01/mes** |

**Baseline combinado:** aproximadamente **$349.53/mes**, antes de custos variaveis.

Aproximando esse baseline para uso temporario:

- producao: ~$6.46/dia;
- producao + DR: ~$11.49/dia;
- com budget de $50, o limite teorico e pouco acima de 4 dias, mas o ambiente deve ser acompanhado pelo AWS Cost Explorer/Budgets porque trafego, storage, I/O e outros custos variaveis podem reduzir essa margem.

### Interpretacao

Este forecast nao representa uma fatura garantida. Ele serve como referencia de planejamento com base na capacidade inicial configurada no Terraform.

O custo real deve ser validado pelo AWS Cost Explorer e, antes de um deploy permanente, pelo AWS Pricing Calculator.

### Limitacoes da Medicao Atual

A coleta runtime de CPU e memoria no EKS esta pendente porque o cluster configurado atualmente nao esta acessivel.

Por isso, o projeto nao apresenta como fatos medidos:

- economia percentual de rightsizing;
- RTO de um novo drill;
- perdas financeiras por incidente;
- economia financeira atribuida a indisponibilidade evitada.

Esses valores devem ser atualizados quando houver nova evidencia reproduzivel.

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
