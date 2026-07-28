/*
    Cruza uma lista de clientes com pendência de telefone (RD) contra o
    cadastro do Omie (WebHook-omie-prd.dbo.cliente_fornecedor) para ver se
    o telefone existe lá.

    Somente leitura: a única tabela "escrita" é a #ListaPendencias, uma
    tabela temporária de sessão (tempdb) usada só para colar a lista de
    entrada — nenhuma tabela do RD ou do Omie é alterada.

    Como usar:
    1. Preencha o INSERT INTO #ListaPendencias abaixo com os CPF/CNPJ
       (com ou sem pontuação) dos clientes pendentes. O nome é opcional,
       só ajuda a ler o resultado.
    2. Rode o script inteiro de uma vez (a tabela temporária só existe
       durante a sessão/execução).
*/

IF OBJECT_ID('tempdb..#ListaPendencias') IS NOT NULL DROP TABLE #ListaPendencias;

CREATE TABLE #ListaPendencias (
    NomeCliente     NVARCHAR(200) NULL,
    CpfCnpjOriginal VARCHAR(30)   NOT NULL
);

-- >>> Cole aqui a lista de clientes com pendência de telefone <<<
INSERT INTO #ListaPendencias (NomeCliente, CpfCnpjOriginal) VALUES
    (N'Cliente Exemplo 1', '123.456.789-00'),
    (N'Cliente Exemplo 2', '12.345.678/0001-90');
    -- adicione uma linha por cliente

;WITH lista AS (
    SELECT
        NomeCliente,
        CpfCnpjOriginal,
        CAST(REPLACE(REPLACE(REPLACE(CpfCnpjOriginal, '.', ''), '-', ''), '/', '') AS VARCHAR(20)) AS CpfCnpjLimpo
    FROM #ListaPendencias
),
omie AS (
    SELECT
        CpfCnpjLimpo,
        AmbienteId,
        Telefone1Ddd,
        Telefone1Numero,
        cidade,
        estado,
        dataUltimaAtualizacao,
        ROW_NUMBER() OVER (
            PARTITION BY CpfCnpjLimpo, AmbienteId
            ORDER BY dataUltimaAtualizacao DESC
        ) AS rn
    FROM (
        SELECT
            CAST(REPLACE(REPLACE(REPLACE(cf.cnpj_cpf, '.', ''), '-', ''), '/', '') AS VARCHAR(20)) AS CpfCnpjLimpo,
            cf.ambiente_id AS AmbienteId,
            CAST(REPLACE(REPLACE(cf.telefone1_ddd, ' ', ''), '-', '') AS VARCHAR(5))     AS Telefone1Ddd,
            CAST(REPLACE(REPLACE(cf.telefone1_numero, ' ', ''), '-', '') AS VARCHAR(20)) AS Telefone1Numero,
            cf.cidade,
            cf.estado,
            cf.dataUltimaAtualizacao
        FROM [WebHook-omie-prd].dbo.cliente_fornecedor cf
        WHERE cf.excluido = 0
          AND cf.cnpj_cpf IS NOT NULL AND cf.cnpj_cpf <> ''
    ) c
),
resultado AS (
    SELECT
        l.NomeCliente,
        l.CpfCnpjOriginal,
        o.AmbienteId,
        CASE
            WHEN o.Telefone1Ddd IS NOT NULL AND o.Telefone1Numero IS NOT NULL
                 AND (o.Telefone1Ddd + o.Telefone1Numero) NOT LIKE '%[^0-9]%'
                 AND LEN(o.Telefone1Ddd + o.Telefone1Numero) IN (10, 11)
            THEN '+55' + o.Telefone1Ddd + o.Telefone1Numero
        END AS TelefoneEncontradoOmie,
        o.cidade,
        o.estado,
        o.dataUltimaAtualizacao,
        ROW_NUMBER() OVER (
            PARTITION BY l.CpfCnpjLimpo
            ORDER BY CASE WHEN o.Telefone1Ddd IS NOT NULL THEN 0 ELSE 1 END, o.dataUltimaAtualizacao DESC
        ) AS OrdemPorCliente
    FROM lista l
    LEFT JOIN omie o ON o.CpfCnpjLimpo = l.CpfCnpjLimpo AND o.rn = 1
)
SELECT
    NomeCliente,
    CpfCnpjOriginal,
    AmbienteId,
    TelefoneEncontradoOmie,
    cidade,
    estado,
    dataUltimaAtualizacao,
    CASE WHEN OrdemPorCliente = 1 THEN 1 ELSE 0 END AS MelhorOpcao
FROM resultado
ORDER BY NomeCliente, OrdemPorCliente;
