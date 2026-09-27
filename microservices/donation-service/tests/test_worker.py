import json
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

import worker


def _tracer():
    tracer = MagicMock()
    tracer.start_as_current_span.return_value.__enter__.return_value = MagicMock()
    return tracer


def test_process_donation_updates_same_audit_record(monkeypatch):
    session = MagicMock()
    donation = SimpleNamespace(
        id=1,
        payment_method="pix",
        status="pending",
        processed_at=None,
    )
    session.query.return_value.filter_by.return_value.first.return_value = donation

    monkeypatch.setattr(worker, "authorize_payment", lambda *_args: {
        "status": "APPROVED",
        "approved": True,
        "authorization_code": "AUTH-123",
    })

    dynamo_table = MagicMock()
    message = json.dumps({
        "donation_id": 1,
        "transaction_id": "tx-123",
        "amount": 100.0,
        "original_currency": "BRL",
        "audit_created_at": "2026-09-26T20:00:00+00:00",
        "trace_context": {},
    })

    result = worker.process_donation(session, _tracer(), message, dynamo_table)

    assert result == "completed"
    assert donation.status == "completed"
    key = dynamo_table.update_item.call_args.kwargs["Key"]
    assert key == {
        "transaction_id": "tx-123",
        "created_at": "2026-09-26T20:00:00+00:00",
    }


def test_process_donation_missing_record_is_retriable():
    session = MagicMock()
    session.query.return_value.filter_by.return_value.first.return_value = None
    message = json.dumps({
        "donation_id": 404,
        "transaction_id": "tx-missing",
        "amount": 100.0,
        "original_currency": "BRL",
        "trace_context": {},
    })

    with pytest.raises(LookupError):
        worker.process_donation(session, _tracer(), message)
