"! Classe da implementação EXISTENTE Z_BNK_BADI_PAYM_ALRT
"! (BAdI BNK_BADI_PAYM_ALRT, spot BNK_BADI_PAYM_STAT_ALRT).
"! Filtro: BNK_BADI_FILTER_ALRT_CAT = 'ZFI_PAY_NOTIF'.
"!
"! Chamada por CL_BNK_PROC_STATUS->ALERT( ), depois de o BCM gravar o estado
"! do item durante RBNK_IMPORT_PAYM_STATUS_REPORT.
"! Teste de 2026-11-18: chamada confirmada (lote 68, item 1, PAIN_ACSP).
"!
"! Regra: não envia e-mail nem levanta excepções; só regista em ZFI_PAY_NOTIF.
"! Remover o BREAK cai-s2 de teste antes do transporte.
CLASS zcl_if_ex_bnk_paym_alrt DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_badi_interface.
    INTERFACES if_ex_bnk_paym_alrt.

  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS zcl_if_ex_bnk_paym_alrt IMPLEMENTATION.

  METHOD if_ex_bnk_paym_alrt~send_alert.
    " Cópia para tipos locais: não depender da compatibilidade exacta
    " entre a assinatura da BAdI e os parâmetros da classe Z.
    DATA: lv_batch_no TYPE bnk_com_btch_no,
          lv_item_no  TYPE bnk_com_btch_cnt,
          lv_stscd    TYPE bnk_com_stscd.

    lv_batch_no = i_batch_no.
    lv_item_no  = i_item_no.
    lv_stscd    = i_stats_cd.

    zcl_fi_pay_notify=>register_from_badi(
      iv_batch_no = lv_batch_no
      iv_item_no  = lv_item_no
      iv_stscd    = lv_stscd ).
  ENDMETHOD.


  METHOD if_ex_bnk_paym_alrt~send_timeout_alert.
    " Não utilizado pela notificação a fornecedores.
  ENDMETHOD.

ENDCLASS.
