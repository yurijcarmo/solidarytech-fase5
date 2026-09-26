from datetime import datetime, timezone
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


class Donation(db.Model):
    __tablename__ = "donations"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    donor_name = db.Column(db.String(255), nullable=False)
    donor_email = db.Column(db.String(255), nullable=False)
    ngo_id = db.Column(db.Integer, nullable=False)
    amount = db.Column(db.Numeric(12, 2), nullable=False)
    original_amount = db.Column(db.Numeric(12, 2))
    original_currency = db.Column(db.String(3), default="BRL")
    currency = db.Column(db.String(3), default="BRL")
    payment_method = db.Column(db.String(50), nullable=False)
    status = db.Column(db.String(20), default="pending")
    transaction_id = db.Column(db.String(100), unique=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    processed_at = db.Column(db.DateTime)

    def to_dict(self):
        return {
            "id": self.id,
            "donor_name": self.donor_name,
            "donor_email": self.donor_email,
            "ngo_id": self.ngo_id,
            "amount": float(self.amount),
            "original_amount": float(self.original_amount) if self.original_amount else float(self.amount),
            "original_currency": self.original_currency or self.currency,
            "currency": self.currency,
            "payment_method": self.payment_method,
            "status": self.status,
            "transaction_id": self.transaction_id,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "processed_at": self.processed_at.isoformat() if self.processed_at else None,
        }
