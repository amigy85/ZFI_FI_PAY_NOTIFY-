# Implementação — Notificação de Pagamentos a Fornecedores (HCB)

Complemento ao `Dossier_Tecnico_Notificacoes_Pagamentos_SAP_HCB.md`.
Análise feita em leitura no ECC HCB (cliente 010) a 2026-11-18, via ADT.

---

## 1. Diagnóstico: o que acontece dentro de `RBNK_IMPORT_PAYM_STATUS_REPORT`

Cadeia de chamadas **confirmada no código standard**:

```
RBNK_IMPORT_PAYM_STATUS_REPORT
 └─ CL_BNK_PROCESS_PAIN002=>PROCESS_PAIN002        (XSLT PAIN002 -> CPON)
     ├─ BAdI BNK_SPLIT_FILE_2_PSRS->SPLIT_PSR_FILE  (só divide ficheiros; opcional)
     └─ CALL_CPON_PROXY
         └─ CL_BNK_CPAY_ORD_NOTIFICATION->EXECUTE_ASYNCHRONOUS   (SET UPDATE TASK LOCAL)
             └─ CL_BNK_PROC_STATUS->PROCESS
                 ├─ FIND_BATCH            (BAdI CPON FIND_BATCH)
                 ├─ FILL_MAPPED_STATUS    (BNK_API_XST_TO_IST -> TBNK_XST_2_IST)
                 ├─ CHECK_* ...
                 └─ STORE                 (grava estados internos do lote e dos itens)
                     └─ ALERT( )          <-- ponto de integração
                         └─ por cada estado externo recebido:
                              BNK_API_XST_TO_IST -> E_ALRT_CAT
                              IF e_alrt_cat IS NOT INITIAL.
                                GET BADI bnk_badi_paym_alrt FILTERS bnk_badi_filter_alrt_cat = e_alrt_cat
                                CALL BADI ...->SEND_ALERT( i_batch_no, i_item_no, i_item_guid, i_stats_cd )
 └─ COMMIT WORK   (no fim do programa)
```

### Porque é que o breakpoint em `SEND_ALERT` nunca parou

A BAdI `BNK_BADI_PAYM_ALRT` só é chamada se o código externo recebido (ex.: `ACSC`)
tiver uma **categoria de alerta** preenchida na tabela `TBNK_XST_2_IST`, coluna `ALRT_CAT`
(SPRO → Administração de status de pagamento → *Atribuir status externo a status interno*).
Sem categoria, `ALERT( )` salta a chamada. O que falta é configuração, não há erro no código.

### Estados internos BCM (constantes de `CL_BNK_PROC_STATUS`)

| Transacção de negócio | Estado interno | Significado            | Tratamento Z                |
|-----------------------|----------------|------------------------|-----------------------------|
| `BRS`                 | `IBC05`        | Rede recebeu           | Não notificar               |
| `BRB`                 | `IBC06`        | Banco recebeu          | Não notificar               |
| `BPE`                 | `IBC22`        | Pendente no banco      | Aguardar                    |
| `BPA`                 | `IBC21`        | Aceite parcialmente    | Avaliar item a item         |
| **`BAC`**             | **`IBC17`**    | **Banco aceitou**      | **Elegível**                |
| `BRE`                 | `IBC19`        | Rejeitado              | Não notificar (CANCELLED)   |

O BCM não tem um estado "liquidado" separado de "banco aceitou". O `ACSC` só pode ser
mapeado para `BAC` → `IBC17`. **Regra implementada: notifica-se quando o item tem `IBC17`
activo e não tem `IBC19`.**

### Mapeamento actual na HCB (`Tabelas/TBNK_XST_2_IST.XLSX`, empresa HCB, banco SB)

| Código externo | Transacção actual | Estado interno | Significado ISO 20022 | Avaliação |
|---|---|---|---|---|
| `PAIN_RCVD` | BRB | IBC06 | Recebido | OK |
| `PAIN_ACTC` | **BAC** | IBC17 | Só aceitação técnica | **Errado:** fecha o lote como aceite logo no 1.º retorno |
| `PAIN_ACCP` | **BAC** | IBC17 | Aceite pelo cliente | Discutível |
| `PAIN_ACSP` | **BAC** | IBC17 | Liquidação em curso | **Errado:** ainda não está liquidado |
| `PAIN_ACSC` | **BRS** | IBC05 | **Liquidação concluída** | **Errado:** o estado final está mapeado para o mais baixo ("rede recebeu") |
| `PAIN_PDNG` | BPE | IBC22 | Pendente | OK |
| `PAIN_PART` | BPA | IBC21 | Parcial | OK |
| `PAIN_RJCT` | BRE | IBC19 | Rejeitado | OK |
| `PAIN_ABCD` | BRB | IBC06 | Não é código ISO | Confirmar com o banco |

Nenhuma linha tem categoria de alerta, e `SALRTCAT` não tem nenhuma categoria BCM nem Z.
**Está assim confirmado porque é que `SEND_ALERT` nunca é chamada.**

**Consequências do mapeamento actual:**

- Hoje, `IBC17` significa "aceitação técnica" e não "pagamento liquidado". Se a notificação se baseasse nele, sairia cedo demais.
- Quando chega o `ACSC` depois de um `ACTC`/`ACSP`, o BCM tenta passar o lote de `BAC` para `BRS`. `CHECK_AGAINST_STATUS_SCHEMA` verifica essa transição no perfil de status (`CRM_STATUS_CHANGE_FOR_ACTIVITY`). Se o perfil não permitir voltar atrás, levanta `NOT_COMPLYING_STATUS_SCHEMA` (mensagem `E017(BNK_COM_INTF)`) e **o `ACSC` nunca é gravado**, logo não chega a `STORE`/`ALERT`.
  → Confirmar na SLG1 (objecto `BNK`, subobjecto `PAIN002`) se aparecem mensagens E017 nas importações de `ACSC`.

### Decisão HCB (2026-11-18): o mapeamento de status NÃO é alterado

- O momento de notificação é o **`PAIN_ACSP`**, mapeado para BAC/IBC17. A HCB aceita-o como confirmação.
- O **`PAIN_ACTC`** também mapeia para BAC, mas é só aceitação técnica, por isso **não pode disparar**.
  Retire a categoria `ZFI_PAY_NOTIF` da linha `PAIN_ACTC` no SPRO.
- Como o código Z não consegue distinguir ACTC de ACSP pelo estado IBC17, o gatilho é o **código externo**.
  `ZCL_FI_PAY_NOTIFY=>IS_TRIGGER_STSCD` só aceita os códigos da variável de selecção STVARV
  `ZFI_PAY_NOTIF_STSCD` (por defeito `PAIN_ACSP`). Assim, uma categoria posta por engano noutro código não envia e-mail.
- **Teste de integração confirmado:** a BAdI parou com `FLT_VAL = ZFI_PAY_NOTIF`, `I_BATCH_NO = 68`,
  `I_ITEM_NO = 1` e `I_STATS_CD = PAIN_ACSP`. O valor chega item a item.
- **Risco aceite:** `ACSP` quer dizer "liquidação em curso". Se o banco rejeitar depois disso (`RJCT`), o e-mail já terá sido enviado.
  Se houver casos destes, é preciso um processo manual de aviso ao fornecedor.

*(Fica como referência a alternativa que não foi adoptada: mapear `ACTC`→BRB, `ACCP`/`ACSP`→BPE, `ACSC`→BAC
com a categoria em `ACSC`.)*

### Pontos ainda por confirmar no sistema

1. Mensagens E017 na SLG1 para `PAIN_ACSC` (ver acima) e se o banco envia sempre `ACSC` ou pára em `ACSP`.
2. Filtro da implementação existente `Z_BNK_BADI_PAYM_ALRT` (contém `BREAK cai-s2`, que deve sair antes do transporte).
3. Se `LAUFD/LAUFI` do item BCM coincidem com a REGUH, ou se é preciso `LAUFD_O/LAUFI_O`. O código tenta as duas.
4. Se o sistema é Unicode (os textos de erro têm acentos; o corpo HTML usa entidades e funciona em ambos os casos).

---

## 2. Arquitectura da solução

```
 PAIN.002 ─► RBNK_IMPORT_PAYM_STATUS_REPORT ─► CL_BNK_PROC_STATUS->STORE ─► ALERT
                                                                             │ ALRT_CAT = ZFI_PAY_NOTIF
                                                                             ▼
                                      ZCL_IF_EX_BNK_PAYM_ALRT (BAdI BNK_BADI_PAYM_ALRT)
                                                                             │
                     ZCL_FI_PAY_NOTIFY=>REGISTER_FROM_BADI  (INSERT PENDING, mesma LUW do BCM)
                                     │  CALL FUNCTION ZFI_PAY_NOTIFY_SEND IN BACKGROUND TASK
                                     ▼
            COMMIT WORK do programa standard ─► tRFC ─► PROCESS_BATCH
                                                         ├─ estado BCM do item (IBC17 / IBC19)
                                                         ├─ REGUH / REGUP / LFA1 / ADR6
                                                         └─ CL_BCS ─► SAPconnect ─► SOST
            Job ZFI_PAY_NOTIFY_JOB (de hora a hora) ─► reprocessa PENDING / ERROR
```

Garantias:

- **A BAdI não envia e-mail.** Só regista e apanha todas as excepções (`CATCH cx_root`). Uma falha nunca afecta o BCM.
- **Consistência com o BCM:** o registo e o tRFC estão na mesma LUW do estado BCM. Se a LUW for anulada, não fica nada.
- **Idempotência:** chave `BATCH_NO + ITEM_NO`, ou seja, uma notificação por instrução. Um PAIN.002 repetido não duplica (o INSERT falha em silêncio).
- **Concorrência tRFC/job:** `CLAIM` faz um `UPDATE ... WHERE status = <anterior>` optimista. Só um processo pode tratar cada registo.
- **Elegibilidade decidida no envio**, já depois do commit, com o estado BCM real do item. Os lotes com estado só ao nível do grupo registam todos os itens e os rejeitados ficam `CANCELLED`.

---

## 3. Objectos a criar (pacote `ZFI`)

| Objecto | Tipo | Ficheiro |
|---|---|---|
| `ZFI_PAY_NOTIF` | Tabela transparente | (definição abaixo) |
| `ZFI_PAY_NOTIF_STATUS` | Domínio + elemento de dados CHAR10 | (abaixo) |
| `ZCX_FI_PAY_NOTIFY` | Classe de excepção (CX_STATIC_CHECK) | `src/zcx_fi_pay_notify.clas.abap` |
| `ZCL_FI_PAY_NOTIFY_DATA` | Classe | `src/zcl_fi_pay_notify_data.clas.abap` |
| `ZCL_FI_PAY_NOTIFY_MAIL` | Classe | `src/zcl_fi_pay_notify_mail.clas.abap` |
| `ZCL_FI_PAY_NOTIFY` | Classe | `src/zcl_fi_pay_notify.clas.abap` |
| `ZCL_IF_EX_BNK_PAYM_ALRT` | Classe **existente** da BAdI (só muda o `SEND_ALERT`) | `manual/zcl_if_ex_bnk_paym_alrt.clas.abap` |
| `ZFI_PAY_NOTIF` | Grupo de funções | — |
| `ZFI_PAY_NOTIFY_SEND` | Módulo de função **RFC** | `manual/zfi_pay_notify_send.func.abap` (criar na SE37) |
| `ZFI_PAY_NOTIFY` | Programa | `src/zfi_pay_notify.prog.abap` |
| `ZFI_PAY_NOTIF_MON` | Transacção do programa | — |

**Ordem de activação:** domínio/elemento → tabela → `ZCX` → `_DATA` → `_MAIL` → grupo de funções + FM → `ZCL_FI_PAY_NOTIFY` → `ZCL_IF_EX_BNK_PAYM_ALRT` → programa.
(`ZCL_FI_PAY_NOTIFY` e o FM referem-se um ao outro: crie o FM vazio, active as duas partes e depois cole o código.)

Nas classes, use o *editor baseado em código fonte* da SE24 (ou o Eclipse ADT) e cole o ficheiro inteiro.

### 3.1 Tabela `ZFI_PAY_NOTIF`

Classe de entrega **A**, categoria de dados APPL1, buffering desligado.

| Campo | Chave | Elemento de dados | Notas |
|---|---|---|---|
| MANDT | X | MANDT | |
| BATCH_NO | X | BNK_COM_BTCH_NO | Lote BCM |
| ITEM_NO | X | BNK_COM_BTCH_CNT | Item BCM, ou seja, a instrução individual |
| ZBUKR | | DZBUKR | |
| LAUFD | | LAUFD | |
| LAUFI | | LAUFI | |
| VBLNR | | VBLNR | Documento de pagamento |
| LIFNR | | LIFNR | |
| BANK_STATUS | | BNK_COM_STSCD | Código externo PAIN.002 |
| PAYMENT_DATE | | DZALDT_ZHL | Usar o mesmo elemento de `REGUH-ZALDT` |
| AMOUNT | | RWBTR | Ref. moeda: `ZFI_PAY_NOTIF-WAERS` |
| WAERS | | WAERS | |
| EMAIL | | AD_SMTPADR | E-mail real do fornecedor |
| STATUS | | ZFI_PAY_NOTIF_STATUS | |
| RETRY_COUNT | | INT4 | |
| LAST_ERROR | | BAPI_MSG | |
| MESSAGE_ID | | OS_GUID | OID BCS (SOST) |
| SENT_AT | | TIMESTAMP | |
| CREATED_AT | | TIMESTAMP | |
| CREATED_BY | | SYUNAME | |
| CHANGED_AT | | TIMESTAMP | |
| CHANGED_BY | | SYUNAME | |

Índice secundário `Z01` (não único): `MANDT, STATUS`. Índice `Z02`: `MANDT, ZBUKR, LAUFD, LAUFI, VBLNR`.

Domínio `ZFI_PAY_NOTIF_STATUS` (CHAR10) com valores fixos:
`PENDING`, `PROCESS`, `SENT`, `ERROR`, `NO_EMAIL`, `CANCELLED`.

### 3.2 Implementação BAdI (SE19)

- Spot de ampliação: **`BNK_BADI_PAYM_STAT_ALRT`**
- Definição BAdI: **`BNK_BADI_PAYM_ALRT`**
- Implementação de ampliação **existente**: `Z_BNK_BADI_PAYM_ALRT` (implementação BAdI `ZBNK_BADI_PAYM_ALRT`), activa
- Classe: **`ZCL_IF_EX_BNK_PAYM_ALRT`**. Substitua o `SEND_ALERT` pelo de `manual/zcl_if_ex_bnk_paym_alrt.clas.abap`, que **remove o `BREAK cai-s2`**
- **Filtro (já configurado):** `BNK_BADI_FILTER_ALRT_CAT = ZFI_PAY_NOTIF`

Não é preciso criar uma implementação nova.

### 3.3 Programa — textos

Textos de selecção: `S_BATCH` Lote BCM · `S_ZBUKR` Empresa · `S_LIFNR` Fornecedor · `S_LAUFD` Data execução ·
`S_STAT` Estado notificação · `P_PROC` Processar pendentes/erros · `P_DISP` Monitor · `P_RESND` Reenviar ·
`P_REG` Registar lote (recuperação) · `P_MAXTR` Máx. tentativas.
Símbolos de texto: `B01` Selecção · `B02` Modo de execução.

---

## 4. Customizing

1. **Categoria de alerta** (transacção `ALRTCATDEF`): crie `ZFI_PAY_NOTIF` ("Notificação pagamento fornecedor"), sem destinatários.
   A exportação de `SALRTCAT` mostra que ela ainda não existe. Serve apenas de valor de filtro da BAdI; o BCM não envia alertas por si só.
2. **SPRO → Bank Communication Management → Administração de status de pagamento → Atribuir status externo a status interno**
   (empresa `HCB`, banco `SB`): o mapeamento de status mantém-se. Fica
   **Categoria de alerta = `ZFI_PAY_NOTIF` apenas em `PAIN_ACSP`**; retire-a de `PAIN_ACTC`.
3. **STVARV** (parâmetros):

   | Nome | Valor | Notas |
   |---|---|---|
   | `ZFI_PAY_NOTIF_ACTIVE` | `X` | Interruptor geral. Vazio desliga sem transporte |
   | `ZFI_PAY_NOTIF_SENDER` | ex.: `no-reply@hcb.co.mz` | Remetente |
   | `ZFI_PAY_NOTIF_TEST_RCPT` | e-mail de teste | **Obrigatório em DEV/QAS** (redirige todos os envios). **Vazio em PRD** |
   | `ZFI_PAY_NOTIF_STSCD` (selecção, tipo S) | `I EQ PAIN_ACSP` | Códigos externos que disparam. Se não existir, usa-se `PAIN_ACSP` |

4. **SCOT:** nó SMTP activo e domínio do remetente autorizado no relay. **SOST** para monitorizar.
5. **Job SM36** `ZFI_PAY_NOTIFY_JOB`: programa `ZFI_PAY_NOTIFY`, variante com `P_PROC = X` e `P_MAXTR = 3`, de hora a hora.
6. **Autorizações:** o utilizador que corre `RBNK_IMPORT_PAYM_STATUS_REPORT` executa o tRFC (`S_RFC` no grupo `ZFI_PAY_NOTIF`, destino `NONE`) e o CL_BCS (`S_OC_SEND`).
   O reenvio exige `S_TCODE = ZFI_PAY_NOTIF_MON`.

---

## 5. Plano de testes (QAS, com `ZFI_PAY_NOTIF_TEST_RCPT` preenchido)

| # | Cenário | Resultado esperado |
|---|---|---|
| 1 | PAIN.002 `ACSP` para lote com 1 fornecedor com e-mail | Linha `SENT`, e-mail na SOST com montante, data e documentos REGUP. **Confirmado em DEV (2026-11-18/19):** envio manual (lote 68, fornecedor 41000886) e depois automático via tRFC, recebido na caixa de teste |
| 2 | Mesmo ficheiro importado outra vez | Sem nova linha e sem novo e-mail |
| 3 | `RJCT` no item | Sem linha (sem categoria) ou linha `CANCELLED` |
| 4 | Lote com estado só no grupo (sem itens no PAIN.002) | Uma linha por item, todos `SENT` |
| 5 | Estado `PART`: item A `ACSC`, item B `RJCT` | A `SENT`, B sem envio |
| 6 | Fornecedor sem e-mail em ADR6 | `NO_EMAIL`; corrigir dados mestre → modo Reenviar → `SENT` |
| 7 | SCOT parado / SMTP em erro | Pagamento BCM inalterado; a SOST mostra o erro |
| 8 | `ZFI_PAY_NOTIF_ACTIVE` vazio | Importação normal, nenhuma linha criada |
| 9 | Dump simulado no tRFC (SM58) | Linha fica `PENDING`; o job envia na execução seguinte |
| 10 | Breakpoint em `ZCL_IF_EX_BNK_PAYM_ALRT~SEND_ALERT` | **Confirmado** (lote 68, item 1, `PAIN_ACSP`) |
| 11 | `PAIN_ACTC` com a categoria posta por engano | Nenhuma linha criada (filtrado por `ZFI_PAY_NOTIF_STSCD`) |

Evidências: SLG1 (objecto `BNK`, subobjecto `PAIN002`), BNK_MONI (estado do item), SE16 `ZFI_PAY_NOTIF`, SOST.

### Estado em 2026-11-19

Confirmado em DEV: cenários 1 e 10. O fluxo completo funciona: PAIN.002 → BAdI → `ZFI_PAY_NOTIF` → tRFC → `CL_BCS` → caixa de correio.
Pendente: cenários 2–9 e 11 em QAS, job `ZFI_PAY_NOTIFY_JOB`, e os passos antes de produção:
retirar `ZFI_PAY_NOTIF` de `PAIN_ACTC` no SPRO; deixar `ZFI_PAY_NOTIF_TEST_RCPT` **vazio** em PRD;
confirmar o remetente no relay SMTP de PRD.

Nota de instalação: no primeiro teste a linha ficou em `PENDING` sem mensagem, porque o tRFC não correu.
No teste seguinte o envio já foi automático. Se voltar a acontecer, verificar se `ZFI_PAY_NOTIFY_SEND`
tem a marca *Módulo com capacidade remota* e ver a SM58.

---

## 6. Limitações conhecidas

- **Montante:** vem de `REGUH-RWBTR` (montante instruído). O PAIN.002 da HCB normalmente não traz montante liquidado. Se trouxer, terá de ser lido de `BNK_XSTAT_TX`.
- **Data:** `REGUH-ZALDT` (data de lançamento do pagamento), não a data-valor bancária.
- **Destinatário:** um endereço por fornecedor, o padrão de ADR6 ou, na falta dele, o de menor sequência. Fornecedores CPD não são tratados.
- **Pagamentos HCM** (`LAUFI` terminado em `P`) e a clientes (`LIFNR` vazio) são excluídos.
- Se uma importação correr **antes** de a categoria de alerta estar configurada, os lotes não ficam registados. Use o modo *Registar lote* do `ZFI_PAY_NOTIFY`.
