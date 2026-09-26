CREATE SCHEMA IF NOT EXISTS solidarytech;

CREATE TABLE IF NOT EXISTS ngos (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    cnpj VARCHAR(18) UNIQUE NOT NULL,
    description TEXT,
    category VARCHAR(100),
    contact_email VARCHAR(255),
    phone VARCHAR(20),
    address TEXT,
    city VARCHAR(100),
    state VARCHAR(2),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS donations (
    id SERIAL PRIMARY KEY,
    donor_name VARCHAR(255) NOT NULL,
    donor_email VARCHAR(255),
    ngo_id INTEGER REFERENCES ngos(id),
    amount DECIMAL(12,2) NOT NULL,
    original_amount DECIMAL(12,2),
    original_currency VARCHAR(3) DEFAULT 'BRL',
    currency VARCHAR(3) DEFAULT 'BRL',
    payment_method VARCHAR(50),
    status VARCHAR(20) DEFAULT 'pending',
    transaction_id VARCHAR(100) UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS volunteers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20),
    skills TEXT[],
    city VARCHAR(100),
    state VARCHAR(2),
    available BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS campaigns (
    id SERIAL PRIMARY KEY,
    ngo_id INTEGER REFERENCES ngos(id),
    title VARCHAR(255) NOT NULL,
    description TEXT,
    required_skills TEXT[],
    city VARCHAR(100),
    state VARCHAR(2),
    start_date DATE,
    end_date DATE,
    max_volunteers INTEGER DEFAULT 10,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS matches (
    id SERIAL PRIMARY KEY,
    volunteer_id INTEGER REFERENCES volunteers(id),
    campaign_id INTEGER REFERENCES campaigns(id),
    status VARCHAR(20) DEFAULT 'pending',
    matched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(volunteer_id, campaign_id)
);

CREATE INDEX idx_donations_status ON donations(status);
CREATE INDEX idx_donations_ngo_id ON donations(ngo_id);
CREATE INDEX idx_donations_created_at ON donations(created_at);
CREATE INDEX idx_volunteers_city_state ON volunteers(city, state);
CREATE INDEX idx_campaigns_active ON campaigns(active);
CREATE INDEX idx_matches_status ON matches(status);

INSERT INTO ngos (name, cnpj, description, category, contact_email, city, state, active)
VALUES
    ('Instituto Esperanca', '12.345.678/0001-01', 'ONG focada em educacao infantil', 'Educacao', 'contato@esperanca.org', 'Sao Paulo', 'SP', true),
    ('Amigos do Bem', '98.765.432/0001-02', 'Combate a fome no nordeste brasileiro', 'Alimentacao', 'contato@amigosbem.org', 'Recife', 'PE', true),
    ('Verde Vida', '11.222.333/0001-03', 'Preservacao ambiental e reflorestamento', 'Meio Ambiente', 'contato@verdevida.org', 'Manaus', 'AM', true);
