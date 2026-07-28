"""
Exporta clientes (RD Station + Omie) para o padrão de importação da Toku.
Somente leitura (SELECT) — a query em sql/exportar_clientes_toku.sql não
grava nada em nenhuma das bases.

Uso:
    python exportar_clientes_toku.py
"""
import os
from datetime import datetime

import dotenv
import pandas as pd
import pyodbc
from openpyxl.styles import Alignment, Font
from openpyxl.utils import get_column_letter

dotenv.load_dotenv()

SQL_SERVER   = os.getenv("SQL_SERVER", "")
SQL_PORT     = os.getenv("SQL_PORT", "1433")
SQL_DATABASE = os.getenv("SQL_DATABASE", "")
SQL_USER     = os.getenv("SQL_USER", "")
SQL_PASSWORD = os.getenv("SQL_PASSWORD", "")
SQL_DRIVER   = os.getenv("SQL_DRIVER", "{ODBC Driver 18 for SQL Server}")

BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
SQL_FILE   = os.path.join(BASE_DIR, "sql", os.getenv("SQL_FILE_NAME", "exportar_clientes_toku.sql"))
OUTPUT_DIR = os.path.join(BASE_DIR, "exports")

COLUNAS_TEXTO = {"CPF OU CNPJ (SOMENTE NÚMEROS)", "CEP"}

# Layout padrão do modelo de importação da Toku (aba "Planilha1").
SHEET_NAME = "Planilha1"
HEADER_FONT = Font(name="Aptos Narrow", size=11)
HEADER_ALIGNMENT = Alignment(horizontal="center", vertical="center", wrap_text=True)
HEADER_ROW_HEIGHT = 38.5
COLUNA_LARGURAS = {
    "A": 13.1796875,
    "B": 19.81640625,
    "C": 8.90625,
    "D": 32.08984375,
    "E": 22.90625,
    "F": 11.453125,
    "G": 12.0,
    "H": 18.7265625,
}


def connect():
    # "tcp:" força o protocolo TCP/IP explicitamente — sem isso, alguns clientes
    # Windows tentam Named Pipes primeiro (configuração de protocolo do cliente)
    # e a conexão falha mesmo com a porta acessível.
    conn_str = (
        f"DRIVER={SQL_DRIVER};SERVER=tcp:{SQL_SERVER},{SQL_PORT};DATABASE={SQL_DATABASE};"
        f"UID={SQL_USER};PWD={SQL_PASSWORD};TrustServerCertificate=yes"
    )
    return pyodbc.connect(conn_str, timeout=30)


def carregar_query() -> str:
    with open(SQL_FILE, "r", encoding="utf-8") as f:
        return f.read()


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    query = carregar_query()

    print("Conectando ao SQL Server...")
    conn = connect()
    try:
        print("Executando query (pode levar alguns segundos)...")
        df = pd.read_sql(query, conn)
    finally:
        conn.close()

    print(f"{len(df)} clientes retornados.")
    campos_completo = ["CELULAR (PADRÃO E.164) Ex. +5548999567788", "CEP", "CIDADE", "CÓDIGO DO ESTADO"]
    if all(col in df.columns for col in campos_completo):
        prontos = int(df[campos_completo].notna().all(axis=1).sum())
        print(f"  - prontos para Toku: {prontos}")
        print(f"  - com alguma pendencia: {len(df) - prontos}")

    for col in COLUNAS_TEXTO:
        if col in df.columns:
            df[col] = df[col].astype("string")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_path = os.path.join(OUTPUT_DIR, f"clientes_toku_{timestamp}.xlsx")

    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        df.to_excel(writer, sheet_name=SHEET_NAME, index=False)
        ws = writer.sheets[SHEET_NAME]

        ws.row_dimensions[1].height = HEADER_ROW_HEIGHT
        for idx, col_name in enumerate(df.columns, start=1):
            letra = get_column_letter(idx)
            ws.column_dimensions[letra].width = COLUNA_LARGURAS.get(letra, 15)
            ws[f"{letra}1"].font = HEADER_FONT
            ws[f"{letra}1"].alignment = HEADER_ALIGNMENT
            if col_name in COLUNAS_TEXTO:
                for cell in ws[letra][1:]:
                    cell.number_format = "@"

    print(f"Arquivo gerado em: {output_path}")


if __name__ == "__main__":
    main()
