-- Extração simples de CepEndereco (energyClub). Somente leitura (SELECT).
-- Tabela com ~1,2M linhas mas estreita (4 colunas): traz tudo de uma vez e o
-- casamento com os CEPs dos Deals do RD/Omie é feito em Python (limpar_cep /
-- merge em montar_planilha_final). Testado na prática: ler a tabela inteira
-- (~2-3s) é MUITO mais rápido do que filtrar por
-- REPLACE(ce.cep,...) IN (?,?,...) em lotes — a função no WHERE impede uso de
-- índice, e com listas grandes de parâmetros o otimizador travava por horas.
-- Escolha do registro mais recente por CEP é feita em Python.

SELECT
    ce.cep        AS Cep,
    ce.uf         AS Uf,
    ce.localidade AS Localidade,
    ce.created_at AS CreatedAt
FROM [energyClub-prd].[dbo].[CepEndereco] ce
WHERE ce.cep IS NOT NULL;
