# 🚀 SolidaryTech — Hackathon Fase 5

Bem-vindo ao repositório oficial da **SolidaryTech**.

Este monorepo contém os microsserviços que compõem a plataforma da ONG e servirá como base para os desafios do Hackathon Fase 5.

O objetivo principal deste projeto é aplicar conceitos modernos de:

- SRE (Site Reliability Engineering)
- FinOps
- Multicloud
- ITSM
- Observabilidade
- Resiliência
- Kubernetes & GitOps
- Infraestrutura como Código (IaC)

---

# 🏗️ Arquitetura dos Microsserviços

O ecossistema é composto por **3 microsserviços independentes**, desenvolvidos com tecnologias diferentes para simular um ambiente corporativo distribuído.

---

## 1️⃣ NGO Service — Cadastro de ONGs

| Item | Valor |
|---|---|
| Linguagem | Python 3.9+ |
| Framework | Flask |
| Banco de Dados | PostgreSQL |
| Porta Local | `8081` |

### 📌 Descrição
Responsável pelo gerenciamento e cadastro das ONGs parceiras da plataforma.

---

## 2️⃣ Donation Service — Processamento de Doações

| Item | Valor |
|---|---|
| Linguagem | Go 1.21+ |
| Banco de Dados | PostgreSQL |
| Mensageria | AWS SQS |
| Porta Local | `8082` |

### 📌 Descrição
Este é o **Hot Path** da aplicação.

Responsável pelo processamento das doações e publicação de eventos assíncronos em filas para processamento posterior.

---

## 3️⃣ Volunteer Service — Gestão de Voluntários

| Item | Valor |
|---|---|
| Linguagem | Python 3.9+ |
| Framework | Flask |
| Banco de Dados | AWS DynamoDB |
| Porta Local | `8083` |

### 📌 Descrição
Gerencia o cadastro e inscrição de voluntários interessados em apoiar as ONGs parceiras.

Utiliza armazenamento NoSQL nativo da AWS com foco em escalabilidade.

---

# 📁 Estrutura do Repositório

```text
.
├── ngo-service/          # Código Python e scripts SQL do serviço de ONGs
├── donation-service/     # Código Go e scripts SQL do serviço de doações
└── volunteer-service/    # Código Python do serviço de voluntários
```

---

# 🚀 Executando Localmente

Antes de realizar deploy em Kubernetes e automatizações CI/CD, recomenda-se validar todo o ambiente localmente.

---

# ✅ Pré-requisitos

Certifique-se de possuir os seguintes itens instalados:

- Python 3.9+
- Go 1.21+
- Docker (opcional, mas recomendado)
- PostgreSQL
- AWS CLI configurado
- Credenciais AWS válidas

---

# 🛠️ Passo 1 — Preparação da Infraestrutura

## PostgreSQL

Crie dois bancos de dados independentes:

### Banco `ngo_db`

Execute:

```sql
ngo-service/db/init.sql
```

### Banco `donation_db`

Execute:

```sql
donation-service/db/init.sql
```

---

## AWS DynamoDB

Crie a tabela:

| Configuração | Valor |
|---|---|
| Nome da Tabela | `SolidaryTechVolunteers` |
| Partition Key | `volunteer_id` |
| Tipo | `String` |

---

## AWS SQS

Crie uma fila do tipo **Standard Queue**.

Exemplo:

```text
https://sqs.us-east-1.amazonaws.com/1234567890/solidary-donations
```

Guarde a URL da fila para utilizar nas variáveis de ambiente.

---

# ⚙️ Passo 2 — Variáveis de Ambiente

Crie um arquivo `.env` dentro de cada microsserviço.

---

## 📄 ngo-service/.env

```env
PORT=8081
DATABASE_URL="postgres://SEU_USUARIO:SUA_SENHA@localhost:5432/ngo_db"
```

---

## 📄 donation-service/.env

```env
PORT=8082
DATABASE_URL="postgres://SEU_USUARIO:SUA_SENHA@localhost:5432/donation_db"

AWS_REGION="us-east-1"
AWS_SQS_URL="SUA_URL_DA_FILA_SQS"
```

---

## 📄 volunteer-service/.env

```env
PORT=8083

AWS_REGION="us-east-1"
AWS_DYNAMODB_TABLE="SolidaryTechVolunteers"
```

---

# ▶️ Passo 3 — Inicializando os Serviços

Abra **3 terminais separados**.

---

## 🟣 Terminal 1 — NGO Service

```bash
cd ngo-service

pip install -r requirements.txt

gunicorn --bind 0.0.0.0:8081 app:app
```

---

## 🟠 Terminal 2 — Donation Service

```bash
cd donation-service

go mod tidy

go run .
```

---

## 🔵 Terminal 3 — Volunteer Service

```bash
cd volunteer-service

pip install -r requirements.txt

gunicorn --bind 0.0.0.0:8083 app:app
```

---

# 🌐 Portas Locais

| Serviço | URL |
|---|---|
| NGO Service | http://localhost:8081 |
| Donation Service | http://localhost:8082 |
| Volunteer Service | http://localhost:8083 |

---

# 🎯 Objetivos do Hackathon

O código fornecido representa apenas a base do software.

O verdadeiro desafio está na engenharia, operação e resiliência da plataforma.

---

# 📦 Conteinerização

- Criar Dockerfiles
- Otimizar imagens
- Implementar estratégias multi-stage build
- Reduzir vulnerabilidades

---

# ☁️ Infraestrutura como Código (Terraform)

Provisionar:

- Amazon EKS
- Amazon RDS
- Amazon ElastiCache
- Amazon SQS
- Amazon DynamoDB
- VPC, Subnets e Security Groups

## 💰 FinOps

Implementar:

- Tags estruturadas
- Controle de custos
- Rightsizing
- Budgets e alertas financeiros

---

# 🔄 CI/CD & GitOps

Automatizar:

- Testes
- Security Scans
- Build de imagens
- Deploy em Kubernetes

Ferramentas sugeridas:

- GitHub Actions
- ArgoCD
- FluxCD

---

# 📊 Observabilidade

Instrumentar os serviços utilizando:

- OpenTelemetry
- Distributed Tracing
- Métricas
- Logs estruturados

Ferramentas sugeridas:

- Grafana
- Prometheus
- Datadog
- New Relic

---

# 🛡️ SRE & Resiliência

Definir:

- SLIs
- SLOs
- Error Budgets
- Estratégias de Disaster Recovery
- Alertas inteligentes
- Health Checks
- Auto Healing

## 🔥 Foco Principal

O `donation-service` deve ser tratado como componente crítico da plataforma.

---

# 📚 Tecnologias Envolvidas

- Python
- Flask
- Go
- PostgreSQL
- DynamoDB
- AWS SQS
- Docker
- Kubernetes
- Terraform
- GitOps
- OpenTelemetry

---

# 🤝 Contribuição

Este projeto foi criado exclusivamente para fins educacionais e execução do Hackathon Fase 5.

Sinta-se livre para evoluir a arquitetura, melhorar a observabilidade e implementar boas práticas de engenharia de plataforma.

---

# 🏁 Boa sorte!

Bom Hackathon 🚀

Faça a diferença com a **SolidaryTech** 💙