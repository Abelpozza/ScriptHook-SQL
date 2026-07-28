"""
Tratamento de dados para a exportação de clientes (RD Station + Omie) no
padrão de importação da Toku.

Este módulo concentra toda a limpeza/validação/formatação que antes vivia em
CTEs de sql/exportar_clientes_toku.sql (parsing de nome, dígito verificador
de CPF/CNPJ, validação de e-mail, formatação de telefone em E.164, limpeza
de cidade/UF, deduplicação). As extrações em sql/extract_*.sql são só
SELECTs simples — todo o tratamento abaixo é feito em pandas/regex.
"""
import re

import numpy as np
import pandas as pd

# Mesmo padrão usado em outras rotinas para separar o nome do cliente de um
# código de UC no fim do Deal (ex.: "CLIENTE X - UC 9/118-0", "- 23583569").
_TRACO_UC = re.compile(
    r'^(uc[\s:\-]*)?\d[\d.\-/\s]*$',
    re.IGNORECASE,
)
_TEM_LETRA = re.compile(r'[A-Za-zÀ-ÿ]')
_TEL_CHARS_RE = re.compile(r'[ ./\-()+]')
_SOMENTE_DIGITOS_RE = re.compile(r'^\d+$')
_EMAIL_FORMATO_RE = re.compile(r'^.+@.+\..{2,}$')

_UFS = {
    'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG',
    'PA', 'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO',
}

_DOMINIOS_SUSPEITOS = [
    (('@gmial.', '@gmai.', '@gmil.', '@gamil.', '@gmal.'), 'CONFERIR - PARECE GMAIL.COM'),
    (('@hotmial.', '@hotnail.', '@hormail.', '@hotmil.'), 'CONFERIR - PARECE HOTMAIL.COM'),
    (('@outlok.', '@outllok.', '@outlool.'), 'CONFERIR - PARECE OUTLOOK.COM'),
    (('@yahho.', '@yaho.'), 'CONFERIR - PARECE YAHOO'),
]
_SUFIXOS_SUSPEITOS = ('.con', '.comm', '.cm')

LABEL_PARA_COLUNA = {
    'CPF/CNPJ': 'CpfCnpjRaw',
    'Coop - E-mail para envio fatura': 'EmailRaw',
    'Endereço - CEP': 'CepRaw',
    'Endereço - Cidade': 'CidadeRaw',
    'Endereço - Estado': 'EstadoRaw',
}


# --------------------------------------------------------------------------
# Funções de limpeza/validação
# --------------------------------------------------------------------------

def _texto_ou_none(valor):
    if not isinstance(valor, str):
        return None
    valor = valor.strip()
    return valor or None


def limpar_nome_deal(nome):
    """Corta o sufixo de código de UC no fim do nome do Deal, se houver."""
    if not isinstance(nome, str):
        return None
    nome = nome.strip()
    prefixo, _, sufixo = nome.rpartition(' - ')
    if prefixo and _TRACO_UC.fullmatch(sufixo.strip()):
        return prefixo.strip()
    return nome


def tem_letra(texto):
    return isinstance(texto, str) and bool(_TEM_LETRA.search(texto))


def limpar_documento(raw):
    if not isinstance(raw, str):
        return ''
    return re.sub(r'[.\-/]', '', raw)


def _valida_cpf(doc):
    if len(doc) != 11 or not doc.isdigit() or doc == doc[0] * 11:
        return False
    nums = [int(d) for d in doc]
    soma = sum(n * p for n, p in zip(nums[:9], range(10, 1, -1)))
    resto = soma % 11
    dv1 = 0 if resto < 2 else 11 - resto
    if dv1 != nums[9]:
        return False
    soma = sum(n * p for n, p in zip(nums[:10], range(11, 1, -1)))
    resto = soma % 11
    dv2 = 0 if resto < 2 else 11 - resto
    return dv2 == nums[10]


def _valida_cnpj(doc):
    if len(doc) != 14 or not doc.isdigit() or doc == doc[0] * 14:
        return False
    nums = [int(d) for d in doc]
    pesos1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
    soma = sum(n * p for n, p in zip(nums[:12], pesos1))
    resto = soma % 11
    dv1 = 0 if resto < 2 else 11 - resto
    if dv1 != nums[12]:
        return False
    pesos2 = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
    soma = sum(n * p for n, p in zip(nums[:13], pesos2))
    resto = soma % 11
    dv2 = 0 if resto < 2 else 11 - resto
    return dv2 == nums[13]


def documento_valido(doc):
    if not doc:
        return False
    if len(doc) == 11:
        return _valida_cpf(doc)
    if len(doc) == 14:
        return _valida_cnpj(doc)
    return False


def email_valido(email):
    if not isinstance(email, str) or not email:
        return False
    if not _EMAIL_FORMATO_RE.match(email):
        return False
    if any(c in email for c in ' ,;'):
        return False
    if email.count('@') != 1:
        return False
    if email.startswith('.') or email.endswith('.') or '..' in email:
        return False
    return True


def email_suspeito(email):
    if not isinstance(email, str) or not email:
        return None
    email = email.lower()
    for trechos, mensagem in _DOMINIOS_SUSPEITOS:
        if any(trecho in email for trecho in trechos):
            return mensagem
    if email.endswith(_SUFIXOS_SUSPEITOS):
        return 'CONFERIR - DOMINIO SUSPEITO'
    return None


def normalizar_telefone(raw):
    if not isinstance(raw, str):
        return None
    limpo = _TEL_CHARS_RE.sub('', raw)
    return limpo or None


def limpar_telefone_omie(raw):
    if not isinstance(raw, str):
        return None
    return raw.replace(' ', '').replace('-', '') or None


def _numero_local(digitos):
    if not digitos or not _SOMENTE_DIGITOS_RE.match(digitos):
        return None
    if len(digitos) in (10, 11):
        return digitos
    if len(digitos) in (12, 13) and digitos.startswith('55'):
        return digitos[2:13]
    return None


def _corrigir_nono_digito(local):
    if local is None:
        return None
    if len(local) == 11:
        return local
    if len(local) == 10 and local[2] in '6789':
        return local[:2] + '9' + local[2:]
    return local


def celular_e164(fone_rd, telefone1_ddd, telefone1_numero, fone_rd_alt=None):
    """Formata o melhor telefone disponível em E.164 (+55...), na ordem:
    contato do RD achado pelo e-mail da fatura > contato do RD achado por um
    e-mail alternativo do Omie (fone_rd_alt) > telefone1 do Omie."""
    local_rd = _numero_local(fone_rd if isinstance(fone_rd, str) else None)
    local_rd_alt = _numero_local(fone_rd_alt if isinstance(fone_rd_alt, str) else None)
    ddd = telefone1_ddd if isinstance(telefone1_ddd, str) else None
    numero = telefone1_numero if isinstance(telefone1_numero, str) else None
    local_omie = _numero_local(f'{ddd}{numero}') if ddd and numero else None

    fixed_rd = _corrigir_nono_digito(local_rd)
    fixed_rd_alt = _corrigir_nono_digito(local_rd_alt)
    fixed_omie = _corrigir_nono_digito(local_omie)
    if fixed_rd:
        return f'+55{fixed_rd}'
    if fixed_rd_alt:
        return f'+55{fixed_rd_alt}'
    if fixed_omie:
        return f'+55{fixed_omie}'
    return None


def limpar_cep(raw):
    """CEP validado: só dígitos e 8 caracteres após remover '-'."""
    if not isinstance(raw, str):
        return None
    limpo = raw.replace('-', '')
    return limpo if len(limpo) == 8 and limpo.isdigit() else None


def limpar_cep_bruto(raw):
    """Normalização simples (sem validar) do CEP vindo do CepEndereco."""
    if not isinstance(raw, str):
        return None
    return raw.replace('-', '').replace(' ', '') or None


def limpar_cidade(raw):
    if not isinstance(raw, str):
        return None
    valor = raw.lstrip()
    if valor[:1] in ('/', '-'):
        valor = valor[1:]
    valor = valor.strip()
    return valor or None


def extrair_uf(raw):
    if not isinstance(raw, str) or not raw.strip():
        return None
    uf = raw.strip().upper()[-2:]
    return uf if uf in _UFS else None


def mais_recente(df, chave, colunas_ordenacao, ascendente):
    """Substitui ROW_NUMBER() OVER (PARTITION BY chave ORDER BY ...) = 1."""
    if df.empty:
        return df
    return (
        df.sort_values(by=colunas_ordenacao, ascending=ascendente)
        .drop_duplicates(subset=chave, keep='first')
        .reset_index(drop=True)
    )


# --------------------------------------------------------------------------
# Montagem dos DataFrames intermediários (equivalentes às CTEs da query antiga)
# --------------------------------------------------------------------------

def montar_base(df_deals, df_custom_fields):
    """Equivalente às CTEs `cfa` + `base`: um Deal por linha, já com nome
    tratado, ambiente_id e documento/CEP limpos."""
    pivot = (
        df_custom_fields
        .pivot_table(index='DealId', columns='Label', values='Value', aggfunc='max')
        .reset_index()
    )
    pivot = pivot.rename(columns=LABEL_PARA_COLUNA)
    for coluna in LABEL_PARA_COLUNA.values():
        if coluna not in pivot.columns:
            pivot[coluna] = None

    base = df_deals.merge(pivot, on='DealId', how='inner')

    base['NomeDeal'] = base['Name'].apply(limpar_nome_deal)
    base['AmbienteId'] = np.where(base['DealPipelineName'] == '001. CGH APARECIDA', 5, 2)
    base = base[base['NomeDeal'].apply(tem_letra)].copy()

    base['doc'] = base['CpfCnpjRaw'].apply(limpar_documento)
    base['EmailRaw'] = base['EmailRaw'].apply(_texto_ou_none)
    base['rd_cep_limpo'] = base['CepRaw'].apply(limpar_cep)

    return base[[
        'DealId', 'NomeDeal', 'AmbienteId', 'doc', 'EmailRaw',
        'CidadeRaw', 'EstadoRaw', 'rd_cep_limpo',
    ]]


def contact_ids_para_buscar(contato_uni):
    return sorted(contato_uni['ContactId'].dropna().unique().tolist())


def montar_contato_uni(df_contacts):
    """Equivalente à CTE `contato_uni`: contato mais recente por e-mail."""
    if df_contacts.empty:
        return pd.DataFrame(columns=['ContactId', 'PrimaryEmail', 'PrimaryPhone'])
    dedup = mais_recente(
        df_contacts, chave='PrimaryEmail',
        colunas_ordenacao=['ContactUpdatedAt'], ascendente=[False],
    )
    return dedup[['ContactId', 'PrimaryEmail', 'PrimaryPhone']]


def montar_fone_uni(df_contact_phones):
    """Equivalente à CTE `fone_uni`: celular > ativo > primário > mais recente."""
    if df_contact_phones.empty:
        return pd.DataFrame(columns=['ContactId', 'Phone'])
    df = df_contact_phones.copy()
    df['_prioridade_tipo'] = np.where(df['PhoneType'] == 'cellphone', 0, 1)
    df['_prioridade_ativo'] = np.where(df['DeletedAt'].isna(), 0, 1)
    dedup = mais_recente(
        df, chave='ContactId',
        colunas_ordenacao=['_prioridade_tipo', '_prioridade_ativo', 'IsPrimary', 'UpdatedAtUtc'],
        ascendente=[True, True, False, False],
    )
    return dedup[['ContactId', 'Phone']]


def montar_email_secundario(df_contact_emails):
    """Equivalente à CTE `email_sec`: e-mails secundários agregados por ';'."""
    if df_contact_emails.empty:
        return pd.DataFrame(columns=['ContactId', 'Secundarios'])
    df = df_contact_emails.copy()
    df['Email'] = df['Email'].str.strip().str.lower()
    df = df.drop_duplicates(subset=['ContactId', 'Email'])
    agrupado = df.groupby('ContactId')['Email'].apply(lambda s: ';'.join(s)).reset_index()
    return agrupado.rename(columns={'Email': 'Secundarios'})


def montar_omie_uni(df_omie):
    """Equivalente à CTE `omie_uni`: registro mais recente por (doc, ambiente)."""
    colunas = [
        'Doc', 'AmbienteId', 'OmieCepLimpo', 'OmieCidade', 'OmieEstado',
        'OmieTelefone1Ddd', 'OmieTelefone1Numero',
    ]
    if df_omie.empty:
        return pd.DataFrame(columns=colunas)
    df = df_omie.copy()
    df['Doc'] = df['CnpjCpf'].apply(limpar_documento)
    df['OmieCepLimpo'] = df['Cep'].apply(limpar_cep)
    df['OmieCidade'] = df['Cidade']
    df['OmieEstado'] = df['Estado']
    df['OmieTelefone1Ddd'] = df['Telefone1Ddd'].apply(limpar_telefone_omie)
    df['OmieTelefone1Numero'] = df['Telefone1Numero'].apply(limpar_telefone_omie)
    dedup = mais_recente(
        df, chave=['Doc', 'AmbienteId'],
        colunas_ordenacao=['DataUltimaAtualizacao'], ascendente=[False],
    )
    return dedup[colunas]


def montar_omie_email_uni(df_omie):
    """E-mail de cadastro mais recente por doc no Omie, com uma flag indicando
    se esse e-mail é exclusivo de um único documento no Omie. Serve para achar
    um segundo Contact no RD quando o e-mail da fatura não bate com nenhum
    (ver montar_planilha_final). Um e-mail usado por 2+ documentos diferentes
    costuma ser de contador/síndico/intermediário — nesse caso o telefone
    encontrado seria dessa outra pessoa, não do cliente, e não deve ser usado."""
    colunas = ['doc', 'OmieEmail', 'OmieEmailExclusivo']
    if df_omie.empty:
        return pd.DataFrame(columns=colunas)
    df = df_omie.copy()
    df['doc'] = df['CnpjCpf'].apply(limpar_documento)
    df['OmieEmail'] = df['Email'].apply(_texto_ou_none)
    df = df[df['OmieEmail'].notna()]
    if df.empty:
        return pd.DataFrame(columns=colunas)
    contagem_docs_por_email = df.groupby('OmieEmail')['doc'].nunique()
    df['OmieEmailExclusivo'] = df['OmieEmail'].map(contagem_docs_por_email).eq(1)
    dedup = mais_recente(df, chave='doc', colunas_ordenacao=['DataUltimaAtualizacao'], ascendente=[False])
    return dedup[colunas]


def montar_cep_tab(df_cep):
    """Equivalente à CTE `cep_tab`: registro mais recente por CEP."""
    colunas = ['CepNum', 'CepTabUf', 'CepTabLocalidade']
    if df_cep.empty:
        return pd.DataFrame(columns=colunas)
    df = df_cep.copy()
    df['CepNum'] = df['Cep'].apply(limpar_cep_bruto)
    df['CepTabUf'] = df['Uf']
    df['CepTabLocalidade'] = df['Localidade']
    dedup = mais_recente(df, chave='CepNum', colunas_ordenacao=['CreatedAt'], ascendente=[False])
    return dedup[colunas]


# --------------------------------------------------------------------------
# Montagem final (equivalente a limpo -> valida -> formatado -> final_prep -> dedup)
# --------------------------------------------------------------------------

COLUNAS_SAIDA = {
    'CPF_CNPJ': 'CPF OU CNPJ (SOMENTE NÚMEROS)',
    'EMAILS_SECUNDARIOS': 'E-MAILS SECUNDÁRIOS (SEPARADOS POR PONTO E VÍRGULA ";")',
    'CELULAR': 'CELULAR (PADRÃO E.164) Ex. +5548999567788',
    'CODIGO_ESTADO': 'CÓDIGO DO ESTADO',
}


def montar_planilha_final(base, contato_uni, fone_uni, email_secundario, omie_uni, cep_tab, omie_email_uni):
    limpo = base.merge(contato_uni, left_on='EmailRaw', right_on='PrimaryEmail', how='left')
    limpo = limpo.merge(fone_uni, on='ContactId', how='left')

    limpo['email'] = limpo['EmailRaw']
    limpo['fone_raw'] = limpo['Phone'].where(limpo['Phone'].notna(), limpo['PrimaryPhone'])
    limpo['fone_rd'] = limpo['fone_raw'].apply(normalizar_telefone)

    # Contato do RD achado pelo e-mail da fatura pode nao ter telefone porque o
    # cliente cadastrou um e-mail diferente (pessoal) como principal no RD. Se o
    # Omie tiver um e-mail de cadastro exclusivo desse cliente (nao compartilhado
    # com outro doc), tenta achar um SEGUNDO contato no RD por esse e-mail.
    limpo = limpo.merge(omie_email_uni, on='doc', how='left')
    usar_email_alt = limpo['OmieEmailExclusivo'].fillna(False) & (limpo['OmieEmail'] != limpo['EmailRaw'])

    contato_alt = contato_uni.rename(columns={
        'ContactId': 'ContactIdAlt', 'PrimaryEmail': 'OmieEmail', 'PrimaryPhone': 'PrimaryPhoneAlt',
    })
    limpo = limpo.merge(contato_alt, on='OmieEmail', how='left')
    fone_uni_alt = fone_uni.rename(columns={'ContactId': 'ContactIdAlt', 'Phone': 'PhoneAlt'})
    limpo = limpo.merge(fone_uni_alt, on='ContactIdAlt', how='left')

    limpo['fone_raw_alt'] = limpo['PhoneAlt'].where(limpo['PhoneAlt'].notna(), limpo['PrimaryPhoneAlt'])
    limpo['fone_rd_alt'] = limpo['fone_raw_alt'].where(usar_email_alt).apply(normalizar_telefone)

    limpo['doc_ok'] = limpo['doc'].apply(documento_valido)
    limpo['email_ok'] = limpo['email'].apply(email_valido)

    formatado = limpo[limpo['doc_ok'] & limpo['email_ok']].copy()
    formatado['NOME'] = formatado['NomeDeal']
    formatado['CPF_CNPJ'] = formatado['doc']
    formatado['EMAIL'] = formatado['email'].str.lower()

    final_prep = formatado.merge(cep_tab, left_on='rd_cep_limpo', right_on='CepNum', how='left')
    final_prep = final_prep.merge(
        omie_uni, left_on=['CPF_CNPJ', 'AmbienteId'], right_on=['Doc', 'AmbienteId'], how='left',
    )
    final_prep = final_prep.merge(email_secundario, on='ContactId', how='left')

    final_prep['EMAILS_SECUNDARIOS'] = final_prep['Secundarios']
    final_prep['CELULAR'] = final_prep.apply(
        lambda r: celular_e164(
            r['fone_rd'], r.get('OmieTelefone1Ddd'), r.get('OmieTelefone1Numero'), r.get('fone_rd_alt'),
        ),
        axis=1,
    )
    final_prep['CEP'] = final_prep['rd_cep_limpo'].where(
        final_prep['rd_cep_limpo'].notna(), final_prep['OmieCepLimpo'],
    )
    final_prep['CIDADE'] = (
        final_prep['CidadeRaw'].apply(limpar_cidade)
        .combine_first(final_prep['CepTabLocalidade'])
        .combine_first(final_prep['OmieCidade'])
    )
    final_prep['CODIGO_ESTADO'] = (
        final_prep['EstadoRaw'].apply(extrair_uf)
        .combine_first(final_prep['CepTabUf'])
        .combine_first(final_prep['OmieEstado'].apply(lambda v: v.upper()[:2] if isinstance(v, str) else None))
    )
    final_prep['CPF_NO_OMIE'] = np.where(final_prep['Doc'].notna(), 'SIM', 'NAO')
    final_prep['EMAIL_SUSPEITO'] = final_prep['EMAIL'].apply(email_suspeito)

    resultado = final_prep[[
        'NOME', 'CPF_CNPJ', 'EMAIL', 'EMAILS_SECUNDARIOS', 'CELULAR', 'CEP', 'CIDADE', 'CODIGO_ESTADO',
    ]].copy()

    resultado['tem_celular'] = resultado['CELULAR'].notna()
    resultado['tem_cep'] = resultado['CEP'].notna()
    resultado['tem_cidade'] = resultado['CIDADE'].notna()
    resultado['tem_uf'] = resultado['CODIGO_ESTADO'].notna()
    resultado['completo'] = (
        resultado['tem_celular'] & resultado['tem_cep'] & resultado['tem_cidade'] & resultado['tem_uf']
    )

    resultado = resultado.sort_values(
        by=['completo', 'tem_celular', 'tem_cep', 'tem_cidade', 'tem_uf', 'NOME'],
        ascending=[False, False, False, False, False, True],
    )
    resultado = resultado.drop_duplicates(subset='CPF_CNPJ', keep='first')
    resultado = resultado.sort_values(by=['completo', 'NOME'], ascending=[False, True])

    resultado = resultado.drop(columns=['tem_celular', 'tem_cep', 'tem_cidade', 'tem_uf', 'completo'])
    resultado = resultado.rename(columns=COLUNAS_SAIDA).reset_index(drop=True)
    return resultado[[
        'NOME', COLUNAS_SAIDA['CPF_CNPJ'], 'EMAIL', COLUNAS_SAIDA['EMAILS_SECUNDARIOS'],
        COLUNAS_SAIDA['CELULAR'], 'CEP', 'CIDADE', COLUNAS_SAIDA['CODIGO_ESTADO'],
    ]]
