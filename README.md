# SolidaryTech - Hackathon Fase 5

A SolidaryTech é uma plataforma para conectar ONGs, doadores e voluntários. Nesta fase final da Pós Tech em Arquitetura Cloud e DevOps, evoluímos o código-base fornecido para uma arquitetura cloud-native com infraestrutura como código e automação de entrega.

No projeto usamos CI/CD com DevSecOps e GitOps, adotando o Git como fonte de verdade para a entrega. Também aplicamos observabilidade por métricas, logs e traces, SRE, FinOps, AIOps, ITSM e Disaster Recovery. Nosso foco foi transformar uma base funcional em um ambiente que pudesse ser provisionado, entregue, observado e operado de forma reproduzível.

> **Leitura rápida:** SRE trata confiabilidade de forma mensurável; FinOps relaciona uso e custo; AIOps aplica IA às operações; ITSM organiza a gestão de serviços e incidentes; Disaster Recovery trata a recuperação tecnológica após falhas relevantes.

## Evolução da arquitetura fornecida

O repositório-base do Hackathon foi entregue com três microsserviços independentes e uma arquitetura propositalmente poliglota, isto é, usando mais de uma linguagem para simular um ambiente corporativo distribuído:

| Serviço na base fornecida | Tecnologia | Persistência / integração |
|---|---|---|
| `ngo-service` | Python + Flask | PostgreSQL |
| `donation-service` | Go | PostgreSQL + AWS SQS (fila gerenciada) |
| `volunteer-service` | Python + Flask | DynamoDB |

Mantivemos as responsabilidades de negócio, mas fizemos algumas mudanças arquiteturais para facilitar a operação e a observabilidade exigidas no Hackathon.

### Padronização dos serviços em Python

Padronizamos os três serviços em Python 3.13 com Flask/Gunicorn. Não fizemos essa mudança por considerar Go inadequado. Uma arquitetura poliglota pode ser uma boa escolha quando serviços possuem necessidades técnicas muito diferentes ou quando existem equipes especializadas em stacks distintas.

Para este projeto, consideramos mais vantajoso reduzir a quantidade de toolchains, isto é, conjuntos diferentes de ferramentas de build, testes e dependências mantidos pela equipe. A padronização trouxe principalmente:

- mesma estrutura de projeto e dependências entre os serviços;
- padrão único de testes e lint;
- Dockerfiles e pipelines CI/CD mais consistentes;
- scans de segurança mais uniformes;
- instrumentação OpenTelemetry semelhante nos serviços;
- logging e troubleshooting mais previsíveis;
- menor carga cognitiva para manutenção e operação;
- procedimentos mais uniformes de build, deploy e recuperação.

### Separação do processamento assíncrono de doações

Na base inicial, o `donation-service` em Go gravava a doação e publicava um evento na SQS. Na arquitetura final mantivemos a SQS, mas separamos o processamento em dois componentes:

- `donation-service`: recebe, valida e persiste a solicitação de doação e publica a mensagem na fila;
- `donation-worker`: processo em segundo plano que consome a SQS, executa o processamento de pagamento, atualiza o estado da doação e registra telemetria.

Essa separação mantém a API mais desacoplada do processamento posterior e permite observar, reiniciar e escalar o serviço e o worker de forma independente.

### Organização dos dados

Na arquitetura final, os dados relacionais de ONGs, voluntários, campanhas, matches e doações ficam no Amazon RDS PostgreSQL usado no ambiente acadêmico. Também usamos:

- Redis para cache de consultas e dados temporários;
- SQS para desacoplar o processamento assíncrono;
- DynamoDB para informações de transação/auditoria do fluxo de doações.

Para o escopo acadêmico, essa organização reduziu a complexidade operacional do banco relacional sem eliminar o uso de diferentes padrões de persistência. Em um produto real com requisitos maiores de autonomia entre microsserviços, a separação de bancos por domínio/serviço poderia ser reavaliada.

### Operabilidade padronizada

Além dos endpoints de negócio, os serviços expõem endpoints operacionais padronizados:

- `/health`: indica que o processo está ativo;
- `/ready`: verifica se o serviço está pronto para receber tráfego e se dependências essenciais estão acessíveis;
- `/metrics`: expõe métricas para o Prometheus.

Também adotamos OpenTelemetry para tracing, Prometheus para métricas e Promtail/Loki para centralização de logs.

> **Fluxo de observabilidade:** tracing acompanha uma requisição ponta a ponta; Promtail coleta os logs dos pods e os envia ao Loki, onde podem ser consultados e visualizados no Grafana.

## Objetivos do projeto

Estruturamos a solução para:

- automatizar o provisionamento da infraestrutura;
- evitar deploy manual como processo de entrega;
- aplicar validações de segurança no pipeline;
- centralizar métricas, logs e traces;
- definir SLI, SLO e Error Budget para o caminho crítico;
- acompanhar consumo de recursos e apoiar decisões de rightsizing;
- detectar anomalias com AIOps;
- organizar o ciclo de incidentes com princípios de ITSM;
- modelar um PCN e uma estratégia de Disaster Recovery em outra região AWS.

> **Termos usados nos objetivos:** SLI é a medida observada; SLO é o objetivo de confiabilidade; Error Budget é a margem de falha permitida pelo SLO; rightsizing ajusta capacidade ao uso real; PCN é o Plano de Continuidade de Negócios.

## Microsserviços

| Componente | Responsabilidade |
|---|---|
| `ngo-service` | Cadastro e gestão de ONGs parceiras |
| `donation-service` | Entrada e persistência das doações, caminho crítico da plataforma |
| `donation-worker` | Consome SQS e conclui o processamento assíncrono |
| `volunteer-service` | Voluntários, campanhas e matching entre voluntários e campanhas |

## Arquitetura

### Fluxo de entrega

```text
GitHub
  |
  v
GitHub Actions
  |-- testes e lint
  |-- DevSecOps scan
  |-- build da imagem imutável
  |   (imagem versionada que não é sobrescrita)
  |-- push para Amazon ECR
  |-- atualização do manifesto GitOps
  |
  v
ArgoCD
  |
  v
Amazon EKS
  |-- ngo-service
  |-- donation-service
  |-- donation-worker
  `-- volunteer-service
```

Adotamos o Git como fonte de verdade. O ArgoCD reconcilia o cluster, isto é, compara continuamente o estado executado no Kubernetes com o estado descrito no Git e corrige divergências.

### Dados e mensageria

```text
RDS PostgreSQL
  |-- ONGs
  |-- voluntários
  |-- campanhas/matches
  `-- doações

Redis
  `-- cache/dados temporários

SQS
  `-- fila de processamento assíncrono de doações

DynamoDB
  `-- transações/auditoria do fluxo de doações
```

### Observabilidade

```text
Métricas
Aplicações/Kubernetes -> Prometheus -> Grafana

Logs
Pods -> Promtail -> Loki -> Grafana

Traces/APM
Aplicações -> OpenTelemetry -> New Relic
```

Promtail lê os logs dos pods e os envia ao Loki. APM, ou Application Performance Monitoring, usa telemetria da aplicação para acompanhar desempenho e localizar gargalos.

## Fundação DevOps

### Docker e Kubernetes

Containerizamos os serviços e criamos os manifests Kubernetes. Os workloads Kubernetes (cargas executadas no cluster) possuem:

- `requests`: quantidade de CPU/memória reservada para o pod;
- `limits`: teto máximo de CPU/memória permitido;
- probes: checagens automáticas usadas pelo Kubernetes para verificar a saúde e a prontidão dos containers;
- HPA: ajuste automático da quantidade de réplicas;
- PDB: limita quantos pods podem ficar indisponíveis durante uma manutenção planejada.

> **Operação do cluster:** HPA significa Horizontal Pod Autoscaler. PDB significa PodDisruptionBudget. Um drain de node esvazia um node de forma controlada e realoca seus pods antes de uma manutenção.

Executamos o ambiente principal no Amazon EKS.

### Infraestrutura como Código

Provisionamos a infraestrutura com Terraform e organizamos os ambientes em:

```text
terraform/
├── environments/
│   ├── production/
│   └── dr/
└── modules/
```

Produção utiliza `us-east-1`. O ambiente de DR é modelado para `us-west-2`.

Os módulos Terraform agrupam blocos reutilizáveis de infraestrutura, como VPC, EKS, RDS, SQS e DynamoDB.

### CI/CD e DevSecOps

Os workflows do GitHub Actions executam:

1. testes e lint;
2. análise de segurança e dependências;
3. build da imagem imutável;
4. publicação no Amazon ECR;
5. atualização do manifesto GitOps.

Dados sensíveis não são armazenados no código. Secrets usados pelo pipeline são fornecidos por GitHub Actions Secrets e, no Kubernetes, por Secrets fornecidos durante a execução da aplicação.

### GitOps

O ArgoCD mantém dois grupos principais:

- `solidarytech-platform`: workloads da aplicação, como Deployments, Services, HPA e PDB;
- `monitoring-stack`: componentes de observabilidade, como Prometheus, Grafana, Loki e OpenTelemetry Collector.

`Healthy` indica que os recursos estão operacionais. `Synced` indica que o estado executado no cluster corresponde ao estado versionado no Git.

## Observabilidade e SRE

SRE foi aplicado principalmente ao `donation-service`, por ser o caminho crítico.

### SLI, SLO e SLA

| Conceito | Uso no projeto |
|---|---|
| SLI | Medida observada, como disponibilidade ou latência |
| SLO | Objetivo interno de confiabilidade para o SLI |
| SLA | Acordo formal de nível de serviço; no cenário acadêmico usamos uma referência proposta, pois não existe contrato comercial real |

Os objetivos usados no dashboard são:

| Indicador | Objetivo |
|---|---|
| Disponibilidade | 99,9% das requisições de negócio sem erro 5xx em 30 dias |
| Latência | 99,0% das requisições de negócio concluídas em até 500 ms em 30 dias |

Os endpoints `/health`, `/ready` e `/metrics` continuam monitorados operacionalmente, mas foram excluídos do cálculo do SLI de negócio para que chamadas automáticas de Kubernetes e Prometheus não distorçam a experiência real do fluxo de doações.

### Dashboards

Mantemos dois dashboards com objetivos diferentes:

- SLO & Error Budget: acompanha se os objetivos de confiabilidade estão sendo cumpridos ao longo da janela de avaliação;
- Golden Metrics: mostra o comportamento operacional mais imediato para investigação de incidentes.

Termos principais:

- Traffic: volume/taxa de requisições, por exemplo `req/s`;
- Error Rate: percentual de requisições que resultaram em erro. `0%` significa que, no recorte exibido, nenhuma requisição considerada terminou com erro;
- latência p95: tempo abaixo do qual 95% das requisições foram concluídas;
- Error Budget: quantidade de falhas ainda tolerada antes de violar o SLO;
- Burn Rate: velocidade com que o Error Budget está sendo consumido;
- worker: processo em segundo plano que consome a fila SQS.

Além de acompanhar os indicadores, organizamos métricas, logs e traces para reduzir o MTTR (Mean Time To Recovery, tempo médio necessário para restaurar um serviço após uma falha). A ideia é encurtar o caminho entre detectar um problema, localizar sua causa e recuperar o serviço. Como este é um ambiente acadêmico sem histórico operacional anterior, não usamos um percentual de redução de MTTR; demonstramos, em vez disso, como os sinais de observabilidade se complementam durante a investigação.

### Limites do ambiente acadêmico e dos testes realizados

Durante a demonstração, geramos carga propositalmente e incluímos latência no fluxo de pagamento para observar como métricas, dashboards, alertas e traces reagiriam a uma degradação. Por isso, a latência observada ultrapassou o SLO em parte da amostra. O objetivo desse teste era tornar a degradação visível; em uma operação real, a violação do SLO seria um sinal para investigação e correção.

## FinOps

FinOps é a disciplina de gestão e otimização financeira da nuvem.

### Tagging

Aplicamos tags por Terraform, incluindo:

```text
Project     = SolidaryTech
Environment = Production
CostCenter  = NGO-Core
ManagedBy   = Terraform
```

Tagging significa usar metadados para organizar recursos e facilitar alocação/rastreabilidade de custos.

### Rightsizing

Rightsizing é o ajuste de CPU e memória com base no consumo observado. Coletamos consumo dos containers e comportamento do HPA durante carga para comparar:

- `request`: recurso reservado para o pod;
- `limit`: recurso máximo permitido;
- pico observado: maior consumo encontrado na janela de teste.

A coleta ajuda a identificar folga ou pressão de recursos, mas uma redução só deve ser feita após testar diferentes perfis de carga. No caso do `donation-service`, o pico de CPU ultrapassou o request e o HPA aumentou réplicas, portanto a amostra não justificou reduzir a reserva de CPU.

### Forecast

Forecast é uma projeção de gastos futuros. Como o AWS Academy é temporário, estimamos quanto a capacidade definida no Terraform custaria se ficasse ativa continuamente por um mês. Essa estimativa não é uma fatura real e pode variar com tráfego, armazenamento, preços e uso efetivo.

Em um ambiente real de produção, isto é, se a SolidaryTech fosse operada continuamente para usuários reais, complementaríamos a análise com:

- Cost Explorer: análise de gastos AWS;
- AWS Budgets: limites e alertas de orçamento;
- CUR (Cost and Usage Report): relatório detalhado de custos e consumo;
- Savings Plans/Reserved Instances: descontos por compromisso de uso;
- Graviton: processadores ARM da AWS que podem melhorar custo/eficiência quando a aplicação é compatível;
- FOCUS: padrão para normalizar dados de custos entre provedores/ferramentas;
- GreenOps: otimização de recursos considerando eficiência e sustentabilidade.

### FinOps Assessment

Usaríamos uma avaliação de maturidade para verificar se a gestão de custos evolui em três etapas:

- Informar: saber onde o dinheiro é gasto, com tags e alocação consistentes;
- Otimizar: identificar desperdício, rightsizing e opções de desconto;
- Operar: transformar análise de custos em rotina, comparando forecast com gasto realizado e acompanhando os resultados das otimizações.

## ITSM e AIOps

ITSM organiza o ciclo de gestão de serviços e incidentes. AIOps usa IA e machine learning para apoiar operações.

No New Relic, configuramos uma condição de anomalia de latência do `donation-service`. A plataforma aprende um baseline a partir do histórico, isto é, uma referência de comportamento esperado, e compara esse padrão com o valor atual para sinalizar desvios relevantes.

O ciclo considerado é:

```text
Detecção
  -> Qualificação
  -> Priorização
  -> Investigação
  -> Mitigação
  -> Recuperação
  -> Comunicação
  -> Post-Mortem
  -> Ações de melhoria
```

Na investigação, traces são divididos em spans, etapas temporizadas de uma mesma requisição, o que permite identificar onde o tempo foi gasto.

Se a solução fosse operada continuamente em produção, também faria sentido integrar uma escala on-call e uma plataforma ITSM para registrar responsável, status, histórico e comunicação. On-call é o profissional de plantão acionado em incidentes.

## PCN e Disaster Recovery

PCN significa Plano de Continuidade de Negócios. Ele define como manter ou recuperar funções críticas diante de falhas relevantes.

Para o DR escolhemos um modelo ativo-passivo em outra região AWS:

- região principal: `us-east-1`;
- região de recuperação: `us-west-2`;
- RTO: tempo máximo alvo para recuperação, definido em até 5 minutos para o caminho crítico;
- RPO: janela máxima tolerada de perda de dados.

> **Recuperação:** RTO significa Recovery Time Objective; RPO significa Recovery Point Objective.

O ambiente secundário é modelado como Warm Standby, uma infraestrutura de contingência preparada para ser ativada ou ampliada durante um failover. Failover é a transferência da operação para a região de recuperação.

O comando:

```bash
./scripts/deploy-dr.sh
```

executa validações e `terraform plan` por padrão. `terraform plan` calcula quais recursos seriam criados/alterados sem executar essas mudanças. Somente `terraform apply` cria a infraestrutura.

Na evidência acadêmica validamos o plano de DR sem manter uma segunda infraestrutura completa ativa. Modelamos o RDS secundário como uma instância independente porque, para o objetivo da entrega, isso foi suficiente para demonstrar a infraestrutura de contingência, a separação entre regiões e o processo previsto de recuperação. Adicionar replicação contínua aumentaria custo e complexidade para atender a um requisito de perda de dados próxima de zero que não fazia parte do cenário proposto.

Como esse banco não recebe continuamente todas as gravações da região principal, não afirmamos RPO zero. RPO zero significaria garantir que nenhuma transação confirmada fosse perdida mesmo em uma falha regional abrupta. Se a SolidaryTech fosse operada continuamente para usuários reais com esse requisito, consideraríamos replicação contínua entre regiões, sincronização, failover e validação de consistência dos dados. Também realizaríamos testes periódicos de failover para medir o tempo de recuperação e comprovar o funcionamento do plano.

## Segurança

Aplicamos práticas compatíveis com o escopo do projeto:

- credenciais reais fora do repositório;
- secrets fornecidos em runtime;
- containers com usuário não root quando aplicável;
- RBAC (Role-Based Access Control, permissões baseadas em papéis) no Kubernetes;
- Network Policies para limitar comunicação entre workloads;
- scans DevSecOps no pipeline;
- infraestrutura versionada em Terraform e GitOps.

No ambiente acadêmico usamos RDS sem Multi-AZ para reduzir custo e complexidade. Se a plataforma fosse operada continuamente com requisitos de alta disponibilidade, avaliaríamos Multi-AZ, EKS Pod Identity ou IRSA, Secrets Manager, KMS, WAF, TLS gerenciado, SBOM, assinatura de imagens e políticas de admission no Kubernetes.

> **Controles citados:** Multi-AZ acrescenta redundância entre zonas; IRSA/Pod Identity fornece identidade AWS aos workloads sem chaves fixas; KMS gerencia chaves de criptografia; WAF protege aplicações web; TLS protege dados em trânsito; SBOM inventaria componentes de software; admission policies bloqueiam recursos fora das regras definidas.

## Outros conteúdos estudados

Também estudamos tecnologias que poderiam ser úteis em cenários com requisitos diferentes, mas que não eram necessárias para atender ao Hackathon. Por isso, não as adicionamos apenas para aumentar a quantidade de ferramentas da solução.

- **Karpenter / KEDA:** autoscaling mais avançado de nodes ou orientado a eventos.
- **Istio / Canary / Blue-Green:** controle de tráfego e estratégias graduais de release.
- **eBPF:** observabilidade de baixo nível em kernel e rede.
- **FOCUS / Unit Economics / GreenOps:** normalização de custos, custo por unidade de negócio e eficiência.
- **MLOps / MCP:** ciclo de vida de modelos e integração de ferramentas com agentes.
- **Multicloud ativo / BGP:** operação entre provedores e roteamento privado entre redes.

Esses conteúdos ficam como referência de aplicação em contextos nos quais tragam benefício técnico real. O foco desta implementação permaneceu nos requisitos efetivamente solicitados para a entrega.

## Estrutura principal do repositório

```text
.
├── .github/
│   └── workflows/
├── microservices/
│   ├── ngo-service/
│   ├── donation-service/
│   └── volunteer-service/
├── kubernetes/
│   ├── argocd/
│   ├── base/
│   └── monitoring/
├── scripts/
├── terraform/
│   ├── environments/
│   └── modules/
├── docker-compose.yml
└── README.md
```

## Scripts principais

| Script | Finalidade |
|---|---|
| `scripts/deploy.sh` | Provisiona/configura o ambiente principal |
| `scripts/bootstrap-argocd.sh` | Configura o ArgoCD |
| `scripts/setup-monitoring.sh` | Configura a stack de observabilidade |
| `scripts/post-deploy-check.sh` | Executa health check pós-deploy |
| `scripts/demo-data.sh` | Gera dados e tráfego de demonstração |
| `scripts/collect-rightsizing-metrics.sh` | Coleta CPU, memória e comportamento do HPA |
| `scripts/deploy-dr.sh` | Valida e gera o plano da infraestrutura de DR |

## Ambiente local

O `docker-compose.yml` sobe as dependências locais, incluindo PostgreSQL, Redis, LocalStack, Prometheus, Grafana e OpenTelemetry Collector.

LocalStack emula APIs AWS usadas no desenvolvimento, como SQS e DynamoDB, permitindo validar o fluxo local sem depender continuamente da conta AWS.

## Validações utilizadas

Exemplos:

```bash
bash -n \
  scripts/deploy.sh \
  scripts/deploy-dr.sh \
  scripts/bootstrap-argocd.sh \
  scripts/demo-data.sh \
  scripts/post-deploy-check.sh \
  scripts/setup-monitoring.sh

python3 -m py_compile \
  microservices/ngo-service/src/app.py \
  microservices/donation-service/src/app.py \
  microservices/donation-service/src/worker.py \
  microservices/volunteer-service/src/app.py

docker compose config

terraform fmt -recursive terraform/

git diff --check
```

Com acesso ao cluster:

```bash
./scripts/post-deploy-check.sh
```

O script verifica nodes, namespaces, stack de monitoramento, serviços da aplicação, HPA, ArgoCD e conectividade interna.

## AWS Academy

O AWS Academy utiliza credenciais temporárias e permissões IAM restritas. Por isso, algumas decisões do ambiente acadêmico diferem do que adotaríamos em uma conta corporativa.

No repositório procuramos deixar claro o que:

- executamos no ambiente;
- validamos por configuração ou `terraform plan`;
- consideraríamos em um ambiente real de produção com requisitos adicionais.

## Repositório

https://github.com/yurijcarmo/solidarytech-fase5
