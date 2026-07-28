-- Extração simples de cliente_fornecedor (Omie). Somente leitura (SELECT).
-- Tabela pequena (~27k linhas): traz tudo de uma vez e o casamento com os
-- documentos dos Deals do RD é feito em Python (limpar_documento / merge em
-- montar_planilha_final). Testado na prática: filtrar aqui por
-- REPLACE(cf.cnpj_cpf,...) IN (?,?,...) é MUITO mais lento (a função no WHERE
-- impede uso de índice, e listas grandes de parâmetros travam o otimizador)
-- do que simplesmente ler a tabela inteira sem esse filtro.
-- Escolha do registro mais recente por (doc, ambiente) é feita em Python.
-- cf.email é usado como e-mail alternativo pra achar um segundo Contact no RD
-- quando o e-mail da fatura não bate com nenhum (montar_omie_email_uni).

SELECT
    cf.cnpj_cpf              AS CnpjCpf,
    cf.ambiente_id           AS AmbienteId,
    cf.cep                   AS Cep,
    cf.cidade                AS Cidade,
    cf.estado                AS Estado,
    cf.telefone1_ddd         AS Telefone1Ddd,
    cf.telefone1_numero      AS Telefone1Numero,
    cf.email                 AS Email,
    cf.dataUltimaAtualizacao AS DataUltimaAtualizacao
FROM [WebHook-omie-prd].dbo.cliente_fornecedor cf
WHERE cf.excluido = 0
  AND cf.cnpj_cpf IS NOT NULL AND cf.cnpj_cpf <> '';
