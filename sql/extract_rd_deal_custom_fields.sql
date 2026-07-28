-- Extração simples de DealCustomFields (RD Station). Somente leitura (SELECT).
-- {IN_LIST} é substituído em Python por (?,?,?,...) com os DealId do lote atual.
-- Sem pivot aqui — o pivot por Label é feito em Python (tratamento_clientes_toku.py).

SELECT
    CAST(cf.DealId AS NVARCHAR(100)) AS DealId,
    cf.Label  AS Label,
    cf.Value  AS Value
FROM [WebHook-Rd-prd].dbo.DealCustomFields cf
WHERE cf.Label IN (N'CPF/CNPJ', N'Coop - E-mail para envio fatura',
                    N'Endereço - CEP', N'Endereço - Cidade', N'Endereço - Estado')
  AND CAST(cf.DealId AS NVARCHAR(100)) IN ({IN_LIST});
