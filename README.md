# ScriptHook-SQL

Script de exportação de clientes (RD Station + Omie) para o padrão de importação da **Toku**, em formato Excel.

## O que o script faz

Cruza dados de três bases somente leitura:

- **RD Station** (`WebHook-Rd-prd`): Deals, campos customizados do Deal (CPF/CNPJ, e-mail de fatura, endereço), Contacts, telefones e e-mails secundários de Contacts.
- **Omie** (`WebHook-omie-prd`): tabela `cliente_fornecedor` (documento, endereço, telefones, e-mail de cadastro).
- **energyClub** (`CepEndereco`): tabela de CEP/cidade/UF usada como referência quando o endereço do RD/Omie está incompleto.

O resultado é uma planilha com nome, CPF/CNPJ, e-mail, e-mails secundários, celular (formato E.164), CEP, cidade e UF — pronta para importação na Toku.

**Nenhuma das consultas grava dado algum.** Todas são `SELECT`; não há `CREATE`/`INSERT`/`UPDATE`/`DELETE` em nenhum ponto do projeto.

## Arquitetura

- `sql/extract_*.sql` — extrações simples (um `SELECT` por tabela/necessidade), sem lógica de negócio.
- `tratamento_clientes_toku.py` — todo o tratamento de dados (parsing de nome, validação de CPF/CNPJ com dígito verificador, validação de e-mail, formatação de telefone em E.164, limpeza de CEP/cidade/UF, deduplicação) feito em Python/pandas/regex.
- `exportar_clientes_toku.py` — orquestra a extração e gera o Excel final.

Esse desenho substitui uma versão anterior que fazia tudo em uma única query SQL monolítica (`sql/exportar_clientes_toku.sql`, mantida no repositório só como referência histórica, sem uso ativo). Mover o tratamento para Python deixou a lógica de negócio mais fácil de ler, testar e ajustar do que CTEs SQL aninhadas.

### Por que ler tabelas inteiras em vez de filtrar no SQL

`cliente_fornecedor` (Omie) e `CepEndereco` (energyClub) são lidas por completo, sem filtro por documento/CEP. Testado na prática: filtrar essas tabelas por uma coluna normalizada com `REPLACE(coluna, ...)` combinada com uma lista `IN (?,?,?,...)` de centenas/milhares de valores faz o otimizador do SQL Server travar por horas. Como as duas tabelas são pequenas/estreitas, ler tudo de uma vez e casar os dados em pandas é muito mais rápido (segundos, não horas).

### Recuperação de telefone via e-mail alternativo

Quando o contato do RD encontrado pelo e-mail da fatura não tem telefone cadastrado, o script tenta um segundo contato usando o e-mail de cadastro do cliente no Omie (que pode ser diferente do e-mail da fatura — ex.: e-mail pessoal vs. e-mail da empresa). Esse fallback só é usado quando o e-mail do Omie é **exclusivo de um único cliente** na base Omie — e-mails compartilhados por múltiplos documentos (ex.: contador, síndico, escritório de contabilidade que cadastra vários clientes com o mesmo e-mail) são descartados, para não atribuir o telefone de um terceiro ao cliente errado.

## Uso

```
python exportar_clientes_toku.py            # carga completa
python exportar_clientes_toku.py --teste    # limita Deals a TOP 1000, para validar antes da carga completa
```

O arquivo é gerado em `exports/clientes_toku_<timestamp>.xlsx`.

## Configuração

Crie um arquivo `.env` na raiz do projeto (não é versionado — veja `.gitignore`) com:

```
SQL_SERVER=
SQL_PORT=1433
SQL_DATABASE=
SQL_USER=
SQL_PASSWORD=
SQL_DRIVER={ODBC Driver 18 for SQL Server}
```

Requer o [ODBC Driver 18 for SQL Server](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server) instalado.

## Dependências

`pandas`, `pyodbc`, `python-dotenv`, `openpyxl`.
