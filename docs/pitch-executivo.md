# SolidaryTech - Pitch Executivo

## Conectando Generosidade a Quem Mais Precisa

---

## O Problema

O Brasil possui mais de **815 mil organizacoes da sociedade civil** (IPEA, 2023). A maioria enfrenta desafios criticos:

- **72%** das ONGs nao possuem infraestrutura digital confiavel para receber doacoes
- Plataformas tradicionais cobram **taxas de ate 15%** sobre cada doacao
- Quando uma campanha viraliza, os sistemas **caem nos momentos de maior engajamento**, desperdicando o pico de generosidade
- Nao ha **rastreabilidade** do impacto: doadores nao sabem se sua contribuicao chegou ao destino
- O matching entre **voluntarios e campanhas** e feito manualmente, com planilhas

**Resultado:** Milhoes de reais em doacoes perdidas e milhares de voluntarios sem direcionamento.

---

## A Solucao: SolidaryTech

A **SolidaryTech** e uma plataforma cloud-native de codigo aberto que conecta **ONGs**, **doadores** e **voluntarios** em um ecossistema integrado, confiavel e global.

### 3 Microsservicos, 1 Missao

| Servico | Funcao | Tecnologia |
|---------|--------|------------|
| **ngo-service** | Cadastro e gestao de ONGs parceiras | Python/Flask + PostgreSQL |
| **donation-service** | Processamento de doacoes (Hot Path) | Python/Flask + SQS + PostgreSQL |
| **volunteer-service** | Matching inteligente entre voluntarios e campanhas | Python/Flask + PostgreSQL |

### Fluxo de uma Doacao

```
Doador acessa    ->  Escolhe ONG  ->  Realiza doacao  ->  Fila SQS (async)
a plataforma         e campanha       (multi-moeda)       processamento

    ->  Gateway de pagamento  ->  Confirmacao  ->  ONG recebe
        (simulado/rebatedor)      em tempo real    notificacao
```

---

## Diferenciais Competitivos

### 1. Disponibilidade de 99.9% (SLA)

A plataforma foi construida sobre principios de **Site Reliability Engineering (SRE)**:

- **SLI de Latencia**: 99.9% das transacoes processadas em menos de 500ms
- **SLI de Disponibilidade**: 99.9% de uptime (apenas ~43 min de indisponibilidade por mes)
- **Error Budget**: politica formal de consumo com alertas automaticos
- **Self-healing**: pods com falha sao automaticamente substituidos pelo Kubernetes

### 2. Doacoes Multi-Moeda

A SolidaryTech e uma **plataforma global**. Aceitamos doacoes em:

| Moeda | Simbolo | Regiao |
|-------|---------|--------|
| Real Brasileiro | BRL | Brasil |
| Dolar Americano | USD | Americas |
| Euro | EUR | Europa |
| Libra Esterlina | GBP | Reino Unido |
| Iene Japones | JPY | Asia |

Todas as transacoes sao convertidas automaticamente e registradas com rastreabilidade completa.

### 3. Disaster Recovery com Integridade de Dados

Se a nuvem cair, as doacoes **continuam**:

- **RTO**: 3-5 minutos para restaurar o servico critico de doacoes (em teste de lab: 58 segundos)
- **RPO = 0 para dados commitados**: sync bidirecional (`dr-data-sync.sh`) preserva todos os dados persistidos
- **Analise honesta**: ~4 transacoes in-flight perdidas durante a janela de failover (~R$ 7.100 de impacto)
- **Warm Standby** sempre ativo em us-west-2 (1 node EKS + RDS + apps com 1 replica)
- **Failback transparente**: `dr-failback.sh` com dual-active transitorio — zero downtime para o cliente na volta
- **Identificacao de regiao**: panel "Regiao Ativa" em todos os 6 dashboards Grafana + endpoint `/region` nos microsservicos
- Health checker automatico (`dr-health-checker.sh --daemon --auto-failover`) dispara failover apos 3 falhas consecutivas

### 4. Custos Otimizados com FinOps

Cada centavo importa quando se trata de uma ONG:

| Recurso | Custo Mensal |
|---------|-------------|
| Infraestrutura completa (EKS + RDS + SQS + S3) | ~$200/mes |
| DR Warm Standby | ~$148/mes |
| **Total** | **~$352/mes** |

Com otimizacoes aplicaveis (Spot Instances, Reserved, scale-down):
- **Economia projetada**: ate 25% (~$88/mes)
- **Custo otimizado**: ~$264/mes para uma plataforma enterprise-grade

### 5. Monitoramento Preditivo (AIOps)

Nao esperamos o problema acontecer - **prevemos**:

- Deteccao de anomalias via Prometheus + regras de ML
- Alertas proativos quando o Error Budget esta sendo consumido rapidamente
- Root Cause Analysis (RCA) automatizado
- Post-Mortem blameless com acoes automaticas
- **AIOps CronJob** executando 8 verificacoes proativas a cada 5 minutos com correcao automatica (CrashLoopBackOff, capacidade, monitoring, ArgoCD, services, health check, AWS resources, namespaces travados)

### 6. Seguranca End-to-End (Hardening Completo)

- Dados criptografados em transito (TLS) e em repouso (AES-256)
- Banco de dados acessivel **somente pela rede interna** (private subnets) com **deletion protection** ativo
- Security Groups com regra de menor privilegio
- Scans automaticos de vulnerabilidades (Trivy SAST/SCA) em cada deploy
- **Containers hardened**: securityContext non-root, readOnlyRootFilesystem, capabilities drop ALL, automountServiceAccountToken desabilitado
- **NetworkPolicies**: deny-all default + regras explicitas por namespace (incluindo monitoring)
- **ECR imutavel**: tags de imagem IMMUTABLE para prevenir supply chain attacks
- **Credenciais protegidas**: mascaramento em logs, variaveis de ambiente (sem exposicao via `ps aux`), `chmod 600` em arquivos de credenciais
- **Validacao de entrada**: paginacao limitada (max 100), validacao de valores monetarios (rejeita NaN/Inf/negativos)
- **EKS**: public_access_cidrs configuravel, audit logs habilitados
- **LGPD-ready**: dados de doadores protegidos conforme legislacao brasileira

---

## Arquitetura de Alta Disponibilidade

```
                    Internet
                       |
                  [ AWS WAF ]
                       |
                [ Load Balancer ]  (porta 443/HTTPS apenas)
                       |
            ┌──────────┼──────────┐
            |          |          |
        [NGO API]  [Donation]  [Volunteer]    <- EKS (Private Subnets)
            |      API + Worker   |
            |          |          |
            └──────┬───┘──────────┘
                   |
            ┌──────┼──────┐
            |      |      |
         [RDS]   [SQS]  [S3]                  <- Servicos Gerenciados
         (Private) (Multi-AZ) (Versioned)

     Monitoramento: Prometheus + Grafana + Loki + OpenTelemetry
     GitOps: ArgoCD (App of Apps) <- GitHub Actions CI/CD
     IaC: Terraform (8 modulos, tags FinOps obrigatorias)
```

---

## ROI - Retorno sobre Investimento

### Comparacao com Solucoes Tradicionais

| Aspecto | Solucao Tradicional | SolidaryTech |
|---------|--------------------:|-------------:|
| Custo mensal de infraestrutura | $2.000 - $5.000 | **$352** |
| Taxas por transacao | 5% - 15% | **0%** (open-source) |
| Tempo de recuperacao (desastre) | 4-24 horas | **3-5 minutos** (teste: 58s) |
| Monitoramento | Manual/reativo | **Automatico/preditivo** |
| Escalabilidade | Semanas para provisionar | **Minutos (auto-scaling)** |
| Vendor lock-in | Alto | **Nenhum (OSS + multi-cloud ready)** |

### Cenario: ONG com 10.000 doacoes/mes (ticket medio R$50)

- **Volume mensal**: R$500.000 em doacoes
- **Economia em taxas** (vs plataforma com 10%): **R$50.000/mes**
- **Custo da infraestrutura**: ~R$1.800/mes
- **ROI liquido mensal**: **R$48.200**

---

## Escalabilidade

A plataforma foi projetada para escalar automaticamente:

- **HPA (Horizontal Pod Autoscaler)**: donation-service (Hot Path) escala de 1 a 4 replicas; ngo-service e volunteer-service de 1 a 3 replicas (calibrados para capacidade do t3.medium: 17 pods/node)
- **Node Autoscaler**: adiciona nodes ao EKS quando necessario (1 a 3 nodes no Academy; 1 a 5 em producao real)
- **SQS**: filas decoupled absorvem picos sem impactar o usuario
- **Testado para**: campanhas virais com 10x o trafego normal

### Cenario: Black Friday Solidaria

Uma campanha viraliza no Instagram. O trafego sobe 10x em 30 minutos:

1. HPA detecta aumento de CPU (>60% no donation-service) e cria replicas adicionais (ate maxReplicas=4)
2. Node autoscaler provisiona novos nodes via API EKS (t3.medium)
3. SQS absorve o burst de doacoes, processando de forma assincrona
4. Doadores nao percebem nenhuma lentidao
5. Apos o pico, o sistema escala de volta automaticamente (economia de custos)

---

## Modelo de Sustentabilidade

A SolidaryTech e uma iniciativa sem fins lucrativos:

- **Zero taxas** sobre doacoes - 100% do valor chega as ONGs
- **Codigo aberto** - qualquer organizacao pode auditar e contribuir
- **Custos sustentados** por:
  - Parcerias com empresas de tecnologia (AWS Credits for Nonprofits)
  - Grants de fundacoes internacionais
  - Programa de voluntariado corporativo (empresas cedem engenheiros)

---

## Conformidade e Governanca

| Requisito | Status |
|-----------|--------|
| LGPD (Lei Geral de Protecao de Dados) | Implementado |
| Criptografia em transito e repouso | Implementado |
| Auditoria de acessos | Implementado (CloudTrail) |
| Backup e retencao de dados | 7 dias automatico + DR |
| Segregacao de ambientes | Produccao / DR separados |
| Gestao de segredos | Kubernetes Secrets + rotation |

---

## Equipe

Consulte o documento de entrega do projeto (PDF) para a lista completa de integrantes.

---

## Conclusao

A SolidaryTech nao e apenas uma plataforma de tecnologia - e um **acelerador de impacto social**. Com uma infraestrutura que custa menos que um aluguel de escritorio, conseguimos:

- Garantir que **100% das doacoes** cheguem as ONGs
- Operar com **99.9% de disponibilidade** mesmo em momentos criticos
- Recuperar de desastres em **menos de 5 minutos** com integridade de dados (teste em lab: 58s)
- Escalar para atender **qualquer volume** de generosidade

**Cada linha de codigo, cada regra de monitoramento, cada decisao arquitetural foi feita pensando em uma coisa: que nenhuma doacao se perca.**

---

*"A tecnologia a servico de quem mais precisa."*
