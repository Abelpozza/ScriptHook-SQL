-- Exportação de clientes (RD Station + Omie) para o padrão de importação da Toku.
-- Somente leitura (SELECT) em [WebHook-Rd-prd], [WebHook-omie-prd] e [energyClub-prd].
-- Nenhum CREATE/ALTER/UPDATE/DELETE. Nada é gravado em nenhuma das bases.

;WITH cfa AS (
    SELECT DealId,
        CAST(MAX(CASE WHEN Label = N'CPF/CNPJ' THEN Value END) AS NVARCHAR(50))   AS CpfCnpjRaw,
        CAST(MAX(CASE WHEN Label = N'Coop - E-mail para envio fatura' THEN Value END) AS NVARCHAR(500)) AS EmailRaw,
        CAST(MAX(CASE WHEN Label = N'Endereço - CEP' THEN Value END) AS NVARCHAR(30))    AS CepRaw,
        CAST(MAX(CASE WHEN Label = N'Endereço - Cidade' THEN Value END) AS NVARCHAR(100)) AS CidadeRaw,
        CAST(MAX(CASE WHEN Label = N'Endereço - Estado' THEN Value END) AS NVARCHAR(50))  AS EstadoRaw
    FROM [WebHook-Rd-prd].dbo.DealCustomFields
    WHERE Label IN (N'CPF/CNPJ', N'Coop - E-mail para envio fatura',
                    N'Endereço - CEP', N'Endereço - Cidade', N'Endereço - Estado')
    GROUP BY DealId
),

base AS (
    SELECT
        CAST(d.DealId AS NVARCHAR(100)) AS DealId,
        CAST(nome_tratado.nome AS NVARCHAR(500)) AS NomeDeal,
        -- Mesmo ambiente_id usado no cruzamento RD -> Omie em outras rotinas:
        -- pipeline "001. CGH APARECIDA" usa o ambiente 5, todo o resto usa o 2.
        CASE WHEN d.DealPipelineName = N'001. CGH APARECIDA' THEN 5 ELSE 2 END AS AmbienteId,
        cfa.CpfCnpjRaw, cfa.EmailRaw, cfa.CepRaw, cfa.CidadeRaw, cfa.EstadoRaw
    FROM [WebHook-Rd-prd].dbo.Deals d
    JOIN cfa ON cfa.DealId = d.Id
    CROSS APPLY (
        -- Posicao (1-based) do ULTIMO " - " no nome do Deal, ou NULL se nao existir.
        SELECT pos = CASE WHEN CHARINDEX(' - ', REVERSE(d.Name)) > 0
                          THEN LEN(d.Name) - CHARINDEX(' - ', REVERSE(d.Name)) - 1
                          ELSE NULL END
    ) p
    CROSS APPLY (
        SELECT sufixo = CASE WHEN p.pos IS NOT NULL THEN SUBSTRING(d.Name, p.pos + 3, 500) END
    ) s
    CROSS APPLY (
        -- Corta o que vem depois do ultimo " - " quando aquilo e so codigo de UC
        -- (numeros, "/", "-" e a sigla "UC"), ex.: "- UC 9/118-0", "- 23583569", "- 20/847426173".
        SELECT nome = CASE
                WHEN p.pos IS NOT NULL
                 AND REPLACE(UPPER(s.sufixo), 'UC', '') NOT LIKE '%[A-ZÀ-Ÿ]%'
                THEN LTRIM(RTRIM(LEFT(d.Name, p.pos - 1)))
                ELSE LTRIM(RTRIM(d.Name))
            END
    ) nome_tratado
    WHERE d.DeletedAt IS NULL
      AND ISNULL(d.DealStageName, '') NOT IN ('EXCLUIDOS', 'UNIDADES CLARO', 'UNIDADES DA OI')
      AND d.DealPipelineName NOT IN (
          N'Comercial GD', N'CONTROLE DE USINAS', N'CS', N'Escritório de Negócios',
          N'EXCLUIDOS', N'EXCLUIDOS 2', N'EXCLUIDOS 3', N'Prospecção de Usinas',
          N'Representantes', N'TROCA DE TITULARIDADE')
      -- Descarta nomes que, depois do tratamento acima, ficaram sem nenhuma letra
      -- (ou seja, o "nome" era so um codigo/numero de UC, sem nome de cliente real).
      AND nome_tratado.nome LIKE '%[A-Za-zÀ-ÿ]%'
),

docs_alvo AS (
    SELECT DISTINCT
        CAST(REPLACE(REPLACE(REPLACE(ISNULL(b.CpfCnpjRaw,''),'.',''),'-',''),'/','') AS VARCHAR(20)) AS doc,
        b.AmbienteId
    FROM base b
),

emails_alvo AS (
    SELECT DISTINCT CAST(LTRIM(RTRIM(b.EmailRaw)) AS NVARCHAR(150)) AS email
    FROM base b
    WHERE b.EmailRaw IS NOT NULL AND b.EmailRaw <> ''
),

contato_uni AS (
    SELECT ContactId, PrimaryEmail, PrimaryPhone
    FROM (
        SELECT CAST(c.ContactId AS NVARCHAR(50))    AS ContactId,
               CAST(c.PrimaryEmail AS NVARCHAR(150)) AS PrimaryEmail,
               CAST(c.PrimaryPhone AS NVARCHAR(40))  AS PrimaryPhone,
               ROW_NUMBER() OVER (PARTITION BY CAST(c.PrimaryEmail AS NVARCHAR(150))
                                  ORDER BY c.ContactUpdatedAt DESC) AS rn
        FROM [WebHook-Rd-prd].dbo.Contacts c
        INNER JOIN emails_alvo ea ON ea.email = CAST(c.PrimaryEmail AS NVARCHAR(150))
        WHERE c.DeletedAt IS NULL AND c.PrimaryEmail IS NOT NULL AND c.PrimaryEmail <> ''
    ) x
    WHERE x.rn = 1
),

contatos_alvo AS (
    SELECT DISTINCT ContactId FROM contato_uni WHERE ContactId IS NOT NULL
),

fone_uni AS (
    SELECT ContactId, Phone
    FROM (
        SELECT CAST(cp.ContactId AS NVARCHAR(50)) AS ContactId,
               CAST(cp.Phone AS NVARCHAR(40))     AS Phone,
               ROW_NUMBER() OVER (PARTITION BY CAST(cp.ContactId AS NVARCHAR(50))
                   ORDER BY CASE WHEN cp.PhoneType = 'cellphone' THEN 0 ELSE 1 END,
                            CASE WHEN cp.DeletedAt IS NULL THEN 0 ELSE 1 END,
                            cp.IsPrimary DESC, cp.UpdatedAtUtc DESC) AS rn
        FROM [WebHook-Rd-prd].dbo.ContactPhones cp
        INNER JOIN contatos_alvo ca ON ca.ContactId = CAST(cp.ContactId AS NVARCHAR(50))
        WHERE ISNULL(cp.PhoneType, '') <> 'fax'
          AND cp.Phone IS NOT NULL AND cp.Phone <> ''
    ) y
    WHERE y.rn = 1
),

email_sec AS (
    SELECT ContactId, STRING_AGG(Email, ';') AS Secundarios
    FROM (
        SELECT DISTINCT
               CAST(ce.ContactId AS NVARCHAR(50))                    AS ContactId,
               CAST(LOWER(LTRIM(RTRIM(ce.Email))) AS NVARCHAR(320))  AS Email
        FROM [WebHook-Rd-prd].dbo.ContactEmails ce
        INNER JOIN contatos_alvo ca ON ca.ContactId = CAST(ce.ContactId AS NVARCHAR(50))
        WHERE ce.DeletedAt IS NULL AND ce.IsPrimary = 0
          AND ce.Email IS NOT NULL AND ce.Email <> ''
    ) e
    GROUP BY ContactId
),

omie_uni AS (
    SELECT CpfCnpjNum, AmbienteId, cep_limpo, cidade, estado, telefone1_ddd, telefone1_numero
    FROM (
        SELECT CAST(REPLACE(REPLACE(REPLACE(cf.cnpj_cpf,'.',''),'-',''),'/','') AS VARCHAR(20)) AS CpfCnpjNum,
               cf.ambiente_id                          AS AmbienteId,
               CASE WHEN cf.cep IS NOT NULL
                     AND REPLACE(cf.cep,'-','') NOT LIKE '%[^0-9]%'
                     AND LEN(REPLACE(cf.cep,'-','')) = 8
                    THEN CAST(REPLACE(cf.cep,'-','') AS VARCHAR(8)) END AS cep_limpo,
               CAST(cf.cidade AS NVARCHAR(100))         AS cidade,
               CAST(cf.estado AS VARCHAR(10))           AS estado,
               CAST(REPLACE(REPLACE(cf.telefone1_ddd,' ',''),'-','') AS VARCHAR(5))     AS telefone1_ddd,
               CAST(REPLACE(REPLACE(cf.telefone1_numero,' ',''),'-','') AS VARCHAR(20)) AS telefone1_numero,
               ROW_NUMBER() OVER (
                   PARTITION BY CAST(REPLACE(REPLACE(REPLACE(cf.cnpj_cpf,'.',''),'-',''),'/','') AS VARCHAR(20)), cf.ambiente_id
                   ORDER BY cf.dataUltimaAtualizacao DESC) AS rn
        FROM [WebHook-omie-prd].dbo.cliente_fornecedor cf
        INNER JOIN docs_alvo da ON da.doc = CAST(REPLACE(REPLACE(REPLACE(cf.cnpj_cpf,'.',''),'-',''),'/','') AS VARCHAR(20))
                                AND da.AmbienteId = cf.ambiente_id
        WHERE cf.excluido = 0 AND cf.cnpj_cpf IS NOT NULL AND cf.cnpj_cpf <> ''
    ) o
    WHERE o.rn = 1
),

ceps_alvo AS (
    SELECT DISTINCT cep FROM (
        SELECT CASE WHEN b.CepRaw IS NOT NULL AND REPLACE(b.CepRaw,'-','') NOT LIKE '%[^0-9]%'
                     AND LEN(REPLACE(b.CepRaw,'-','')) = 8
                    THEN CAST(REPLACE(b.CepRaw,'-','') AS VARCHAR(8)) END AS cep
        FROM base b
        UNION ALL
        SELECT cep_limpo FROM omie_uni
    ) c
    WHERE c.cep IS NOT NULL
),

cep_tab AS (
    SELECT cep_num, uf, localidade
    FROM (
        SELECT CAST(REPLACE(REPLACE(ce.cep,'-',''),' ','') AS VARCHAR(8)) AS cep_num,
               CAST(ce.uf AS VARCHAR(2))           AS uf,
               CAST(ce.localidade AS NVARCHAR(100)) AS localidade,
               ROW_NUMBER() OVER (PARTITION BY CAST(REPLACE(REPLACE(ce.cep,'-',''),' ','') AS VARCHAR(8))
                                  ORDER BY ce.created_at DESC) AS rn
        FROM [energyClub-prd].[dbo].[CepEndereco] ce
        INNER JOIN ceps_alvo ca ON ca.cep = CAST(REPLACE(REPLACE(ce.cep,'-',''),' ','') AS VARCHAR(8))
        WHERE ce.cep IS NOT NULL
    ) z
    WHERE z.rn = 1
),

limpo AS (
    SELECT
        b.DealId, b.NomeDeal, b.AmbienteId,
        CAST(REPLACE(REPLACE(REPLACE(ISNULL(b.CpfCnpjRaw,''),'.',''),'-',''),'/','') AS VARCHAR(20)) AS doc,
        LTRIM(RTRIM(ISNULL(b.EmailRaw, ct.PrimaryEmail))) AS email,
        CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
             ISNULL(fu.Phone, ct.PrimaryPhone)
             ,' ',''),'.',''),'-',''),'/',''),'(',''),')',''),'+','')
             AS VARCHAR(40)) AS fone_rd,
        ct.ContactId,
        CASE WHEN b.CepRaw IS NOT NULL
              AND REPLACE(b.CepRaw,'-','') NOT LIKE '%[^0-9]%'
              AND LEN(REPLACE(b.CepRaw,'-','')) = 8
             THEN CAST(REPLACE(b.CepRaw,'-','') AS VARCHAR(8)) END AS rd_cep_limpo,
        b.CidadeRaw, b.EstadoRaw
    FROM base b
    LEFT JOIN contato_uni ct ON ct.PrimaryEmail = LTRIM(RTRIM(b.EmailRaw))
    LEFT JOIN fone_uni fu ON fu.ContactId = ct.ContactId
),

valida AS (
    SELECT l.*,
        CASE
            WHEN LEN(l.doc) = 11 AND l.doc NOT LIKE '%[^0-9]%' AND l.doc <> REPLICATE(LEFT(l.doc,1), 11)
            THEN
                CASE WHEN
                    CASE WHEN
                        (CAST(SUBSTRING(l.doc,1,1) AS INT)*10+CAST(SUBSTRING(l.doc,2,1) AS INT)*9
                        +CAST(SUBSTRING(l.doc,3,1) AS INT)*8+CAST(SUBSTRING(l.doc,4,1) AS INT)*7
                        +CAST(SUBSTRING(l.doc,5,1) AS INT)*6+CAST(SUBSTRING(l.doc,6,1) AS INT)*5
                        +CAST(SUBSTRING(l.doc,7,1) AS INT)*4+CAST(SUBSTRING(l.doc,8,1) AS INT)*3
                        +CAST(SUBSTRING(l.doc,9,1) AS INT)*2) % 11 < 2
                    THEN 0
                    ELSE 11 - ((CAST(SUBSTRING(l.doc,1,1) AS INT)*10+CAST(SUBSTRING(l.doc,2,1) AS INT)*9
                        +CAST(SUBSTRING(l.doc,3,1) AS INT)*8+CAST(SUBSTRING(l.doc,4,1) AS INT)*7
                        +CAST(SUBSTRING(l.doc,5,1) AS INT)*6+CAST(SUBSTRING(l.doc,6,1) AS INT)*5
                        +CAST(SUBSTRING(l.doc,7,1) AS INT)*4+CAST(SUBSTRING(l.doc,8,1) AS INT)*3
                        +CAST(SUBSTRING(l.doc,9,1) AS INT)*2) % 11)
                    END = CAST(SUBSTRING(l.doc,10,1) AS INT)
                AND
                    CASE WHEN
                        (CAST(SUBSTRING(l.doc,1,1) AS INT)*11+CAST(SUBSTRING(l.doc,2,1) AS INT)*10
                        +CAST(SUBSTRING(l.doc,3,1) AS INT)*9+CAST(SUBSTRING(l.doc,4,1) AS INT)*8
                        +CAST(SUBSTRING(l.doc,5,1) AS INT)*7+CAST(SUBSTRING(l.doc,6,1) AS INT)*6
                        +CAST(SUBSTRING(l.doc,7,1) AS INT)*5+CAST(SUBSTRING(l.doc,8,1) AS INT)*4
                        +CAST(SUBSTRING(l.doc,9,1) AS INT)*3+CAST(SUBSTRING(l.doc,10,1) AS INT)*2) % 11 < 2
                    THEN 0
                    ELSE 11 - ((CAST(SUBSTRING(l.doc,1,1) AS INT)*11+CAST(SUBSTRING(l.doc,2,1) AS INT)*10
                        +CAST(SUBSTRING(l.doc,3,1) AS INT)*9+CAST(SUBSTRING(l.doc,4,1) AS INT)*8
                        +CAST(SUBSTRING(l.doc,5,1) AS INT)*7+CAST(SUBSTRING(l.doc,6,1) AS INT)*6
                        +CAST(SUBSTRING(l.doc,7,1) AS INT)*5+CAST(SUBSTRING(l.doc,8,1) AS INT)*4
                        +CAST(SUBSTRING(l.doc,9,1) AS INT)*3+CAST(SUBSTRING(l.doc,10,1) AS INT)*2) % 11)
                    END = CAST(SUBSTRING(l.doc,11,1) AS INT)
                THEN 1 ELSE 0 END
            WHEN LEN(l.doc) = 14 AND l.doc NOT LIKE '%[^0-9]%' AND l.doc <> REPLICATE(LEFT(l.doc,1), 14)
            THEN
                CASE WHEN
                    CASE WHEN
                        (CAST(SUBSTRING(l.doc,1,1) AS INT)*5+CAST(SUBSTRING(l.doc,2,1) AS INT)*4
                        +CAST(SUBSTRING(l.doc,3,1) AS INT)*3+CAST(SUBSTRING(l.doc,4,1) AS INT)*2
                        +CAST(SUBSTRING(l.doc,5,1) AS INT)*9+CAST(SUBSTRING(l.doc,6,1) AS INT)*8
                        +CAST(SUBSTRING(l.doc,7,1) AS INT)*7+CAST(SUBSTRING(l.doc,8,1) AS INT)*6
                        +CAST(SUBSTRING(l.doc,9,1) AS INT)*5+CAST(SUBSTRING(l.doc,10,1) AS INT)*4
                        +CAST(SUBSTRING(l.doc,11,1) AS INT)*3+CAST(SUBSTRING(l.doc,12,1) AS INT)*2) % 11 < 2
                    THEN 0
                    ELSE 11 - ((CAST(SUBSTRING(l.doc,1,1) AS INT)*5+CAST(SUBSTRING(l.doc,2,1) AS INT)*4
                        +CAST(SUBSTRING(l.doc,3,1) AS INT)*3+CAST(SUBSTRING(l.doc,4,1) AS INT)*2
                        +CAST(SUBSTRING(l.doc,5,1) AS INT)*9+CAST(SUBSTRING(l.doc,6,1) AS INT)*8
                        +CAST(SUBSTRING(l.doc,7,1) AS INT)*7+CAST(SUBSTRING(l.doc,8,1) AS INT)*6
                        +CAST(SUBSTRING(l.doc,9,1) AS INT)*5+CAST(SUBSTRING(l.doc,10,1) AS INT)*4
                        +CAST(SUBSTRING(l.doc,11,1) AS INT)*3+CAST(SUBSTRING(l.doc,12,1) AS INT)*2) % 11)
                    END = CAST(SUBSTRING(l.doc,13,1) AS INT)
                AND
                    CASE WHEN
                        (CAST(SUBSTRING(l.doc,1,1) AS INT)*6+CAST(SUBSTRING(l.doc,2,1) AS INT)*5
                        +CAST(SUBSTRING(l.doc,3,1) AS INT)*4+CAST(SUBSTRING(l.doc,4,1) AS INT)*3
                        +CAST(SUBSTRING(l.doc,5,1) AS INT)*2+CAST(SUBSTRING(l.doc,6,1) AS INT)*9
                        +CAST(SUBSTRING(l.doc,7,1) AS INT)*8+CAST(SUBSTRING(l.doc,8,1) AS INT)*7
                        +CAST(SUBSTRING(l.doc,9,1) AS INT)*6+CAST(SUBSTRING(l.doc,10,1) AS INT)*5
                        +CAST(SUBSTRING(l.doc,11,1) AS INT)*4+CAST(SUBSTRING(l.doc,12,1) AS INT)*3
                        +CAST(SUBSTRING(l.doc,13,1) AS INT)*2) % 11 < 2
                    THEN 0
                    ELSE 11 - ((CAST(SUBSTRING(l.doc,1,1) AS INT)*6+CAST(SUBSTRING(l.doc,2,1) AS INT)*5
                        +CAST(SUBSTRING(l.doc,3,1) AS INT)*4+CAST(SUBSTRING(l.doc,4,1) AS INT)*3
                        +CAST(SUBSTRING(l.doc,5,1) AS INT)*2+CAST(SUBSTRING(l.doc,6,1) AS INT)*9
                        +CAST(SUBSTRING(l.doc,7,1) AS INT)*8+CAST(SUBSTRING(l.doc,8,1) AS INT)*7
                        +CAST(SUBSTRING(l.doc,9,1) AS INT)*6+CAST(SUBSTRING(l.doc,10,1) AS INT)*5
                        +CAST(SUBSTRING(l.doc,11,1) AS INT)*4+CAST(SUBSTRING(l.doc,12,1) AS INT)*3
                        +CAST(SUBSTRING(l.doc,13,1) AS INT)*2) % 11)
                    END = CAST(SUBSTRING(l.doc,14,1) AS INT)
                THEN 1 ELSE 0 END
            ELSE 0
        END AS doc_ok,
        CASE WHEN l.email LIKE '%_@_%.__%'
              AND l.email NOT LIKE '%[ ,;]%' AND l.email NOT LIKE '%@%@%'
              AND l.email NOT LIKE '.%' AND l.email NOT LIKE '%.' AND l.email NOT LIKE '%..%'
             THEN 1 ELSE 0 END AS email_ok
    FROM limpo l
),

formatado AS (
    SELECT v.DealId, v.NomeDeal AS NOME, v.doc AS CPF_CNPJ, LOWER(v.email) AS EMAIL,
           v.fone_rd, v.ContactId, v.rd_cep_limpo, v.CidadeRaw, v.EstadoRaw, v.AmbienteId
    FROM valida v
    WHERE v.doc_ok = 1 AND v.email_ok = 1
),

final_prep AS (
    SELECT
        f.DealId, f.NOME, f.CPF_CNPJ, f.EMAIL,
        es.Secundarios AS EMAILS_SECUNDARIOS,
        CAST(CASE
            WHEN fy.fixed_rd IS NOT NULL THEN '+55' + fy.fixed_rd
            WHEN fy.fixed_omie IS NOT NULL THEN '+55' + fy.fixed_omie
            ELSE NULL
        END AS VARCHAR(20)) AS CELULAR,
        CAST(COALESCE(f.rd_cep_limpo, o.cep_limpo) AS VARCHAR(8)) AS CEP,
        CAST(COALESCE(
            NULLIF(LTRIM(RTRIM(CASE WHEN LEFT(LTRIM(ISNULL(f.CidadeRaw,'')),1) IN ('/','-')
                THEN SUBSTRING(LTRIM(f.CidadeRaw),2,100) ELSE f.CidadeRaw END)), ''),
            ct.localidade, o.cidade) AS NVARCHAR(100)) AS CIDADE,
        CAST(COALESCE(
            CASE WHEN RIGHT(UPPER(LTRIM(RTRIM(ISNULL(f.EstadoRaw,'')))),2) IN
                ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG',
                 'PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO')
                THEN RIGHT(UPPER(LTRIM(RTRIM(f.EstadoRaw))),2) ELSE NULL END,
            ct.uf, UPPER(LEFT(o.estado,2))) AS VARCHAR(2)) AS CODIGO_ESTADO,
        CASE WHEN o.CpfCnpjNum IS NOT NULL THEN 'SIM' ELSE 'NAO' END AS CPF_NO_OMIE,
        CASE
            WHEN f.EMAIL LIKE '%@gmial.%' OR f.EMAIL LIKE '%@gmai.%' OR f.EMAIL LIKE '%@gmil.%'
                 OR f.EMAIL LIKE '%@gamil.%' OR f.EMAIL LIKE '%@gmal.%'
                THEN 'CONFERIR - PARECE GMAIL.COM'
            WHEN f.EMAIL LIKE '%@hotmial.%' OR f.EMAIL LIKE '%@hotnail.%'
                 OR f.EMAIL LIKE '%@hormail.%' OR f.EMAIL LIKE '%@hotmil.%'
                THEN 'CONFERIR - PARECE HOTMAIL.COM'
            WHEN f.EMAIL LIKE '%@outlok.%' OR f.EMAIL LIKE '%@outllok.%' OR f.EMAIL LIKE '%@outlool.%'
                THEN 'CONFERIR - PARECE OUTLOOK.COM'
            WHEN f.EMAIL LIKE '%@yahho.%' OR f.EMAIL LIKE '%@yaho.%'
                THEN 'CONFERIR - PARECE YAHOO'
            WHEN f.EMAIL LIKE '%.con' OR f.EMAIL LIKE '%.comm' OR f.EMAIL LIKE '%.cm'
                THEN 'CONFERIR - DOMINIO SUSPEITO'
            ELSE NULL
        END AS EMAIL_SUSPEITO
    FROM formatado f
    LEFT JOIN cep_tab ct ON ct.cep_num = f.rd_cep_limpo
    LEFT JOIN omie_uni o ON o.CpfCnpjNum = f.CPF_CNPJ AND o.AmbienteId = f.AmbienteId
    LEFT JOIN email_sec es ON es.ContactId = f.ContactId
    CROSS APPLY (
        SELECT
            local_rd = CASE
                WHEN f.fone_rd IS NOT NULL AND f.fone_rd NOT LIKE '%[^0-9]%' AND LEN(f.fone_rd) IN (10,11)
                    THEN f.fone_rd
                WHEN f.fone_rd IS NOT NULL AND f.fone_rd NOT LIKE '%[^0-9]%' AND LEN(f.fone_rd) IN (12,13) AND LEFT(f.fone_rd,2) = '55'
                    THEN SUBSTRING(f.fone_rd,3,11)
                ELSE NULL
            END,
            local_omie = CASE
                WHEN o.telefone1_ddd IS NOT NULL AND o.telefone1_numero IS NOT NULL
                     AND (o.telefone1_ddd + o.telefone1_numero) NOT LIKE '%[^0-9]%'
                     AND LEN(o.telefone1_ddd + o.telefone1_numero) IN (10,11)
                    THEN o.telefone1_ddd + o.telefone1_numero
                ELSE NULL
            END
    ) fx
    CROSS APPLY (
        SELECT
            fixed_rd = CASE
                WHEN fx.local_rd IS NULL THEN NULL
                WHEN LEN(fx.local_rd) = 11 THEN fx.local_rd
                WHEN LEN(fx.local_rd) = 10 AND SUBSTRING(fx.local_rd,3,1) IN ('6','7','8','9')
                    THEN LEFT(fx.local_rd,2) + '9' + SUBSTRING(fx.local_rd,3,8)
                ELSE fx.local_rd
            END,
            fixed_omie = CASE
                WHEN fx.local_omie IS NULL THEN NULL
                WHEN LEN(fx.local_omie) = 11 THEN fx.local_omie
                WHEN LEN(fx.local_omie) = 10 AND SUBSTRING(fx.local_omie,3,1) IN ('6','7','8','9')
                    THEN LEFT(fx.local_omie,2) + '9' + SUBSTRING(fx.local_omie,3,8)
                ELSE fx.local_omie
            END
    ) fy
),

dedup AS (
    SELECT fp.*,
        CASE WHEN fp.CELULAR IS NOT NULL AND fp.CEP IS NOT NULL AND fp.CIDADE IS NOT NULL AND fp.CODIGO_ESTADO IS NOT NULL
             THEN 1 ELSE 0 END AS completo,
        ROW_NUMBER() OVER (PARTITION BY fp.CPF_CNPJ
            ORDER BY
                CASE WHEN fp.CELULAR IS NOT NULL AND fp.CEP IS NOT NULL AND fp.CIDADE IS NOT NULL AND fp.CODIGO_ESTADO IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN fp.CELULAR IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN fp.CEP IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN fp.CIDADE IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN fp.CODIGO_ESTADO IS NOT NULL THEN 0 ELSE 1 END,
                fp.NOME) AS rn
    FROM final_prep fp
)
SELECT
    NOME,
    CPF_CNPJ           AS [CPF OU CNPJ (SOMENTE NÚMEROS)],
    EMAIL,
    EMAILS_SECUNDARIOS AS [E-MAILS SECUNDÁRIOS (SEPARADOS POR PONTO E VÍRGULA ";")],
    CELULAR            AS [CELULAR (PADRÃO E.164) Ex. +5548999567788],
    CEP,
    CIDADE,
    CODIGO_ESTADO      AS [CÓDIGO DO ESTADO]
FROM dedup
WHERE rn = 1
ORDER BY completo DESC, NOME
OPTION (MAXRECURSION 100);
