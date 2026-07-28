-- Extração simples de Deals (RD Station). Somente leitura (SELECT).
-- Sem tratamento de dados aqui — nome, CPF/CNPJ, e-mail etc. são limpos em Python
-- (tratamento_clientes_toku.py). O marcador /*TOP_N*/ é substituído por
-- "TOP 1000" no modo --teste, ou removido em produção.

SELECT /*TOP_N*/
    CAST(d.Id AS NVARCHAR(100)) AS DealId,
    d.Name               AS Name,
    d.DealPipelineName   AS DealPipelineName,
    d.DealStageName       AS DealStageName
FROM [WebHook-Rd-prd].dbo.Deals d
WHERE d.DeletedAt IS NULL
  AND ISNULL(d.DealStageName, '') NOT IN ('EXCLUIDOS', 'UNIDADES CLARO', 'UNIDADES DA OI')
  AND d.DealPipelineName NOT IN (
      N'Comercial GD', N'CONTROLE DE USINAS', N'CS', N'Escritório de Negócios',
      N'EXCLUIDOS', N'EXCLUIDOS 2', N'EXCLUIDOS 3', N'Prospecção de Usinas',
      N'Representantes', N'TROCA DE TITULARIDADE');
