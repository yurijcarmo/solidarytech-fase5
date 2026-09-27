# Incident Lifecycle - SolidaryTech

## Fluxo

```text
Falha
  |
  v
Prometheus
  |
  | detecta condicao
  v
Alertmanager
  |
  +--------------------------+
  |                          |
  v                          v
Incident Receiver      Self-Healing
notificacao/registro   somente quando autorizado
  |                          |
  +-------------+------------+
                |
                v
           Recuperacao
                |
                v
       Validacao por SLIs/SLO
                |
                v
             Resolved
                |
                v
          Automated RCA
                |
                v
           Post-Mortem
                |
                v
        Acoes Preventivas
```

## Detect

Prometheus avalia metricas e regras de alerta.

## Notify

Alertmanager agrupa, roteia e encaminha alertas.

## Triage

O incidente e classificado de acordo com severidade, impacto e servico afetado.

## Mitigate

O time utiliza runbooks ou remediacao automatica controlada.

## Recover

O servico retorna ao estado saudavel.

## Validate

SLIs, SLOs, metricas, logs e traces sao utilizados para confirmar a recuperacao.

## Resolve

O Alertmanager envia o estado `resolved` ao receiver de incidentes.

## Learn

O RCA coleta evidencias para apoiar a investigacao da causa raiz.

Incidentes relevantes geram post-mortem e acoes preventivas.

## MTTR

A automacao reduz partes do tempo total de recuperacao:

- deteccao automatica reduz tempo para perceber a falha;
- Alertmanager reduz tempo para encaminhar o incidente;
- runbooks reduzem tempo de diagnostico e decisao;
- self-healing pode reduzir tempo de mitigacao;
- observabilidade reduz tempo de validacao da recuperacao.
