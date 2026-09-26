# SRE - Definicao Formal de SLI, SLO e SLA

## Servico: donation-service (Caminho Critico / Hot Path)

**Descricao:** O donation-service e o servico responsavel pelo processamento de doacoes financeiras na plataforma SolidaryTech. Por ser o caminho critico do negocio (Hot Path), qualquer indisponibilidade impacta diretamente as ONGs parceiras e seus beneficiarios.

**Nivel de Criticidade:** P0 (Critico) - Impacto direto na receita das ONGs

---

## 1. Service Level Indicators (SLIs)

### SLI 1 - Latencia

| Campo | Valor |
|-------|-------|
| **Descricao** | Proporcao de requisicoes validas de doacao atendidas em menos de 500ms, medida no lado do servidor |
| **Formula** | `count(http_request_duration_seconds_bucket{le="0.5", service="donation-service", status!~"4.."}) / count(http_request_duration_seconds_count{service="donation-service", status!~"4.."})` |
| **Metrica Prometheus** | `http_request_duration_seconds_bucket` |
| **Janela de Medicao** | Rolling window de 30 dias |
| **Fonte de Dados** | Prometheus via OpenTelemetry Collector |

### SLI 2 - Disponibilidade (Taxa de Erros)

| Campo | Valor |
|-------|-------|
| **Descricao** | Proporcao de requisicoes validas de doacao que resultam em resposta de sucesso (non-5xx) |
| **Formula** | `count(http_requests_total{service="donation-service", status!~"5.."}) / count(http_requests_total{service="donation-service"})` |
| **Metrica Prometheus** | `http_requests_total` |
| **Janela de Medicao** | Rolling window de 30 dias |
| **Fonte de Dados** | Prometheus via OpenTelemetry Collector |

---

## 2. Service Level Objectives (SLOs)

| SLO | SLI Associado | Target | Janela |
|-----|---------------|--------|--------|
| **SLO-LATENCIA** | Latencia (SLI 1) | 99.9% das requisicoes < 500ms | 30 dias (rolling) |
| **SLO-DISPONIBILIDADE** | Disponibilidade (SLI 2) | 99.9% de respostas bem-sucedidas | 30 dias (rolling) |

---

## 3. Error Budget

O Error Budget e o complemento do SLO - e a quantidade de "falha permitida" dentro da janela de medicao.

| Metrica | Calculo | Valor |
|---------|---------|-------|
| **Budget Total (30 dias)** | 100% - 99.9% = 0.1% | 0.1% |
| **Tempo de Indisponibilidade Permitido** | 30 dias x 24h x 60min x 0.001 | ~43.2 minutos/mes |
| **Requisicoes com Falha Permitidas** | Assumindo 1M req/mes: 1.000.000 x 0.001 | ~1.000 requisicoes/mes |
| **Violacoes de Latencia Permitidas** | Assumindo 1M req/mes: 1.000.000 x 0.001 | ~1.000 requisicoes > 500ms/mes |

### Politica de Consumo do Error Budget

| Consumo do Budget | Acao |
|-------------------|------|
| < 50% consumido | Operacao normal, deploys liberados |
| 50-75% consumido | Alerta para equipe SRE, revisao de deploys |
| 75-90% consumido | Freeze de features, foco em estabilidade |
| > 90% consumido | Freeze total de deploys, equipe focada em confiabilidade |
| 100% consumido | Incidente ativo, todas as mudancas bloqueadas |

---

## 4. Service Level Agreement (SLA)

O SLA e a garantia contratual oferecida as ONGs parceiras. Deve ser **menos agressivo** que o SLO interno, criando um buffer de protecao.

| Clausula | Valor |
|----------|-------|
| **Disponibilidade Garantida** | 99.5% (uptime mensal) |
| **Latencia Maxima (p95)** | 1 segundo |
| **Tempo Maximo de Indisponibilidade** | ~3.6 horas/mes |
| **Buffer SLO vs SLA** | 0.4% (margem de seguranca) |
| **Janela de Manutencao** | Domingos, 02:00-06:00 UTC (excluido do calculo) |

### Comparativo SLO vs SLA

| Metrica | SLO (Interno) | SLA (Contratual) | Buffer |
|---------|---------------|-------------------|--------|
| Disponibilidade | 99.9% | 99.5% | 0.4% |
| Latencia p99 | 500ms | 1000ms | 500ms |
| Downtime/mes | ~43 min | ~3.6h | ~3h |

---

## 5. Alertas e Burn Rate

### Regras de Alerta Baseadas em Burn Rate

O burn rate mede a velocidade com que o Error Budget esta sendo consumido. Um burn rate de 1x significa que o budget sera totalmente consumido ao final da janela de 30 dias.

| Burn Rate | Severidade | Acao | Notificacao |
|-----------|------------|------|-------------|
| **> 14.4x** (2% budget em 1h) | **Critico (P1)** | Pager do Incident Commander | PagerDuty + Slack #incidents |
| **> 6x** (5% budget em 6h) | **Alto (P2)** | Pager do On-Call SRE | PagerDuty + Slack #sre-alerts |
| **> 3x** (10% budget em 3 dias) | **Medio (P3)** | Ticket automatico | Slack #sre-alerts + Jira |
| **> 1x** (projecao de estouro) | **Baixo (P4)** | Revisao no standup | Slack #sre-weekly |

### Regras Prometheus (PrometheusRule)

```yaml
groups:
  - name: donation-service-slo-alerts
    rules:
      - alert: DonationServiceHighErrorBurnRate
        expr: |
          (
            sum(rate(http_requests_total{service="donation-service",status=~"5.."}[1h]))
            / sum(rate(http_requests_total{service="donation-service"}[1h]))
          ) > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
          service: donation-service
        annotations:
          summary: "Burn rate critico no donation-service"
          description: "Error budget sendo consumido a 14.4x. Budget sera esgotado em ~2 horas."

      - alert: DonationServiceHighLatencyBurnRate
        expr: |
          (
            1 - (
              sum(rate(http_request_duration_seconds_bucket{le="0.5",service="donation-service"}[1h]))
              / sum(rate(http_request_duration_seconds_count{service="donation-service"}[1h]))
            )
          ) > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
          service: donation-service
        annotations:
          summary: "Burn rate de latencia critico no donation-service"
          description: "Latencia p99 degradada. Budget de latencia sera esgotado em ~2 horas."
```

---

## 6. Impacto do DR nos SLOs

Cada evento de failover consome parte do Error Budget:

| Metrica | Valor |
|---------|-------|
| RTO target | 3-5 minutos (teste em lab: 58 segundos) |
| Consumo do Error Budget por failover (estimativa) | 3-5 min / 43.2 min = **7-12%** (teste: 2.2%) |
| Transacoes perdidas por failover | ~4 (in-flight + tentadas) |
| Impacto financeiro estimado | ~R$ 7.100 por evento |
| Failovers permitidos antes de esgotar budget | ~45 eventos/mes (teorico) |

**Nota:** O failback (DR → Producao) e transparente e **nao** consome Error Budget (zero downtime).

---

## 7. Dashboards SRE

A plataforma possui **6 dashboards Grafana**, todos com o panel **"Regiao Ativa"** no canto superior direito (PROD em verde / DR em laranja):

| Dashboard | O que exibe |
|-----------|-------------|
| **Platform Overview** | Request rate, latencia p99, erros, pods, HPA, CPU/memoria |
| **Business Metrics - Doacoes** | Doacoes processadas, total arrecadado (R$), distribuicao por moeda |
| **SRE Golden Metrics** | Latencia (p50/p95/p99), taxa de erros, throughput, saturacao |
| **SLO/SLI Tracking** | SLO compliance 30 dias, error budget restante, burn rate |
| **Infrastructure & Cluster** | Nodes, pods por namespace, HPA status, network I/O |
| **Disaster Recovery - Status** | RTO/RPO, integridade de dados, perda estimada, timeline de failover |

---

## 7. MTTR - Mean Time To Recovery

### Como a Stack de Observabilidade Reduz o MTTR

| Fase do Incidente | Sem Observabilidade | Com Stack SRE | Reducao |
|-------------------|---------------------|---------------|---------|
| **Deteccao** | ~15 min (usuario reporta) | ~1 min (alerta automatico) | 93% |
| **Triagem** | ~20 min (logs manuais) | ~3 min (dashboard + traces) | 85% |
| **Diagnostico** | ~30 min (tentativa e erro) | ~5 min (distributed tracing) | 83% |
| **Resolucao** | ~15 min (deploy manual) | ~5 min (rollback GitOps) | 67% |
| **MTTR Total** | ~80 minutos | ~14 minutos | **82%** |

### Automacoes que Contribuem para Reducao do MTTR

1. **Alertas proativos** - Prometheus detecta anomalias antes do impacto ao usuario
2. **Distributed Tracing** - OpenTelemetry permite rastrear uma doacao por todos os servicos
3. **Dashboards pre-configurados** - SRE Dashboard com Golden Metrics ja filtra o servico em incidente
4. **Rollback via GitOps** - ArgoCD permite reverter o deploy em segundos via `git revert`
5. **Runbooks automatizados** - Documentacao de resposta vinculada aos alertas
