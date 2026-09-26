# Decisoes Tecnicas e Arquiteturais

## SolidaryTech - Justificativa das Escolhas de Arquitetura

---

## 1. EKS vs ECS - Orquestracao de Containers

**Decisao:** Amazon EKS (Elastic Kubernetes Service)

| Criterio | EKS (Kubernetes) | ECS |
|----------|------------------|-----|
| Portabilidade | Multi-cloud (AKS, GKE) | AWS-only |
| Ecossistema | Prometheus, ArgoCD, Helm, etc | Limitado |
| GitOps | ArgoCD nativo | Workaround necessario |
| Comunidade | Enorme, CNCF | Menor |
| Curva de aprendizado | Maior | Menor |
| Custo control plane | $73/mes | Gratuito |

**Justificativa:** Apesar do custo adicional do control plane, o EKS oferece portabilidade multi-cloud (essencial para DR em outro provider no futuro), ecossistema rico para observabilidade (Prometheus, Grafana, OTel) e suporte nativo a GitOps via ArgoCD. Para uma ONG que precisa de resiliencia, a portabilidade e um seguro contra vendor lock-in.

---

## 2. Python/Flask - Linguagem Unificada dos Microsservicos

**Decisao:** Python 3.13 (Flask) para todos os 3 microsservicos

| Criterio | Python/Flask | Node.js | Java/Spring |
|----------|-------------|---------|-------------|
| Velocidade de desenvolvimento | Rapido | Rapido | Lento |
| Ecossistema ML/AI | Rico (AIOps) | Limitado | Moderado |
| Ecossistema AWS | boto3 nativo | AWS SDK | AWS SDK |
| Instrumentacao (OTel) | Excelente | Boa | Excelente |
| Stack unificada | 1 linguagem, 1 runtime | 1 linguagem | 1 linguagem |

**Justificativa:** Python foi escolhido como linguagem **unica** por 3 motivos: (1) produtividade — ecossistema rico com SQLAlchemy, boto3, OpenTelemetry e Flask permite entregar funcionalidades rapidamente; (2) stack homogenea — todos os microsservicos compartilham o mesmo runtime, Dockerfile, dependencias e padroes de codigo, reduzindo a carga operacional; (3) alinhamento academico — Python e a linguagem principal do curriculo da FIAP, garantindo que toda a equipe pode contribuir em qualquer servico. O donation-service, apesar de ser Hot Path, escala horizontalmente via HPA e processa assincronamente via SQS, compensando a performance individual.

---

## 3. PostgreSQL - Banco de Dados

**Decisao:** PostgreSQL 15 via Amazon RDS

| Criterio | PostgreSQL | DynamoDB | Aurora |
|----------|-----------|----------|--------|
| Custo (micro) | ~$15/mes | Pay-per-request | ~$60/mes |
| SQL/Relacional | Nativo | Nao | Nativo |
| Transacoes ACID | Sim | Limitado | Sim |
| Read Replicas | Sim | Global Tables | Sim |
| AWS Academy suporte | Sim | Sim | Limitado |

**Justificativa:** Os dados da SolidaryTech sao inerentemente relacionais (ONGs tem doacoes, campanhas tem voluntarios). PostgreSQL oferece transacoes ACID criticas para processamento financeiro, suporte a Read Replicas para DR, e e o banco mais custo-efetivo no tier t3.micro. DynamoDB seria mais adequado para logs de auditoria e cache, podendo ser adicionado como evolucao futura.

**Evolucao planejada:**
- **Redis (ElastiCache)**: cache de sessoes e rate limiting para o donation-service
- **DynamoDB**: audit log imutavel de todas as transacoes de doacao

---

## 4. SQS - Processamento Assincrono de Doacoes

**Decisao:** Amazon SQS com Dead Letter Queue (DLQ)

```
[Doador] -> [donation-service API] -> [SQS Queue] -> [donation-worker]
                                           |
                                    (falha 3x)
                                           |
                                      [SQS DLQ] -> Alerta + Investigacao
```

| Criterio | SQS | RabbitMQ (self-hosted) | SNS+SQS |
|----------|-----|-----------------------|---------|
| Gerenciamento | AWS Managed | Self-hosted | AWS Managed |
| Custo | ~$0.40/mes | Node dedicado | ~$0.40/mes |
| Confiabilidade | 99.999999999% | Depende do setup | 99.999999999% |
| DLQ nativa | Sim | Plugin | Sim |
| At-least-once delivery | Sim | Configuravel | Sim |

**Justificativa:** O Hot Path de doacoes exige **desacoplamento** entre o recebimento (sincrono, resposta rapida ao doador) e o processamento (assincrono, pode demorar). SQS garante que nenhuma doacao se perca, mesmo que o worker esteja temporariamente indisponivel. A DLQ captura transacoes que falharam 3x para investigacao manual, garantindo zero perda de dados.

---

## 5. Warm Standby vs Cold DR vs Active-Active - Estrategia de DR

**Decisao:** Warm Standby (Ativo-Passivo) com workload minimo **sempre ativo** em us-west-2

### Por que nao Cold DR (provisionar sob demanda)?

O modelo Cold DR (infraestrutura criada apenas quando necessario) foi descartado por 3 motivos:

1. **RTO de 30+ minutos e inaceitavel**: Provisionar EKS (15 min), RDS (10 min), configurar apps (5 min) demora demais. Cada minuto de downtime no donation-service impacta ONGs e doadores.

2. **Fragilidade operacional**: O failover depende de Terraform + AWS CLI + configuracao manual. No ambiente AWS Academy, o Terraform destroy ja falhou silenciosamente — o mesmo pode acontecer no provisionamento de emergencia, justamente quando mais importa.

3. **RPO ruim**: Sem Read Replica ativa, o RPO depende de backups (1h) ou snapshots. Com Read Replica, o RPO cai para ~1 segundo.

### Por que nao Active-Active?

| Criterio | Warm Standby | Active-Active |
|----------|-------------|---------------|
| Custo mensal adicional | ~$148/mes | ~$400/mes |
| RTO | 3-5 min | ~0 min |
| Complexidade | Moderada | Alta (replicacao bidirecional) |
| Consistencia de dados | Async (RPO ~1s) | Sync (requer multi-master) |

Active-Active exigiria replicacao bidirecional do PostgreSQL (multi-master), resolucao de conflitos de escrita, e roteamento DNS inteligente — complexidade que nao se justifica para o volume atual da SolidaryTech.

### Decisao: Warm Standby com workload minimo

| Criterio | Cold DR | **Warm Standby** | Active-Active |
|----------|---------|-------------------|---------------|
| RTO | 30-45 min | **3-5 min** | ~0 min |
| RPO (commitados) | 1 hora (backup) | **0** (sync bidirecional) | ~0 |
| RPO (in-transit) | 1 hora | **RTO window** (~4 transacoes) | ~0 |
| Custo adicional/mes | $0 | **$148** | $400 |
| Confiabilidade do failover | Baixa | **Alta** | Muito alta |
| Complexidade operacional | Baixa | **Moderada** | Alta |

**O Warm Standby e o ponto ideal**: RTO de 3-5 minutos por um custo 63% menor que Active-Active, com confiabilidade muito superior ao Cold DR. Em teste de lab, o RTO medido foi de **58 segundos**.

O ambiente DR mantem:
- EKS com 1 node e apps rodando com 1 replica (workload minimo)
- RDS Read Replica cross-region com sync continuo (RPO ~1s)
- SQS independente pre-criada
- Stack de monitoramento ativa

No failover, basta: promover a Read Replica + reiniciar pods + escalar nodes.

Os scripts `scripts/dr-failover.sh`, `scripts/dr-failback.sh` e `scripts/dr-data-sync.sh` automatizam o processo completo incluindo sincronizacao bidirecional de dados.

**Quando migrar para Active-Active:** Se a SolidaryTech crescer para processar >100k doacoes/dia, o custo de 3-5 min de downtime e ~4 transacoes perdidas por failover superara o custo adicional de Active-Active.

---

## 6. ArgoCD vs FluxCD - GitOps

**Decisao:** ArgoCD com padrao App of Apps

| Criterio | ArgoCD | FluxCD |
|----------|--------|--------|
| Interface Web | Rica, visual | Nenhuma (CLI only) |
| App of Apps | Nativo | Kustomization |
| RBAC | Granular | Basic |
| Self-heal | Nativo | Configuravel |
| Comunidade CNCF | Graduated | Graduated |
| Visibilidade | Alta (UI mostra diff) | Baixa |

**Justificativa:** ArgoCD foi escolhido pela **interface visual** (critica para demonstracoes e auditorias), pelo padrao **App of Apps** (gerencia N aplicacoes de um unico ponto), pelo **self-heal** nativo (reverte mudancas manuais no cluster) e pelo RBAC granular. Para o hackathon, a capacidade de visualizar o estado de sincronizacao em tempo real e um diferencial importante.

### Configuracao App of Apps

```
ArgoCD Project: solidarytech
    |
    ├── Application: ngo-service         -> kubernetes/base/ngo-service/
    ├── Application: donation-service    -> kubernetes/base/donation-service/
    ├── Application: volunteer-service   -> kubernetes/base/volunteer-service/
    └── Application: monitoring-stack    -> kubernetes/monitoring/
```

---

## 7. Prometheus + Grafana vs Datadog/New Relic - Observabilidade

**Decisao:** Stack open-source (Prometheus + Grafana + Loki + OpenTelemetry)

| Criterio | Prometheus + Grafana | Datadog | New Relic |
|----------|---------------------|---------|-----------|
| Custo | Gratuito (OSS) | $15/host/mes | Free tier limitado |
| Vendor lock-in | Nenhum | Alto | Alto |
| AWS Academy | Funciona | Requer conta externa | Requer conta externa |
| Customizacao | Total | Limitada | Limitada |
| Integracao K8s | Nativa | Agent-based | Agent-based |
| AIOps nativo | Via regras/ML | Watchdog | Applied Intelligence |

**Justificativa:** Stack open-source e a unica opcao viavel para o AWS Academy (sem custos extras ou contas externas). Prometheus e o padrao de facto para metricas em Kubernetes, Grafana permite dashboards customizados para SRE (Golden Metrics, SLO, Error Budget), e Loki complementa com logs. A instrumentacao via OpenTelemetry e vendor-neutral, permitindo migrar para Datadog/New Relic no futuro sem mudar o codigo.

---

## 8. Arquitetura de Rede - Seguranca por Design

**Decisao:** Segregacao rigorosa com subnets publicas e privadas

```
VPC 10.0.0.0/16
├── Public Subnets (10.0.1.0/24, 10.0.2.0/24)
│   ├── Internet Gateway
│   ├── NAT Gateway
│   └── Load Balancer (porta 443 apenas)
│
└── Private Subnets (10.0.10.0/24, 10.0.20.0/24)
    ├── EKS Worker Nodes
    ├── RDS PostgreSQL (porta 5432, acessivel SOMENTE dos nodes EKS)
    └── Pods dos microsservicos
```

### Security Groups

| Recurso | Regras de Entrada | Justificativa |
|---------|-------------------|---------------|
| Load Balancer | 443 (HTTPS) de 0.0.0.0/0 | Unico ponto de entrada publico |
| EKS Nodes | Apenas do LB e entre si | Comunicacao interna somente |
| RDS | 5432 apenas do SG dos EKS Nodes | Banco NUNCA acessivel da internet |

### Seguranca nos Pods

```yaml
securityContext:
  runAsNonRoot: true      # Nunca rodar como root
  readOnlyRootFilesystem: true  # Filesystem somente leitura
  allowPrivilegeEscalation: false  # Sem escalacao de privilegios
```

**Justificativa:** O principio de **menor privilegio** e aplicado em todas as camadas. O banco de dados e acessivel somente pela rede interna, os containers rodam sem privilegios root, e o unico ponto de entrada e o Load Balancer na porta 443 (HTTPS). Isso minimiza a superficie de ataque e atende requisitos de conformidade LGPD.

---

## 9. Auto-Scaling e Resiliencia a Carga

**Decisao:** Escalabilidade automatica em 3 camadas (Pod, Node, DR)

### Camada 1: Pod Auto-Scaling (HPA)

| Servico | Min | Max | CPU Target | Memory Target | Scale-Up | Scale-Down |
|---------|-----|-----|------------|---------------|----------|------------|
| donation-service (Hot Path) | 1 | **4** | 60% | 75% | 4 pods/30s | 1 pod/60s (stab 300s) |
| donation-worker | 1 | 4 | 70% | 80% | padrao | padrao (escalado a 0 no Academy) |
| ngo-service | 1 | **3** | 70% | 80% | 2 pods/60s | 1 pod/60s (stab 180s) |
| volunteer-service | 1 | **3** | 70% | 80% | 2 pods/60s | 1 pod/60s (stab 180s) |

**Justificativa dos maxReplicas (calibrados para capacidade t3.medium):**

O t3.medium suporta no maximo **17 pods por node** (limitacao ENI do AWS VPC CNI). Com 2 nodes = **34 slots totais**.

Pods fixos do sistema (nao escalaveis):

| Componente | Pods | Tipo |
|------------|------|------|
| CoreDNS | 2 | Deployment (HA obrigatorio — DNS do cluster) |
| kube-proxy | 2 | DaemonSet (1 por node) |
| aws-node (VPC CNI) | 2 | DaemonSet (1 por node) |
| metrics-server | 1 | Deployment |
| ArgoCD (server, repo, redis, dex, controller, notifications, appset) | 7 | StatefulSet + Deployments |
| Prometheus | 1 | Deployment |
| AlertManager | 1 | Deployment |
| Grafana | 1 | Deployment |
| Loki | 1 | Deployment |
| Promtail | 2 | DaemonSet (1 por node) |
| OTel Collector | 2 | DaemonSet (1 por node) |
| SelfHealing Handler | 1 | Deployment |
| **Total fixo** | **~23-24** | |

**Slots restantes para aplicacoes: ~10-11**

Pior caso com todos os HPAs no maximo: 4 (donation) + 3 (ngo) + 3 (volunteer) + 0 (worker no Academy) = **10 pods de app**. Total: 24 + 10 = **34 pods = capacidade exata dos 2 nodes**.

O donation-service recebe maxReplicas=4 (maior que os demais) porque e o Hot Path — processa transacoes financeiras com writes no RDS, publish no SQS e cache no Redis. Os servicos ngo e volunteer sao predominantemente leitura e recebem maxReplicas=3. O donation-worker esta escalado a 0 no Academy (LabEksNodeRole sem `sqs:ReceiveMessage`), mas em producao real competiria pelos mesmos slots.

O threshold de CPU do donation-service e mais baixo (60% vs 70%) para escalar **antes** de saturar, garantindo latencia baixa em transacoes financeiras. O scale-down e conservador (stabilization de 300s) para evitar flapping.

### Camada 2: Node Auto-Scaling

No Academy, o Cluster Autoscaler (v1.32.0) esta deployado mas **inoperante** por restricao IAM. O workaround e o script `node-autoscaler.sh`:

```
Pods Pending (sem recursos) -> node-autoscaler.sh detecta
    -> eks:UpdateNodegroupConfig (desired +1) -> Node provisionado ~3-5 min
    -> IMDS hop limit corrigido automaticamente -> Pods agendados no novo node
```

| Componente | Versao | Funcao |
|------------|--------|--------|
| Metrics Server | v0.7.2 | Fornece metricas de CPU/memoria para o HPA |
| node-autoscaler.sh | — | Escala nodes via API EKS quando pods ficam Pending (workaround Academy) |
| Cluster Autoscaler | v1.32.0 | Deployado mas inoperante no Academy (sem `autoscaling:DescribeAutoScalingGroups`) |

**Configuracao do node-autoscaler.sh:**
- `CHECK_INTERVAL=30` — verifica a cada 30 segundos
- `MIN_NODES=1` — minimo de 1 node (scale down nao vai abaixo)
- `MAX_NODES=3` — maximo de 3 nodes (Academy permite max 9 EC2 total, reservando slots para DR)
- `SCALE_DOWN_DELAY=120` — cooldown de 2 min antes de scale down
- IMDS hop limit corrigido automaticamente em novos nodes

**Em producao real:** Cluster Autoscaler opera nativamente com IAM Role dedicada (IRSA) — max 5 nodes, auto-discovery via tags ASG.

### Camada 3: DR Automatico (Health Checker)

```
dr-health-checker.sh --daemon --auto-failover
    |
    ├── Check 1: EKS cluster status (ACTIVE?)
    ├── Check 2: Nodes Ready (>0?)
    └── Check 3: RDS primary (available?)
         |
    3 falhas consecutivas -> FAILOVER AUTOMATICO
         |
         ├── Promover RDS Read Replica -> standalone
         ├── Atualizar secrets com endpoint DR
         ├── Rollout restart pods
         └── Escalar nodes DR para producao
```

| Parametro | Valor | Justificativa |
|-----------|-------|---------------|
| Intervalo de check | 60s | Balanco entre deteccao rapida e custo de API |
| Threshold de falha | 3 consecutivas | Evita falsos positivos por instabilidade momentanea |
| Tempo ate failover | ~3 min (3x60s) + ~2 min (execucao) = **~5 min** | Dentro do RTO target |
| Modo dry-run | `--dry-run` | Para testes sem impacto |
| Safety gate | `--auto-failover` obrigatorio | Previne failover acidental |

**Justificativa:** O failover manual (digitar "FAILOVER") tinha RTO imprevisivel — dependia de um operador humano detectar o problema, logar na maquina e executar o script. Com o health checker automatico, o RTO e previsivel (~5 min) e independe de intervencao humana. Em teste de DR drill no lab, o RTO medido foi de 58 segundos. O safety gate `--auto-failover` garante que ninguem ative o failover automatico por acidente.

---

## 10. Limitacoes do AWS Academy Learner Lab e Mitigacoes

O AWS Academy Learner Lab impoe restricoes de IAM e recursos que impactam algumas funcionalidades. Todas foram identificadas, documentadas e mitigadas com solucoes alternativas.

### 10.1. Restricoes Identificadas

| Restricao | Impacto | Mitigacao |
|-----------|---------|-----------|
| Criacao de IAM Roles proibida | Cluster Autoscaler e IRSA nao funcionam | Node scaling via `aws eks update-nodegroup-config` |
| LabEksNodeRole sem `autoscaling:DescribeAutoScalingGroups` | Cluster Autoscaler nao consegue descobrir/escalar ASGs | HPA funciona normalmente; nodes escalados via CLI |
| LabEksNodeRole sem `sqs:ReceiveMessage` | donation-worker nao consegue consumir da fila SQS | Worker escalado a 0 replicas; doacoes processadas sincronamente |
| Max 9 instancias EC2 | Limita capacidade total de nodes | Producao: max 5 nodes, DR: max 2 nodes, 2 reservados |
| IMDS hop limit padrao = 1 | Pods nao acessam credenciais AWS via instance metadata | Atualizado para hop limit 2 via `modify-instance-metadata-options` |
| Budget de $50 | Limita tempo de execucao e tamanho de instancias | t3.medium para nodes, t3.micro para RDS, scripts de stop/start |
| Sem Object Lock no S3 | Backup imutavel (WORM) nao disponivel | Versionamento habilitado como alternativa |
| Sem `rds:CreateDBInstanceReadReplica` | Read Replica cross-region bloqueada | RDS standalone no DR; replicacao manual |
| EKS Managed Node Group cria SG proprio | Pods usam SG diferente do configurado no Terraform | Modulo RDS aceita ambos os SGs (node + cluster) |

### 10.2. Cluster Autoscaler vs AWS Academy

O Cluster Autoscaler (v1.32.0) esta configurado e deployado mas **nao opera** no AWS Academy por duas restricoes cumulativas:

1. **IMDS hop limit** (corrigido): EKS cria instancias com hop limit 1, impedindo pods de acessar instance metadata. Corrigido via:
   ```bash
   aws ec2 modify-instance-metadata-options --instance-id <id> --http-put-response-hop-limit 2
   ```

2. **IAM permissions** (nao contornavel): O LabEksNodeRole nao tem permissao `autoscaling:DescribeAutoScalingGroups`, necessaria para o CA descobrir os Auto Scaling Groups. Como nao podemos criar/modificar IAM roles no Academy, o CA fica inoperante.

**Mitigacao aplicada:** Script `node-autoscaler.sh` que simula o Cluster Autoscaler usando a API do EKS (permitida no Academy) em vez da API do Auto Scaling Group (bloqueada).

**Como funciona o workaround:**

O Cluster Autoscaler oficial usa a API `autoscaling:SetDesiredCapacity` para adicionar/remover nodes. O `LabEksNodeRole` bloqueia essa API, mas permite `eks:UpdateNodegroupConfig`, que faz a mesma coisa por outro caminho.

```
┌─────────────────────────────────────────────────────────┐
│  Cluster Autoscaler (oficial)     ← BLOQUEADO           │
│  autoscaling:DescribeAutoScalingGroups                   │
│  autoscaling:SetDesiredCapacity                          │
├─────────────────────────────────────────────────────────┤
│  node-autoscaler.sh (workaround)  ← FUNCIONAL           │
│  eks:DescribeNodegroup (verificar desired atual)         │
│  eks:UpdateNodegroupConfig (alterar desired)             │
│  ec2:ModifyInstanceMetadataOptions (fix IMDS hop limit)  │
└─────────────────────────────────────────────────────────┘
```

**Logica do script (loop a cada 30s):**

| Condicao | Acao | Detalhe |
|----------|------|---------|
| Pods Pending > 0 ou capacidade > 85% | **SCALE UP** | Incrementa desired em +1 (max 3 nodes) |
| 0 pods Pending e capacidade < 40% | **SCALE DOWN** | Decrementa desired em -1 (min 1 node), com cooldown de 2 min |
| Novo node adicionado | **Fix IMDS** | Ajusta hop limit para 2 em todos os nodes para que pods acessem credenciais IAM |

**Fluxo completo de auto-scaling:**

```
Carga sobe → HPA cria pods → Pods ficam Pending (node cheio)
                                    ↓
                        node-autoscaler.sh detecta
                                    ↓
                    eks:UpdateNodegroupConfig (desired +1)
                                    ↓
                  Novo node sobe (~3-5 min) + IMDS fix
                                    ↓
               Pods Pending agendam no novo node
                                    ↓
         Carga normaliza → Cooldown → Scale down
```

**Como executar (4 terminais):**

```bash
# Terminal 1 — Node Autoscaler (manter rodando)
bash scripts/node-autoscaler.sh

# Terminal 2 — Port-forwards dos servicos (porta 8083 evita conflito com ArgoCD na 8080)
kubectl port-forward svc/ngo-service -n solidarytech 8083:8080 &
kubectl port-forward svc/donation-service -n solidarytech 8081:8081 &
kubectl port-forward svc/volunteer-service -n solidarytech 8082:8082 &

# Terminal 3 — Load test (seed + rampa progressiva)
NGO_URL=http://localhost:8083 bash scripts/load-test.sh all

# Terminal 4 — Grafana (observar dashboards em tempo real)
kubectl port-forward svc/grafana 3000:3000 -n monitoring
# Abrir http://localhost:3000
```

**O que observar no Grafana durante o teste:**

| Dashboard | O que mostra |
|-----------|-------------|
| Platform Overview | Throughput subindo, pods escalando, CPU aumentando |
| Business Metrics | Doacoes sendo processadas em 5 moedas, volume crescendo |
| Infrastructure & Cluster | Novo node aparecendo, HPA current vs max, pods por namespace |
| SRE Golden Metrics | Latencia P99, error rate, SLO compliance |
| SLO/SLI Tracking | Error budget burn rate reagindo a carga |

**Parametros configuraveis via variavel de ambiente:**

```bash
CHECK_INTERVAL=30    # Intervalo de verificacao (segundos)
MIN_NODES=1          # Minimo de nodes (scale down nao vai abaixo)
MAX_NODES=3          # Maximo de nodes (scale up nao vai acima)
SCALE_DOWN_DELAY=120 # Cooldown antes de scale down (segundos)
```

**Em producao real:** O Cluster Autoscaler funcionaria normalmente com uma IAM Role dedicada (via IRSA) contendo as permissoes necessarias (`autoscaling:*`, `ec2:Describe*`). O `node-autoscaler.sh` nao seria necessario.

### 10.3. SQS Worker vs AWS Academy

O donation-worker consome mensagens da fila SQS via `boto3.receive_message()`. No Academy, o LabEksNodeRole nao tem permissao `sqs:ReceiveMessage`, causando `AccessDenied`.

**Importante:** O SQS em si **funciona** no Academy — o donation-service consegue **enviar** mensagens para a fila via `sqs:SendMessage` (confirmado em testes). O problema e apenas no **recebimento** pelo worker pod, pois o LabEksNodeRole nao tem `sqs:ReceiveMessage`.

**Mitigacao aplicada:**
- Worker escalado a 0 replicas automaticamente no `deploy.sh` (linha 315)
- As doacoes sao criadas **sincronamente** pelo donation-service API (gravam no PostgreSQL + enviam para SQS + escrevem audit log no DynamoDB)
- O fluxo assincrono (API -> SQS -> Worker -> processamento) esta **100% implementado** no codigo e funciona em ambientes com IAM completo

**Em producao real:** Bastaria atribuir uma IAM Role com `sqs:ReceiveMessage` ao worker pod (via IRSA ou node role) e escalar o worker para 1+ replicas.

### 10.4. Security Group do RDS e EKS Managed Node Groups

O EKS Managed Node Groups cria dois Security Groups distintos: (1) o SG customizado definido no Terraform (`eks-node-sg`) e (2) o SG gerenciado automaticamente pelo EKS (`eks-cluster-sg-*`). Os pods herdam o SG gerenciado pelo EKS, nao o customizado.

**Problema:** O modulo RDS originalmente criava uma regra de ingress referenciando apenas o SG customizado. Os pods nao conseguiam conectar ao RDS (timeout na porta 5432).

**Solucao aplicada:** O modulo RDS agora recebe ambos os SGs (`eks_node_sg_id` e `eks_cluster_sg_id`) e cria regras de ingress para os dois. O `eks_cluster_sg_id` e obtido via `aws_eks_cluster.main.vpc_config[0].cluster_security_group_id`, que e o SG que o EKS atribui automaticamente aos pods.

### 10.5. RDS Read Replica Cross-Region (DR)

**Restricao:** O IAM do AWS Academy (LabRole/voclabs) nao possui a permissao `rds:CreateDBInstanceReadReplica`, impedindo a criacao de Read Replicas cross-region (us-east-1 -> us-west-2).

**Impacto no DR:** A arquitetura original previa um RDS Read Replica em us-west-2 sincronizando continuamente com a producao (RPO ~1 segundo). Sem essa permissao, a replicacao automatica nao e possivel.

**Mitigacao aplicada:** O DR cria um RDS standalone independente em us-west-2 com as mesmas credenciais e schema. Isso permite:
- Validar todo o fluxo de failover (promover banco, reiniciar pods, escalar nodes)
- Demonstrar a arquitetura de DR completa (EKS + RDS + SQS em regiao separada)
- Testar o `dr-failover.sh` e o `dr-health-checker.sh` end-to-end

**Limitacao:** Sem replicacao automatica, os dados entre producao e DR nao sao sincronizados em tempo real. O RPO efetivo depende da ultima sincronizacao manual (backup/restore).

**Em producao real com IAM completo:**
```hcl
module "rds" {
  # ...
  is_read_replica = true
  source_db_arn   = data.terraform_remote_state.production.outputs.rds_arn
}
```
O RDS Read Replica sincroniza continuamente com a producao via replicacao nativa do PostgreSQL, alcancando RPO de ~1 segundo e failover via `aws rds promote-read-replica`.

| Aspecto | AWS Academy (atual) | Producao Real |
|---------|--------------------:|-------------:|
| Tipo RDS DR | Standalone independente | Read Replica cross-region |
| Replicacao | Manual (backup/restore) | Automatica e continua |
| RPO | Depende do ultimo backup | ~1 segundo |
| Failover RDS | Ja independente | `promote-read-replica` |
| Custo adicional | Igual | Igual (replica mesmo preco) |

### 10.6. Limites de Pods por Node (t3.medium)

O t3.medium suporta no maximo **17 pods** por node (limitacao do AWS VPC CNI baseada no numero de ENIs). Com o stack completo (ArgoCD, monitoring, system pods), o no satura rapidamente.

| Componente | Pods Tipicos | Detalhes |
|------------|-------------|----------|
| kube-system (aws-node, kube-proxy, coredns, metrics-server) | 7 | 2 DaemonSets (2 cada) + 2 CoreDNS + 1 metrics-server |
| argocd (server, repo, redis, dex, controller, notifications, appset) | 7 | GitOps controller, UI, cache, auth |
| monitoring (prometheus, grafana, loki, alertmanager, otel, promtail, selfhealing) | 10 | 4 Deployments + 2 DaemonSets (2 cada) + handler |
| solidarytech (donation, ngo, volunteer) | 3-10 | Min 3 (1 cada), max 10 (4+3+3) com HPA |
| **Total** | **27-34** | 2 nodes x 17 pods = 34 slots |

Com 2 nodes = 34 slots disponiveis. Os HPAs foram calibrados (donation max 4, ngo/volunteer max 3) para nunca exceder essa capacidade. Com 3+ nodes (via node-autoscaler.sh), ha folga para scale-up completo.

**Gestao operacional de capacidade:**
- O `deploy.sh` executa `clean_orphans()` em ambas regioes antes de provisionar, removendo recursos orfaos (EKS em FAILED, subnet groups, parameter groups) que impediriam novo deploy
- O `destroy.sh` usa polling (nao sleep fixo) para aguardar exclusao de ElastiCache e NAT Gateways, e executa `verify_clean()` como fase final de verificacao em ambas regioes
- O AIOps CronJob (`aiops-remediation.sh`) monitora capacidade a cada 5 minutos e reduz HPAs automaticamente se pods ficarem Pending por limite de nodes

---

## 11. Security Hardening — Defesa em Profundidade

**Decisao:** Aplicar hardening em todas as camadas (scripts, Terraform, Kubernetes, aplicacao)

A auditoria de seguranca identificou e corrigiu vulnerabilidades em 4 camadas:

### 11.1. Camada de Scripts (deploy.sh, destroy.sh)

| Vulnerabilidade | Correcao |
|-----------------|----------|
| Senha do banco visivel via `ps aux` (`-var=password`) | Credenciais passadas via `export TF_VAR_*` (variaveis de ambiente) |
| Validacao de senha com `echo \| grep` (expoe em /proc) | Validacao com `[[ =~ ]]` (built-in bash, sem subprocesso) |
| Credenciais impressas no stdout | Salvas em arquivo com `chmod 600`, nunca no log |
| Variaveis sensiveis permanecem no ambiente | `unset TF_VAR_db_password TF_VAR_db_username` apos uso |
| Output do ECR describe-repositories expoe ARNs | Redirecionado para `&>/dev/null` |

### 11.2. Camada de Infraestrutura (Terraform)

| Recurso | Hardening Aplicado |
|---------|-------------------|
| RDS | `deletion_protection = true`, `skip_final_snapshot = false` |
| ECR | `image_tag_mutability = IMMUTABLE` (previne supply chain attacks) |
| EKS | `public_access_cidrs` configuravel, audit logs habilitados (`api`, `audit`, `authenticator`) |
| S3 (state) | `put-public-access-block` com todos os bloqueios ativos |

### 11.3. Camada de Kubernetes

| Recurso | Hardening Aplicado |
|---------|-------------------|
| Pods de aplicacao | `securityContext: runAsNonRoot, allowPrivilegeEscalation: false, capabilities: drop: [ALL]` |
| Pods de aplicacao | `automountServiceAccountToken: false` |
| Prometheus | `readOnlyRootFilesystem: true`, UID 65534 |
| Grafana | UID 472, senha admin via `secretKeyRef` (nao hardcoded) |
| AlertManager, Loki | securityContext com UID dedicado, drop ALL |
| Monitoring namespace | NetworkPolicies: deny-all default + allow internal + allow app->prometheus |

### 11.4. Camada de Aplicacao (Python/Flask)

| Vulnerabilidade | Correcao |
|-----------------|----------|
| DATABASE_URL hardcoded com `postgres:postgres` | `RuntimeError` se variavel nao definida |
| Paginacao sem limite (DoS via `per_page=999999`) | `per_page = min(request.args.get(...), 100)` |
| Valores monetarios sem validacao | Rejeita `<= 0`, `NaN`, `Inf` no donation-service |
| Atribuicao insegura de booleanos | `bool(data["active"])` / `bool(data["available"])` com type safety |

---

## 12. Deploy Unificado (Producao + DR)

**Decisao:** Integrar o deploy de DR como Step 10 do `deploy.sh` (script unico)

| Criterio | Scripts Separados | Deploy Unificado |
|----------|-------------------|------------------|
| Experiencia do operador | 2 scripts, ordem importa | 1 comando, fluxo completo |
| Risco de esquecer DR | Alto | Zero (integrado) |
| Credenciais | Digitar 2 vezes | Digitar 1 vez |
| Consistencia | Versoes podem divergir | Mesmo contexto, mesmas variaveis |

O `deploy.sh` executa:
1. **Pre-step: `clean_orphans()`** em ambas regioes (prod e DR), removendo recursos orfaos de deploys anteriores (EKS em FAILED, RDS subnet/param groups, ElastiCache subnet groups, CloudWatch logs/alarms)
2. **10 steps**: S3 state -> ECR -> Terraform prod -> kubectl -> ArgoCD -> Monitoring (com criacao explicita de ConfigMaps Grafana) -> Build Docker -> Rollout -> Health Check -> **DR (Terraform + ArgoCD + Monitoring minimos)**

Tempo total de deploy: **~47 minutos** (EKS Prod ~10min, EKS DR ~13min, RDS Prod ~8min, RDS DR ~9min, ElastiCache ~4min).

O `destroy.sh` executa 13 fases com polling ativo (nao sleep fixo), verificacao de estado em loop, e `verify_clean()` como fase final de limpeza em ambas regioes. Tempo total: **~36 minutos**.

O DR roda com workload minimo (1 node, 1 replica por app, componentes ArgoCD nao-essenciais desligados) e escala somente no failover.

---

## 13. Exposicao de Servicos — ClusterIP + Port-Forward vs Ingress/LoadBalancer

**Decisao:** Services do tipo `ClusterIP` com acesso via `kubectl port-forward` no ambiente AWS Academy.

### 13.1. Por que nao usamos LoadBalancer ou Ingress Controller no Academy

O AWS Academy Learner Lab impoe restricoes que tornam o uso de Ingress Controller/LoadBalancer impraticavel:

| Fator | Detalhes |
|-------|---------|
| **Custo** | Cada Service `LoadBalancer` cria um NLB/ALB (~$16/mes por LB). Com 3 servicos + Grafana + ArgoCD = 5 LBs = **$80/mes** — 23% do orcamento total |
| **Budget Academy** | Limite de $50 por sessao. Um unico LB pode consumir o budget em poucos dias |
| **IAM** | Ingress Controllers como AWS ALB Controller exigem IAM Roles (IRSA) que o Academy nao permite criar |
| **Dominio/TLS** | Sem dominio registrado, o TLS termination no LB nao agrega valor |

### 13.2. O que esta preparado para producao

A infraestrutura ja esta pronta para Ingress Controller — basta instalar e ativar:

| Componente | Status | Arquivo |
|------------|--------|---------|
| Ingress manifest (rotas por path) | Criado | `kubernetes/base/ingress.yaml` |
| LB Security Group (HTTPS 443 + HTTP 80) | Criado | `terraform/modules/eks/main.tf` |
| NetworkPolicy allow-ingress-controller | Criada | `kubernetes/base/network-policies.yaml` |
| SSL redirect annotation | Configurado | `ingress.yaml` annotations |

### 13.3. Arquitetura em producao real

```
                   Internet
                      |
               [ Route 53 (DNS) ]
                      |
              [ ACM Certificate ]
                      |
            [ AWS ALB / NLB ($16/mes) ]
                      |
            [ Nginx Ingress Controller ]
                      |
          ┌───────────┼───────────┐
          |           |           |
   /api/v1/ngos  /api/v1/     /api/v1/
                 donations    volunteers
          |           |           |
     [ ngo-svc ] [ donation ] [ volunteer ]
     ClusterIP   ClusterIP    ClusterIP
```

**Fluxo:** Cliente -> DNS (Route 53) -> ALB com TLS (ACM) -> Ingress Controller (1 pod) -> Services ClusterIP -> Pods

### 13.4. Simulacao de custo — Producao Real com Ingress

| Componente | Custo Academy (atual) | Custo Producao Real |
|------------|----------------------:|--------------------:|
| Port-forward (acesso local) | $0 | - |
| AWS ALB (Ingress) | - | $16/mes |
| ACM Certificate (TLS) | - | $0 (gratuito) |
| Route 53 Hosted Zone | - | $0.50/mes |
| Nginx Ingress Controller (pod) | - | $0 (roda no EKS) |
| **Total exposicao** | **$0** | **$16.50/mes** |

### 13.5. Como ativar em producao (3 comandos)

```bash
# 1. Instalar Nginx Ingress Controller (cria o ALB automaticamente)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/aws/deploy.yaml

# 2. Aplicar o Ingress manifest (ja existe no repo)
kubectl apply -f kubernetes/base/ingress.yaml

# 3. Obter o endpoint do LoadBalancer
kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Resultado: abc123.us-east-1.elb.amazonaws.com
# Configurar este CNAME no Route 53 para o dominio desejado
```

Apos estes 3 comandos, todos os servicos ficam acessiveis via HTTPS em um unico endpoint, sem necessidade de port-forward.

---

## 14. Resumo das Decisoes

| # | Decisao | Alternativa Descartada | Motivo Principal |
|---|---------|----------------------|------------------|
| 1 | EKS | ECS | Portabilidade e ecossistema GitOps |
| 2 | Python/Flask (unificado) | Node.js, Java | Stack homogenea, produtividade, alinhamento academico |
| 3 | PostgreSQL RDS | DynamoDB, Aurora | Relacional, ACID, custo baixo |
| 4 | SQS + DLQ | RabbitMQ | Gerenciado, confiavel, zero manutencao |
| 5 | Warm Standby DR | Cold DR / Active-Active | RTO 3-5 min (teste: 58s) por 63% menos que Active-Active |
| 6 | ArgoCD | FluxCD | UI visual, App of Apps, RBAC |
| 7 | Prometheus/Grafana | Datadog | Gratuito, sem vendor lock-in |
| 8 | Private Subnets | Flat network | Seguranca por design |
| 9 | Auto-Scaling 3 camadas | Scaling manual | HPA + node-autoscaler.sh (Academy) / Cluster Autoscaler (prod real) + AIOps CronJob + DR automatico |
| 10 | Mitigacoes AWS Academy | Abandonar funcionalidades | Solucoes alternativas documentadas para cada restricao |
| 11 | Security Hardening 4 camadas | Seguranca basica | Defesa em profundidade: scripts, Terraform, K8s, aplicacao |
| 12 | Deploy unificado (Prod+DR) | Scripts separados | Operacao simplificada, consistencia, zero risco de esquecer DR |
| 13 | ClusterIP + port-forward | LoadBalancer / Ingress | Custo zero no Academy; infra pronta para Ingress em producao ($16.50/mes) |
| 16 | Sync bidirecional (INSERT ON CONFLICT) | Replicacao nativa RDS | RPO=0 para dados commitados, funciona sem Read Replica |
| 17 | Identificacao de regiao (3 camadas) | Label manual | Prometheus + API + Grafana panel em todos dashboards |
| 18 | AIOps proativa (CronJob 5min) | Apenas alertas reativos | 8 verificacoes com correcao automatica (CrashLoopBackOff, capacidade, monitoring, ArgoCD, services, health, AWS, namespaces) |
| 19 | Deploy/Destroy idempotentes | Scripts frageis com sleep fixo | `clean_orphans()` pre-deploy + polling ativo no destroy + `verify_clean()` pos-destroy |

Cada decisao foi tomada considerando 3 pilares: **custo** (ONG com orcamento limitado), **confiabilidade** (doacoes nao podem se perder) e **operacionalidade** (equipe enxuta precisa de automacao).

**Nota sobre AWS Academy:** As restricoes do Learner Lab (secao 10) nao representam limitacoes da arquitetura. Em um ambiente AWS com IAM completo, o Cluster Autoscaler, IRSA, SQS Worker, Read Replica cross-region e Ingress Controller funcionam nativamente sem nenhuma alteracao de codigo.

---

## 18. AIOps Proativa - Remediacao Automatica via CronJob

**Decisao:** Implementar remediacao proativa como CronJob Kubernetes, complementando o self-healing reativo (webhook AlertManager).

| Criterio | Self-healing Reativo (existente) | AIOps Proativa (adicionada) |
|----------|----------------------------------|----------------------------|
| Trigger | Alerta do Prometheus via AlertManager | Verificacao periodica (cron 5 min) |
| Escopo | Pod-level (restart, scale) | Cluster-wide (8 categorias) |
| Deteccao | Somente metricas acima do threshold | Estado completo (pods, services, AWS, namespaces) |
| Dependencia | Prometheus + AlertManager devem estar rodando | Independente — roda mesmo se monitoring cair |

**Justificativa:** O self-healing via webhook depende de Prometheus e AlertManager estarem funcionais. Se o proprio stack de monitoring cair, nenhum alerta e disparado e nenhuma correcao acontece. O CronJob AIOps e independente — verifica inclusive se o monitoring esta rodando e o reinicia se necessario.

### 8 Verificacoes Automaticas

| # | Verificacao | Deteccao | Correcao Automatica |
|---|-------------|----------|---------------------|
| 1 | Pods CrashLoopBackOff | Container em loop de restart | `rollout restart` do deployment |
| 2 | Capacidade de pods | Pods Pending por limite de nodes (>85% capacidade) | Reduz replicas de HPAs acima do minimo |
| 3 | Monitoring stack | Prometheus/Grafana/Loki/AlertManager nao pronto | Restart; Grafana: cria ConfigMaps faltantes |
| 4 | ArgoCD | Server nao pronto ou apps Degraded | Restart ArgoCD server; alerta para apps |
| 5 | Services sem endpoints | Service ativo sem pods respondendo | Alerta (verificar deployment/selector) |
| 6 | Health check apps | `/health` nao retorna "healthy" | `rollout restart` do servico afetado |
| 7 | AWS resources | RDS parado ou ElastiCache indisponivel | `start-db-instance` automatico para RDS |
| 8 | Namespaces travados | Namespace em Terminating ha muito tempo | Remove finalizers para destravar |

### Implementacao

- **Script CLI**: `scripts/aiops-remediation.sh` (modos: normal, `--dry-run`, `--watch`)
- **CronJob K8s**: `kubernetes/monitoring/selfhealing/cronjob-aiops.yaml` (every 5 min, `concurrencyPolicy: Forbid`)
- **ServiceAccount**: reutiliza `prometheus` (permissoes de leitura no cluster)
- **Timeout**: 120s por execucao (`activeDeadlineSeconds`)

### Exemplo de Saida

```
[AIOPS 14:30:00] Verificacao proativa iniciada
[OK] Todos os pods saudaveis
[OK] Capacidade de pods: 31/34
[OK] Stack de monitoramento completa
[OK] ArgoCD Server operacional
[OK] Todos os services com endpoints ativos
[OK] donation-service: healthy
[OK] ngo-service: healthy
[OK] volunteer-service: healthy
[OK] RDS: available
[OK] ElastiCache Redis: available
[OK] Nenhum namespace travado
━━━ Resumo AIOps ━━━
  Verificacoes: 8
  Correcoes automaticas: 0
  Problemas detectados: 0
Ambiente 100% saudavel — nenhuma acao necessaria.
```

---

## 19. Deploy e Destroy Idempotentes

**Decisao:** Tornar `deploy.sh` e `destroy.sh` idempotentes e resilientes a falhas, eliminando necessidade de intervencao manual.

### Problema

Deploys consecutivos falhavam por **recursos orfaos** de execucoes anteriores:
- ElastiCache subnet groups (`solidarytech-redis-subnet`) sobreviviam ao destroy por sleep insuficiente
- RDS subnet/parameter groups persistiam apos exclusao da instancia RDS
- EKS clusters em estado FAILED bloqueavam criacao de novo cluster

### Solucao: `clean_orphans()` no deploy

```
deploy.sh inicio
    |
    ├── clean_orphans("us-east-1", "production")
    │   ├── EKS em FAILED? -> aws eks delete-cluster
    │   ├── RDS subnet groups? -> aws rds delete-db-subnet-group (query dinamica)
    │   ├── RDS param groups? -> aws rds delete-db-parameter-group
    │   ├── ElastiCache subnet groups? -> aws elasticache delete-cache-subnet-group
    │   └── CloudWatch logs/alarms? -> cleanup
    │
    ├── clean_orphans("us-west-2", "dr")
    │   └── (mesmas verificacoes na regiao DR)
    │
    └── Prossegue com deploy normal (Steps 1-10)
```

### Solucao: Polling ativo no destroy

| Recurso | Antes (fragil) | Depois (resiliente) |
|---------|----------------|---------------------|
| ElastiCache | `sleep 120` (fixo) | Polling a cada 15s ate exclusao confirmada (timeout 5min) |
| NAT Gateway | `sleep 60` (fixo) | Polling a cada 10s ate exclusao confirmada (timeout 180s) |
| VPC | 1 tentativa | 3 tentativas com limpeza de SGs e subnets residuais entre retries |
| Verificacao final | Nao existia | `verify_clean()`: verifica VPCs, subnet groups, param groups, alarms em ambas regioes |

### Tempos Medidos

**Deploy completo (producao + DR):** ~47 minutos

| Step | Tempo | Recurso |
|------|-------|---------|
| EKS Producao | ~10 min | Cluster + Node Group |
| EKS DR | ~13 min | Cluster + Node Group |
| RDS Producao | ~8 min | PostgreSQL 15, t3.micro |
| RDS DR | ~9 min | PostgreSQL 15, t3.micro |
| ElastiCache | ~4 min | Redis 7.0, cache.t3.micro |
| kubectl + ArgoCD + Monitoring | ~3 min | Manifestos + ConfigMaps |

**Destroy completo:** ~36 minutos

| Fase | Tempo | Recurso |
|------|-------|---------|
| EKS DR | ~13 min | Cluster + Node Group |
| RDS (ambas regioes) | ~10 min | Instancias + subnet/param groups |
| EKS Producao | ~5 min | Cluster + Node Group |
| ElastiCache + NAT + VPC | ~5 min | Com polling ativo |
| Verificacao final | ~1 min | `verify_clean()` em ambas regioes |

---

## 15. Consolidado de Limitacoes AWS Academy e Workarounds

O AWS Academy Learner Lab utiliza IAM roles pre-configuradas (`LabRole`, `LabEksClusterRole`, `LabEksNodeRole`) que nao podem ser editadas. Isso impoe restricoes que nao existem em contas AWS reais. Para cada restricao, foi implementado um workaround funcional.

### Mapa de Restricoes vs Workarounds

| # | Restricao IAM | Permissao Ausente | Componente Afetado | Workaround | Script |
|---|---------------|-------------------|-------------------|------------|--------|
| 1 | IMDS hop limit | — (config EC2, nao IAM) | Todos os pods (credenciais IAM) | `modify-instance-metadata-options --http-put-response-hop-limit 2` | `deploy.sh`, `start-environment.sh`, `node-autoscaler.sh` |
| 2 | Cluster Autoscaler | `autoscaling:DescribeAutoScalingGroups`, `autoscaling:SetDesiredCapacity` | Scaling automatico de nodes | Script `node-autoscaler.sh` usa API EKS (`eks:UpdateNodegroupConfig`) | `node-autoscaler.sh` |
| 3 | SQS Worker | `sqs:ReceiveMessage` | Processamento assincrono de doacoes | Worker escalado a 0; doacoes processadas sincronamente | `deploy.sh` |
| 4 | RDS Read Replica | `rds:CreateDBInstanceReadReplica` | DR cross-region | RDS standalone em us-west-2 (mesmas credenciais e schema) | `deploy-dr.sh` |
| 5 | IRSA | `iam:CreateOpenIDConnectProvider`, `iam:CreateRole` | IAM por pod (zero trust) | Pods herdam credenciais do node role via IMDS | `deploy.sh` |

### Como Verificar se os Workarounds Estao Ativos

```bash
# 1. IMDS hop limit (deve retornar 2)
aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=solidarytech-eks-production" \
    --query 'Reservations[].Instances[].MetadataOptions.HttpPutResponseHopLimit' \
    --output text --region us-east-1

# 2. Cluster Autoscaler (deve estar 0/0 replicas)
kubectl get deployment cluster-autoscaler -n kube-system

# 3. SQS Worker (deve estar 0/0 replicas)
kubectl get deployment donation-worker -n solidarytech

# 4. DR RDS standalone (deve estar available)
aws rds describe-db-instances --db-instance-identifier solidarytech-dr-postgres \
    --region us-west-2 --query 'DBInstances[0].DBInstanceStatus' --output text

# 5. IMDS acessivel de dentro do pod
kubectl exec -n solidarytech deploy/donation-service -- \
    wget -q -O- http://169.254.169.254/latest/meta-data/iam/info 2>/dev/null | head -3
```

### Como Testar o Auto-Scaling Completo (Demo)

**Pre-requisitos:**
- Ambiente rodando (`bash scripts/start-environment.sh` ou `bash scripts/deploy.sh`)
- Apache Bench instalado (`sudo yum install httpd-tools` ou `sudo apt install apache2-utils`)

**Passo a passo (4 terminais):**

```bash
# ┌─────────────────────────────────────────────────┐
# │ Terminal 1 — Node Autoscaler (manter rodando)   │
# └─────────────────────────────────────────────────┘
bash scripts/node-autoscaler.sh

# ┌─────────────────────────────────────────────────┐
# │ Terminal 2 — Port-forwards dos servicos         │
# └─────────────────────────────────────────────────┘
# Porta 8083 evita conflito com ArgoCD na 8080
kubectl port-forward svc/ngo-service -n solidarytech 8083:8080 &
kubectl port-forward svc/donation-service -n solidarytech 8081:8081 &
kubectl port-forward svc/volunteer-service -n solidarytech 8082:8082 &

# ┌─────────────────────────────────────────────────┐
# │ Terminal 3 — Load test (seed + rampa)           │
# └─────────────────────────────────────────────────┘
NGO_URL=http://localhost:8083 bash scripts/load-test.sh all

# ┌─────────────────────────────────────────────────┐
# │ Terminal 4 — Grafana                            │
# └─────────────────────────────────────────────────┘
kubectl port-forward svc/grafana 3000:3000 -n monitoring
# Abrir http://localhost:3000 (admin / ver secret grafana-admin-secret)
```

**Sequencia esperada:**

1. `load-test.sh seed` — cria dados iniciais (ONGs, voluntarios, campanhas, doacoes em 5 moedas)
2. `load-test.sh` inicia rampa: 5 → 15 → 30 → 50 req/s
3. HPA detecta CPU alta → cria pods adicionais
4. Pods ficam Pending (node t3.medium cheio — max 17 pods)
5. `node-autoscaler.sh` detecta pods Pending → adiciona node via API EKS
6. Novo node sobe (~3-5 min) + IMDS hop limit corrigido automaticamente
7. Pods Pending agendam no novo node
8. Carga normaliza → cooldown 2 min → scale down automatico

**Dashboards Grafana para observar:**

| Dashboard | O que mostra durante o teste |
|-----------|----------------------------|
| **Platform Overview** | Status UP/DOWN, throughput por servico, error rate comparativo, CPU/mem por pod |
| **Business Metrics** | Volume de doacoes crescendo, distribuicao por moeda (pie chart), taxa de sucesso |
| **Infrastructure & Cluster** | Novo node aparecendo, HPA escalando replicas, pods por namespace, network I/O |
| **SRE Golden Metrics** | Latencia P50/P95/P99, SLO compliance (gauge), error budget |
| **SLO/SLI Tracking** | Burn rate reagindo a carga, SLO compliance 30-day |

### Diferenca: Academy vs Producao Real

| Capacidade | AWS Academy | Producao Real (IAM completo) |
|------------|-------------|------------------------------|
| Auto-scaling de nodes | `node-autoscaler.sh` (API EKS) | Cluster Autoscaler nativo (API ASG) |
| Processamento async | Sincrono (worker desligado) | SQS Worker ativo, at-least-once delivery |
| DR RDS | Standalone (sem replicacao) | Read Replica cross-region (RPO ~1s) |
| IAM por pod | IMDS com hop limit 2 (node role) | IRSA (role por ServiceAccount, zero trust) |
| Ingress | ClusterIP + port-forward | ALB Ingress Controller + HTTPS |
| Custo estimado mensal | ~$165 (Lab Credits) | ~$250-400 (com reservas: ~$180) |

**Conclusao:** Nenhuma restricao do Academy compromete a arquitetura. Todos os workarounds sao transparentes — o codigo da aplicacao, os manifestos Kubernetes e o Terraform sao **identicos** ao que seria usado em producao. A unica diferenca esta nos scripts operacionais que adaptam a execucao ao ambiente restrito.

---

## 16. Integridade de Dados no DR - Sync Bidirecional

**Decisao:** Sincronizacao bidirecional de dados via `INSERT ON CONFLICT` usando `transaction_id` (UUID) como chave de deduplicacao.

### Problema

Os bancos RDS em us-east-1 (producao) e us-west-2 (DR) sao **independentes** — nao ha replicacao nativa cross-region no Academy (sem permissao para criar Read Replicas cross-region). Isso significa:

- Dados criados durante operacao no DR seriam **perdidos** ao retornar para producao
- Producao nao replica automaticamente para DR, deixando RPO alto

### Solucao: Sync Bidirecional Idempotente

```
Producao (us-east-1)  <-- sync bidirecional -->  DR (us-west-2)
  RDS PostgreSQL                                   RDS PostgreSQL
  4548 donations                                   4548 donations
  R$ 637.125,18                                    R$ 637.125,18
       ✓ 100% MATCH                                     ✓ 100% MATCH
```

**Scripts implementados:**

| Script | Funcao |
|--------|--------|
| `scripts/dr-data-sync.sh` | Sincronizacao de dados (prod-to-dr, dr-to-prod, bidirectional) |
| `scripts/dr-failover.sh` | Failover com sync pre-migracao (Step 1) |
| `scripts/dr-failback.sh` | Failback com merge bidirecional + validacao de integridade |

**Chaves de deduplicacao:**

| Tabela | Chave | Tipo |
|--------|-------|------|
| donations | `transaction_id` (UUID) | UNIQUE INDEX |
| ngos | `cnpj` | UNIQUE CONSTRAINT |
| volunteers | `email` | UNIQUE CONSTRAINT |

### Fluxo de Failover com Protecao de Dados

```
1. FAILOVER (prod → DR)
   ├── Sync prod → DR (preservar dados atuais na regiao de destino)
   ├── Promover RDS / Atualizar secrets
   ├── Reiniciar pods no DR
   └── Validar integridade

2. OPERACAO NO DR
   └── Todas as escritas vao para o banco DR

3. FAILBACK (DR → prod)
   ├── Sync DR → prod (trazer dados criados durante DR)
   ├── Sync prod → DR (garantir backup atualizado)
   ├── Validar contagens (ambos devem ser iguais)
   ├── Mudar trafego para producao
   └── Reduzir DR para warm standby
```

### O que se PERDE no failover (analise honesta)

O RTO de 58s **nao significa zero perda**. Durante esses 58 segundos:

```
t=0          t=58s
|--- JANELA SEM SERVICO ---|
  ↑ requests in-flight: PERDIDOS
  ↑ requests tentados:  PERDIDOS (cliente recebe timeout)
  ↑ sem fila/buffer:    nao ha como recuperar
```

| Tipo de dado | Status | Explicacao |
|-------------|--------|------------|
| Commitados no DB antes da queda | **PRESERVADOS** | Sync bidirecional migra para DR |
| In-flight (aceitos, nao commitados) | **PERDIDOS** | Conexao cortada, sem WAL remoto |
| Tentados durante 58s de RTO | **PERDIDOS** | Nenhum servico disponivel, sem fila intermediaria |
| Criados no DR apos failover | **PRESERVADOS** | Sync traz de volta no failback |

**Estimativa de perda por failover:**
- Throughput medio: ~0.07 req/s → **~4 transacoes perdidas em 58s**
- Ticket medio: ~R$ 1.780 → **impacto financeiro: ~R$ 7.100**

### RPO (Recovery Point Objective)

- **Dados persistidos (commitados):** RPO = 0 (sync preserva tudo que esta no DB)
- **Transacoes em transito:** RPO = RTO (58s de transacoes irrecuperaveis)
- **Desastre subito (sem sync pre-failover):** RPO = intervalo desde ultimo sync
- **Em producao real:** RDS Read Replica cross-region (RPO ~1s automatico) + SQS como buffer (retry de transacoes falhas)

### Por que Failover Manual (nao automatico)?

O DR e ativado **manualmente** por design:

1. **Evitar split-brain:** Auto-failover pode ativar DR quando producao ainda esta funcional (ex: problema de rede entre regioes), causando duas regioes ativas com dados divergentes
2. **Academy constraints:** Sem Route53 Health Checks + DNS Failover automatico
3. **Camadas de auto-recuperacao ANTES do DR:**
   - Kubernetes self-healing (restart automatico de pods)
   - HPA auto-scaling (mais replicas se CPU/memoria alta)
   - Liveness/Readiness probes (remove pods degradados do trafego)

O DR so e acionado quando **todas** as camadas automaticas falharem (ex: AZ inteira fora, node morto sem substituicao).

### Failover vs Failback: niveis diferentes de transparencia

| Operacao | Downtime | Perda de dados | Transparente? |
|----------|----------|----------------|---------------|
| **Failover** (prod → DR) | **58s** (RTO) | ~4 transacoes in-flight | **Nao** — cliente recebe timeout |
| **Failback** (DR → prod) | **~0s** | 0 transacoes | **Sim** — dual-active transitorio |

O failover tem perda inevitavel porque a producao **ja caiu** — nao ha como servir requests sem servico. O failback e diferente: a producao ja esta saudavel, entao podemos fazer a transicao com ambas regioes ativas.

### Failback Transparente

O failback foi projetado para ser **transparente para o cliente e a aplicacao**:

```
Tempo -->
DR ativo:    [==== servindo ====][drain][standby]
Producao:    [== ready (idle) ==][======= servindo =======]
                                  ^
                          Transicao sem gap
```

**Tecnicas utilizadas:**

| Tecnica | Problema que resolve |
|---------|---------------------|
| **Readiness gate** | Nao redireciona ate producao estar Running+Ready |
| **Dual-active transitorio** | Ambas regioes operam simultaneamente durante sync |
| **Restart seletivo** | So reinicia pods que NAO estao Running (evita downtime desnecessario) |
| **Connection draining** | Aguarda requests in-flight no DR completarem antes de desligar |
| **Delta sync final** | Captura escritas que ocorreram durante o sync principal |
| **Scale 0 antes de drain** | Impede novas conexoes no DR enquanto conclui as existentes |

**Em producao real (fora Academy), complementar com:**

- Route53 Health Check + DNS Failover (TTL 60s) para chaveamento automatico de DNS
- AWS Global Accelerator para failover sub-30s sem depender de TTL DNS
- RDS Read Replica cross-region com promocao automatica (RPO ~1s)
- ALB Ingress Controller com health checks para zero-downtime no Kubernetes

---

## 17. Identificacao de Regiao Ativa (Multi-Layer)

**Decisao:** Implementar identificacao de regiao em 3 camadas independentes para garantir que operadores e ferramentas sempre saibam qual regiao esta servindo trafego.

### Camada 1: Prometheus (`external_labels`)

```yaml
global:
  external_labels:
    cluster: production    # ou "dr"
    region: us-east-1      # ou "us-west-2"
```

Todos os dashboards Grafana usam a label `topology_kubernetes_io_region` (automatica dos nodes EKS) para exibir a regiao ativa.

### Camada 2: API `/region` (todos os microsservicos)

Endpoint adicionado a todos os 3 microsservicos (donation-service, ngo-service, volunteer-service):

```json
GET /region
{
  "region": "us-east-1",
  "cluster": "solidarytech-eks-production",
  "service": "donation-service",
  "role": "production"
}
```

A logica determina o role automaticamente: se `CLUSTER_NAME` contem "dr" ou `AWS_REGION` e "us-west-2", retorna `"role": "dr"`.

### Camada 3: Grafana "Regiao Ativa" (todos os dashboards)

Panel tipo `stat` no canto superior direito de **todos os 6 dashboards**:

| Dashboard | Panel "Regiao Ativa" |
|-----------|---------------------|
| Platform Overview | Sim |
| Business Metrics - Doacoes | Sim |
| SRE Golden Metrics | Sim |
| SLO/SLI Tracking | Sim |
| Infrastructure & Cluster | Sim |
| Disaster Recovery - Status | Sim |

**Query Prometheus:**
```promql
topk(1, count by (topology_kubernetes_io_region) (up{namespace="solidarytech"} == 1))
```

**Value mapping:**
- `us-east-1` → **PROD** (fundo verde)
- `us-west-2` → **DR** (fundo laranja)

**Justificativa:** Em um cenario de DR, a primeira pergunta de qualquer operador e "em qual regiao estamos?". Ter essa informacao visivel em todos os dashboards elimina ambiguidade e erros de operacao.
