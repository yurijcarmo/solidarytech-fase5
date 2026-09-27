# Runbook - DonationWorkerStalled

## Objetivo

Orientar a investigacao e recuperacao quando o donation-worker deixa de consultar a fila SQS ou fica indisponivel.

## Alerta

- Nome: `DonationWorkerStalled`
- Servico: `donation-worker`
- Severidade: `critical`

O alerta e acionado quando:

- o Prometheus nao consegue acessar o worker; ou
- o worker permanece sem polling bem-sucedido do SQS acima do limite configurado.

## 1. Confirmar o incidente

Verificar o alerta no Prometheus:

```bash
curl -s http://localhost:9091/api/v1/alerts | python3 -m json.tool
```

Verificar disponibilidade do worker:

```bash
curl -sG http://localhost:9091/api/v1/query \
  --data-urlencode 'query=up{job="donation-worker"}' \
  | python3 -m json.tool
```

## 2. Verificar o worker

No ambiente local:

```bash
docker compose ps donation-worker
docker compose logs donation-worker --tail=100
```

No Kubernetes:

```bash
kubectl get pods -n solidarytech
kubectl get deployments -n solidarytech
```

## 3. Verificar dependencia SQS

Confirmar se a fila esta disponivel e se existem mensagens acumuladas.

No ambiente local:

```bash
docker compose exec localstack awslocal sqs list-queues
```

## 4. Recuperacao

Se o worker estiver parado no ambiente local:

```bash
docker compose up -d donation-worker
```

No Kubernetes, seguir a politica de remediacao controlada. Apenas alertas explicitamente autorizados podem acionar self-healing.

## 5. Validar a recuperacao

Confirmar que o worker voltou:

```bash
curl -sG http://localhost:9091/api/v1/query \
  --data-urlencode 'query=up{job="donation-worker"}' \
  | python3 -m json.tool
```

O valor esperado e `1`.

Confirmar que o alerta foi resolvido:

```bash
curl -s http://localhost:9091/api/v1/alerts | python3 -m json.tool
```

Confirmar o evento `resolved` no receiver:

```bash
docker compose logs incident-receiver --tail=200
```

## 6. Pos-incidente

Se o incidente for relevante ou recorrente:

1. Executar o RCA automatizado para coleta de evidencias.
2. Identificar a causa raiz.
3. Registrar timeline e impacto.
4. Aplicar os 5 Whys quando necessario.
5. Criar acoes preventivas.
6. Atualizar este runbook se houver novo aprendizado.

## Escalonamento

Escalar para investigacao manual quando:

- o worker nao recuperar;
- houver recorrencia;
- houver falha de SQS ou banco;
- houver erro de permissao;
- o Error Budget estiver sendo consumido rapidamente.
