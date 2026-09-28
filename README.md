# SolidaryTech — Hackathon Fase 5

Plataforma cloud-native para ONGs, doadores e voluntários, evoluída a partir do ecossistema fornecido no Hackathon da FIAP.

## Arquitetura

- **ngo-service** — Python/Flask + PostgreSQL + Redis
- **donation-service** — Python/Flask + PostgreSQL + SQS + DynamoDB + worker assíncrono
- **volunteer-service** — Python/Flask + PostgreSQL
- **AWS** — VPC, EKS, RDS, SQS, DynamoDB, ElastiCache e ECR provisionados por Terraform
- **GitOps** — ArgoCD
- **Observabilidade** — Prometheus, Grafana, Loki e OpenTelemetry
- **APM/AIOps** — New Relic via OTLP
- **DR** — Warm Standby em `us-west-2` com infraestrutura Terraform dedicada

## Decisão de padronização tecnológica

A solução fornecida como base apresentava uma arquitetura poliglota, com microsserviços utilizando stacks distintas. Durante a evolução do projeto, os serviços foram padronizados em Python para reduzir diversidade tecnológica e simplificar manutenção, testes, CI/CD, análise de segurança, instrumentação com OpenTelemetry e troubleshooting.

No fluxo crítico de doações, o processamento assíncrono por SQS foi preservado e complementado por um worker dedicado, mantendo desacoplamento e resiliência. A padronização também simplifica os procedimentos de Disaster Recovery e sincronização de dados entre regiões.

## Estrutura

```text
microservices/             microsserviços e testes
terraform/
  modules/                 módulos reutilizáveis
  environments/production produção us-east-1
  environments/dr         Warm Standby us-west-2
kubernetes/
  base/                    workloads, HPA, PDB e NetworkPolicies
  monitoring/              Prometheus, Grafana, Loki, OTel e Alertmanager
  argocd/                  aplicações GitOps
.github/workflows/         CI/CD, DevSecOps e validação Terraform
scripts/
  deploy.sh                provisionamento da infraestrutura no AWS Academy
  bootstrap-argocd.sh      bootstrap GitOps após as imagens estarem no ECR
  demo-data.sh             geração reproduzível de dados para a demonstração
  deploy-dr.sh             provisionamento do ambiente DR
  collect-rightsizing-metrics.sh
```

## CI/CD

Cada microsserviço possui pipeline com:

1. lint e testes automatizados;
2. cobertura;
3. Trivy para imagem e dependências;
4. quality gate para vulnerabilidades críticas;
5. build e push de imagem imutável `sha-*` no ECR;
6. atualização automática do manifesto GitOps;
7. reconciliação pelo ArgoCD.

O Terraform possui workflow separado para `fmt`, `validate` e `plan` manual no AWS Academy.

## AWS Academy

As credenciais do Learner Lab são temporárias e **não são versionadas**. O deploy utiliza as roles existentes do Academy e cria os secrets de runtime diretamente no Kubernetes.

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
export AWS_DEFAULT_REGION="us-east-1"
export NEW_RELIC_LICENSE_KEY="..."

aws sts get-caller-identity
./scripts/deploy.sh
```

Após executar as pipelines dos três serviços no GitHub Actions:

```bash
./scripts/bootstrap-argocd.sh
kubectl get applications -n argocd
kubectl get pods -A
```

## Dados para demonstração

Com o ambiente saudável:

```bash
./scripts/demo-data.sh
```

O script cria dados de negócio e tráfego suficiente para popular métricas, traces e dashboards sem executar vários comandos manualmente.

## DR

A estratégia adotada para o laboratório é **Warm Standby** em `us-west-2`. No AWS Academy o RDS DR é standalone; não é apresentada garantia de replicação cross-region nativa ou RPO zero.

```bash
cd terraform/environments/dr
terraform init -backend=false
terraform validate
terraform plan
```
