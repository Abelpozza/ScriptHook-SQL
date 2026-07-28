-- Extração simples de Contacts (RD Station). Somente leitura (SELECT).
-- Tabela pequena (~85k linhas): traz tudo de uma vez (mais rápido do que
-- buscar por lote de e-mail, mesmo padrão de extract_omie_clientes.sql), pois
-- agora um Deal pode precisar casar tanto pelo e-mail da fatura quanto por um
-- e-mail alternativo do Omie (ver montar_planilha_final).
-- Escolha do contato mais recente por e-mail é feita em Python (mais_recente()).

SELECT
    CAST(c.ContactId AS NVARCHAR(50))     AS ContactId,
    CAST(c.PrimaryEmail AS NVARCHAR(150)) AS PrimaryEmail,
    CAST(c.PrimaryPhone AS NVARCHAR(40))  AS PrimaryPhone,
    c.ContactUpdatedAt AS ContactUpdatedAt
FROM [WebHook-Rd-prd].dbo.Contacts c
WHERE c.DeletedAt IS NULL
  AND c.PrimaryEmail IS NOT NULL AND c.PrimaryEmail <> '';
