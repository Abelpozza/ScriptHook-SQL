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
from openpyxl.utils import get_column_letter

dotenv.load_dotenv()

SQL_SERVER   = os.getenv("SQL_SERVER", "")
SQL_DATABASE = os.getenv("SQL_DATABASE", "")
SQL_USER     = os.getenv("SQL_USER", "")
SQL_PASSWORD = os.getenv("SQL_PASSWORD", "")
SQL_DRIVER   = os.getenv("SQL_DRIVER", "{ODBC Driver 18 for SQL Server}")

BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
SQL_FILE   = os.path.join(BASE_DIR, "sql", os.getenv("SQL_FILE_NAME", "exportar_clientes_toku.sql"))
OUTPUT_DIR = os.path.join(BASE_DIR, "exports")

COLUNAS_TEXTO = {"CPF OU CNPJ (SOMENTE NÚMEROS)", "CEP"}


def connect():
    conn_str = (
        f"DRIVER={SQL_DRIVER};SERVER={SQL_SERVER};DATABASE={SQL_DATABASE};"
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
    if "completo" in df.columns:
        prontos = int(df["completo"].sum())
        print(f"  - prontos para Toku: {prontos}")
        print(f"  - com alguma pendencia: {len(df) - prontos}")

    for col in COLUNAS_TEXTO:
        if col in df.columns:
            df[col] = df[col].astype("string")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_path = os.path.join(OUTPUT_DIR, f"clientes_toku_{timestamp}.xlsx")

    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        df.to_excel(writer, sheet_name="clientes", index=False)
        ws = writer.sheets["clientes"]
        for idx, col_name in enumerate(df.columns, start=1):
            if col_name in COLUNAS_TEXTO:
                letra = get_column_letter(idx)
                for cell in ws[letra][1:]:
                    cell.number_format = "@"

    print(f"Arquivo gerado em: {output_path}")


if __name__ == "__main__":
    main()
