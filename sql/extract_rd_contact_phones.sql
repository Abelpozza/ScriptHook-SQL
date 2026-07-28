-- Extração simples de ContactPhones (RD Station). Somente leitura (SELECT).
-- {IN_LIST} é substituído em Python por (?,?,?,...) com os ContactId do lote atual.
-- Escolha do telefone preferido por contato é feita em Python (mais_recente()).

SELECT
    CAST(cp.ContactId AS NVARCHAR(50)) AS ContactId,
    CAST(cp.Phone AS NVARCHAR(40))     AS Phone,
    cp.PhoneType  AS PhoneType,
    cp.IsPrimary  AS IsPrimary,
    cp.DeletedAt  AS DeletedAt,
    cp.UpdatedAtUtc AS UpdatedAtUtc
FROM [WebHook-Rd-prd].dbo.ContactPhones cp
WHERE ISNULL(cp.PhoneType, '') <> 'fax'
  AND cp.Phone IS NOT NULL AND cp.Phone <> ''
  AND CAST(cp.ContactId AS NVARCHAR(50)) IN ({IN_LIST});
