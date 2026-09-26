#!/usr/bin/env python3
import os
import markdown

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

DOCS = [
    ("1. Pitch Executivo", "docs/pitch-executivo.md"),
    ("2. Evolucao do Projeto", "docs/evolucao-projeto.md"),
    ("3. Decisoes Tecnicas", "docs/decisoes-tecnicas.md"),
    ("4. Plano de Continuidade de Negocios", "docs/PCN.md"),
    ("5. SRE - SLO, SLI e SLA", "docs/SLO-SLI-SLA.md"),
    ("6. ITSM e AIOps", "docs/ITSM-lifecycle.md"),
    ("7. FinOps e Forecast", "docs/finops-forecast.md"),
    ("8. README do Projeto", "README.md"),
]

TEAM = [
    ("Diego Felipe Rocha Silva", "rm369588", "diegofeliperochasilva@gmail.com"),
    ("Erick Saraiva de Sousa", "rm369969", "ericksaraiva27@gmail.com"),
    ("Jhousyfran Muniz Costa", "rm369476", "jhousyfrancosta@gmail.com"),
    ("Regis Teruo Nomi", "rm369601", "regis.nomi@gmail.com"),
    ("Yuri Jose do Carmo", "rm370037", "yjcarmo@gmail.com"),
]

CSS = """
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=Fira+Code:wght@400;500&display=swap');

:root {
    --primary: #1a365d;
    --primary-light: #2c5282;
    --accent: #2b6cb0;
    --bg: #ffffff;
    --text: #1a202c;
    --text-secondary: #4a5568;
    --border: #e2e8f0;
    --code-bg: #f7fafc;
    --table-stripe: #f7fafc;
    --success: #38a169;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    font-size: 11pt;
    line-height: 1.7;
    color: var(--text);
    background: var(--bg);
}

/* Cover page */
.cover-page {
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    text-align: center;
    padding: 60px 40px;
    page-break-after: always;
    background: linear-gradient(135deg, #1a365d 0%, #2c5282 50%, #2b6cb0 100%);
    color: white;
}

.cover-page .institution {
    font-size: 14pt;
    font-weight: 300;
    letter-spacing: 3px;
    text-transform: uppercase;
    margin-bottom: 10px;
    opacity: 0.9;
}

.cover-page .course {
    font-size: 11pt;
    font-weight: 300;
    letter-spacing: 2px;
    text-transform: uppercase;
    margin-bottom: 60px;
    opacity: 0.8;
}

.cover-page .title {
    font-size: 36pt;
    font-weight: 700;
    margin-bottom: 15px;
    letter-spacing: 1px;
}

.cover-page .subtitle {
    font-size: 14pt;
    font-weight: 300;
    margin-bottom: 60px;
    opacity: 0.9;
    max-width: 600px;
}

.cover-page .divider {
    width: 80px;
    height: 3px;
    background: rgba(255,255,255,0.5);
    margin: 0 auto 40px;
}

.cover-page .date {
    font-size: 12pt;
    font-weight: 300;
    margin-bottom: 50px;
    opacity: 0.8;
}

.cover-team {
    margin-top: 20px;
    width: 100%;
    max-width: 600px;
}

.cover-team h3 {
    font-size: 12pt;
    font-weight: 500;
    letter-spacing: 2px;
    text-transform: uppercase;
    margin-bottom: 15px;
    opacity: 0.9;
}

.cover-team table {
    width: 100%;
    border-collapse: collapse;
    font-size: 10pt;
}

.cover-team th {
    background: rgba(255,255,255,0.15);
    color: white;
    padding: 8px 12px;
    text-align: left;
    font-weight: 500;
    border-bottom: 1px solid rgba(255,255,255,0.2);
}

.cover-team td {
    padding: 7px 12px;
    border-bottom: 1px solid rgba(255,255,255,0.1);
    color: rgba(255,255,255,0.9);
}

.cover-team tr:nth-child(even) td {
    background: rgba(255,255,255,0.05);
}

/* Table of contents */
.toc-page {
    padding: 60px 60px;
    page-break-after: always;
}

.toc-page h2 {
    font-size: 22pt;
    color: var(--primary);
    margin-bottom: 30px;
    padding-bottom: 10px;
    border-bottom: 3px solid var(--primary);
}

.toc-page ol {
    list-style: none;
    counter-reset: toc-counter;
    padding: 0;
}

.toc-page li {
    counter-increment: toc-counter;
    padding: 12px 0;
    border-bottom: 1px dotted var(--border);
    font-size: 13pt;
}

.toc-page li::before {
    content: counter(toc-counter) ".";
    font-weight: 600;
    color: var(--primary);
    margin-right: 12px;
    display: inline-block;
    width: 30px;
}

.toc-page li a {
    color: var(--text);
    text-decoration: none;
}

/* Document chapters */
.chapter {
    padding: 50px 60px;
    page-break-before: always;
}

.chapter h1 {
    font-size: 22pt;
    color: var(--primary);
    margin-bottom: 8px;
    padding-bottom: 10px;
    border-bottom: 3px solid var(--primary);
    line-height: 1.3;
}

.chapter h2 {
    font-size: 16pt;
    color: var(--primary);
    margin-top: 28px;
    margin-bottom: 12px;
    padding-bottom: 6px;
    border-bottom: 1px solid var(--border);
}

.chapter h3 {
    font-size: 13pt;
    color: var(--primary-light);
    margin-top: 22px;
    margin-bottom: 10px;
}

.chapter h4 {
    font-size: 11pt;
    color: var(--accent);
    margin-top: 18px;
    margin-bottom: 8px;
}

.chapter p {
    margin-bottom: 12px;
    text-align: justify;
}

.chapter ul, .chapter ol {
    margin-bottom: 12px;
    padding-left: 24px;
}

.chapter li {
    margin-bottom: 4px;
}

.chapter blockquote {
    border-left: 4px solid var(--accent);
    padding: 12px 20px;
    margin: 16px 0;
    background: #ebf8ff;
    color: var(--text-secondary);
    font-style: italic;
    border-radius: 0 4px 4px 0;
}

.chapter hr {
    border: none;
    border-top: 1px solid var(--border);
    margin: 24px 0;
}

/* Tables */
.chapter table {
    width: 100%;
    border-collapse: collapse;
    margin: 16px 0;
    font-size: 9.5pt;
}

.chapter th {
    background: var(--primary);
    color: white;
    padding: 8px 10px;
    text-align: left;
    font-weight: 500;
    font-size: 9pt;
}

.chapter td {
    padding: 7px 10px;
    border-bottom: 1px solid var(--border);
    vertical-align: top;
}

.chapter tr:nth-child(even) td {
    background: var(--table-stripe);
}

.chapter tr:hover td {
    background: #edf2f7;
}

/* Code */
.chapter code {
    font-family: 'Fira Code', 'Consolas', 'Monaco', monospace;
    font-size: 9pt;
    background: var(--code-bg);
    padding: 2px 5px;
    border-radius: 3px;
    border: 1px solid var(--border);
}

.chapter pre {
    background: #1a202c;
    color: #e2e8f0;
    padding: 16px 20px;
    border-radius: 6px;
    overflow-x: auto;
    margin: 16px 0;
    font-size: 8.5pt;
    line-height: 1.5;
}

.chapter pre code {
    background: none;
    border: none;
    padding: 0;
    color: inherit;
    font-size: inherit;
}

/* Strong and emphasis */
.chapter strong {
    color: var(--primary);
    font-weight: 600;
}

/* Mermaid blocks — render as preformatted */
.chapter pre code.language-mermaid {
    color: #e2e8f0;
}

/* Print styles */
@media print {
    body { font-size: 10pt; }

    .cover-page {
        min-height: auto;
        height: 100vh;
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }

    .chapter { page-break-before: always; padding: 40px 50px; }
    .toc-page { page-break-after: always; }

    .chapter pre { white-space: pre-wrap; word-wrap: break-word; }

    .chapter table { page-break-inside: avoid; }
    .chapter h2, .chapter h3 { page-break-after: avoid; }

    .chapter th {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }

    .cover-team th, .cover-team td {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}

@page {
    size: A4;
    margin: 15mm;
}
"""


def build_team_table():
    rows = ""
    for name, rm, email in TEAM:
        rows += f"<tr><td>{name}</td><td>{rm}</td><td>{email}</td></tr>\n"
    return f"""
    <div class="cover-team">
        <h3>Equipe</h3>
        <table>
            <thead><tr><th>Nome</th><th>RM</th><th>Email</th></tr></thead>
            <tbody>{rows}</tbody>
        </table>
    </div>
    """


def build_cover():
    return f"""
    <div class="cover-page">
        <div class="institution">FIAP Pos Tech</div>
        <div class="course">Arquitetura Cloud e DevOps</div>
        <div class="divider"></div>
        <div class="title">Hackathon SolidaryTech</div>
        <div class="subtitle">Plataforma de Doacoes para ONGs &mdash; Documento Tecnico Completo</div>
        <div class="date">Setembro 2026</div>
        {build_team_table()}
    </div>
    """


def build_toc():
    items = ""
    for i, (title, _) in enumerate(DOCS, 1):
        items += f'<li><a href="#chapter-{i}">{title}</a></li>\n'
    return f"""
    <div class="toc-page">
        <h2>Sumario</h2>
        <ol>{items}</ol>
    </div>
    """


def convert_md(filepath):
    import re
    with open(filepath, "r", encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r'\[([^\]]+)\]\(docs/[^)]+\)', r'\1', text)
    text = re.sub(r'\[([^\]]+)\]\(\./[^)]+\)', r'\1', text)
    md = markdown.Markdown(extensions=["tables", "toc", "fenced_code"])
    return md.convert(text)


def build_chapters():
    html = ""
    for i, (title, relpath) in enumerate(DOCS, 1):
        fullpath = os.path.join(PROJECT_ROOT, relpath)
        content = convert_md(fullpath)
        html += f'<div class="chapter" id="chapter-{i}">\n{content}\n</div>\n'
    return html


def main():
    page = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SolidaryTech - Documento Tecnico Completo</title>
    <style>{CSS}</style>
</head>
<body>
{build_cover()}
{build_toc()}
{build_chapters()}
</body>
</html>"""

    outpath = os.path.join(PROJECT_ROOT, "docs", "SolidaryTech-Documento-Completo.html")
    with open(outpath, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"HTML gerado: {outpath}")


if __name__ == "__main__":
    main()
