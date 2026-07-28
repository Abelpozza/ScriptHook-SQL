-- Extração simples de ContactEmails (RD Station). Somente leitura (SELECT).
-- {IN_LIST} é substituído em Python por (?,?,?,...) com os ContactId do lote atual.
-- Agregação em ";" dos e-mails secundários por contato é feita em Python.

SELECT
    CAST(ce.ContactId AS NVARCHAR(50)) AS ContactId,
    ce.Email     AS Email
FROM [WebHook-Rd-prd].dbo.ContactEmails ce
WHERE ce.DeletedAt IS NULL
  AND ce.IsPrimary = 0
  AND ce.Email IS NOT NULL AND ce.Email <> ''
  AND CAST(ce.ContactId AS NVARCHAR(50)) IN ({IN_LIST});
