from datetime import datetime, timezone

from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


class Volunteer(db.Model):
    __tablename__ = "volunteers"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    name = db.Column(db.String(255), nullable=False)
    email = db.Column(db.String(255), nullable=False)
    phone = db.Column(db.String(20))
    skills = db.Column(db.Text, default="")
    city = db.Column(db.String(100))
    state = db.Column(db.String(2))
    available = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        skills_list = [s.strip() for s in (self.skills or "").split(",") if s.strip()]
        return {
            "id": self.id,
            "name": self.name,
            "email": self.email,
            "phone": self.phone or "",
            "skills": skills_list,
            "city": self.city or "",
            "state": self.state or "",
            "available": self.available,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class Campaign(db.Model):
    __tablename__ = "campaigns"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    ngo_id = db.Column(db.Integer, nullable=False)
    title = db.Column(db.String(255), nullable=False)
    description = db.Column(db.Text)
    required_skills = db.Column(db.Text, default="")
    city = db.Column(db.String(100))
    state = db.Column(db.String(2))
    start_date = db.Column(db.String(20))
    end_date = db.Column(db.String(20))
    max_volunteers = db.Column(db.Integer, default=10)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        skills_list = [s.strip() for s in (self.required_skills or "").split(",") if s.strip()]
        return {
            "id": self.id,
            "ngo_id": self.ngo_id,
            "title": self.title,
            "description": self.description or "",
            "required_skills": skills_list,
            "city": self.city or "",
            "state": self.state or "",
            "start_date": self.start_date,
            "end_date": self.end_date,
            "max_volunteers": self.max_volunteers,
            "active": self.active,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class Match(db.Model):
    __tablename__ = "matches"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    volunteer_id = db.Column(db.Integer, nullable=False)
    campaign_id = db.Column(db.Integer, nullable=False)
    status = db.Column(db.String(20), default="pending")
    matched_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            "id": self.id,
            "volunteer_id": self.volunteer_id,
            "campaign_id": self.campaign_id,
            "status": self.status,
            "matched_at": self.matched_at.isoformat() if self.matched_at else None,
        }
