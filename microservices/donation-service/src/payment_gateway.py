import logging
import os
import random
import time
import uuid

from opentelemetry import trace

SERVICE_NAME = os.getenv("SERVICE_NAME", "donation-service")
logger = logging.getLogger(SERVICE_NAME)
tracer = trace.get_tracer("payment-gateway")

RESPONSE_CODES = {
    "APPROVED": "Transacao autorizada com sucesso",
    "DECLINED": "Transacao recusada pelo emissor",
    "INSUFFICIENT_FUNDS": "Saldo insuficiente",
    "TIMEOUT": "Tempo limite excedido na autorizadora",
    "FRAUD_SUSPECT": "Transacao bloqueada por suspeita de fraude",
}


def authorize_payment(amount, currency, payment_method):
    with tracer.start_as_current_span("payment_gateway.authorize") as span:
        span.set_attribute("payment.amount", float(amount))
        span.set_attribute("payment.currency", currency)
        span.set_attribute("payment.method", payment_method)

        latency = random.uniform(0.1, 0.3)
        time.sleep(latency)

        span.set_attribute("payment.gateway_latency_ms", round(latency * 1000, 1))

        roll = random.random()

        if roll < 0.92:
            status = "APPROVED"
            authorization_code = f"AUTH-{uuid.uuid4().hex[:12].upper()}"
        elif roll < 0.95:
            status = "DECLINED"
            authorization_code = None
        elif roll < 0.97:
            status = "INSUFFICIENT_FUNDS"
            authorization_code = None
        elif roll < 0.99:
            status = "FRAUD_SUSPECT"
            authorization_code = None
        else:
            status = "TIMEOUT"
            authorization_code = None
            time.sleep(random.uniform(0.5, 1.0))

        approved = status == "APPROVED"

        span.set_attribute("payment.status", status)
        span.set_attribute("payment.approved", approved)
        if authorization_code:
            span.set_attribute("payment.authorization_code", authorization_code)
        if not approved:
            span.set_attribute("error", True)

        result = {
            "status": status,
            "approved": approved,
            "message": RESPONSE_CODES[status],
            "authorization_code": authorization_code,
            "gateway_latency_ms": round(latency * 1000, 1),
        }

        logger.info(
            "Payment gateway: amount=%.2f %s method=%s status=%s auth=%s",
            float(amount), currency, payment_method,
            status, authorization_code or "N/A",
        )

        return result
