from datetime import datetime, timezone
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


class NGO(db.Model):
    __tablename__ = "ngos"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    name = db.Column(db.String(255), nullable=False)
    cnpj = db.Column(db.String(18), unique=True, nullable=False)
    description = db.Column(db.Text)
    category = db.Column(db.String(100))
    contact_email = db.Column(db.String(255), nullable=False)
    phone = db.Column(db.String(20))
    address = db.Column(db.String(500))
    city = db.Column(db.String(100))
    state = db.Column(db.String(2))
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = db.Column(
        db.DateTime, default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )
    active = db.Column(db.Boolean, default=True)

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "cnpj": self.cnpj,
            "description": self.description,
            "category": self.category,
            "contact_email": self.contact_email,
            "phone": self.phone,
            "address": self.address,
            "city": self.city,
            "state": self.state,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "active": self.active,
        }
