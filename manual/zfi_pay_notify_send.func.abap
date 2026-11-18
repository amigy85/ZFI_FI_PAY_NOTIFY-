FUNCTION zfi_pay_notify_send.
*"----------------------------------------------------------------------
*"*"Interface local:
*"  IMPORTING
*"     VALUE(IV_BATCH_NO) TYPE  BNK_COM_BTCH_NO
*"----------------------------------------------------------------------
* Grupo de funções: ZFI_PAY_NOTIF
* Tipo de processamento: Módulo com capacidade remota (RFC)
*
* Chamado IN BACKGROUND TASK por ZCL_FI_PAY_NOTIFY=>TRIGGER_SEND, só é
* executado depois do COMMIT WORK de RBNK_IMPORT_PAYM_STATUS_REPORT.
* O fim da unidade tRFC faz o commit, e é nesse momento que o CL_BCS
* entrega o pedido ao SAPconnect. Sem COMMIT WORK explícito aqui.
*
* Se este tRFC falhar (SM58), os registos continuam PENDING e o job
* ZFI_PAY_NOTIFY_JOB trata-os na execução seguinte.

  DATA lo_notify TYPE REF TO zcl_fi_pay_notify.

  TRY.
      CREATE OBJECT lo_notify.
      lo_notify->process_batch( iv_batch_no = iv_batch_no
                                iv_commit   = abap_false ).
    CATCH cx_root.                                       "#EC CATCH_ALL
      " Os erros individuais já ficam gravados em ZFI_PAY_NOTIF-LAST_ERROR.
  ENDTRY.

ENDFUNCTION.
