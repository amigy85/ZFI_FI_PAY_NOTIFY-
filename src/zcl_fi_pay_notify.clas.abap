"! Notificação automática de pagamentos a fornecedores (F110 + BCM + PAIN.002).
"!
"! Fluxo:
"!  1. RBNK_IMPORT_PAYM_STATUS_REPORT -> CL_BNK_PROC_STATUS->STORE( ) -> ALERT( )
"!     -> BAdI BNK_BADI_PAYM_ALRT -> REGISTER_FROM_BADI( ): grava PENDING em
"!     ZFI_PAY_NOTIF na mesma LUW do BCM e agenda o tRFC ZFI_PAY_NOTIFY_SEND.
"!  2. No COMMIT WORK do programa standard, o tRFC corre PROCESS_BATCH( ).
"!  3. O job ZFI_PAY_NOTIFY_JOB (programa ZFI_PAY_NOTIFY) reprocessa o que
"!     ficou pendente ou com erro.
"!
"! Falhas de e-mail nunca são propagadas para o processamento BCM.
CLASS zcl_fi_pay_notify DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    TYPES tt_notif TYPE STANDARD TABLE OF zfi_pay_notif WITH DEFAULT KEY.

    CONSTANTS:
      BEGIN OF gc_status,
        pending   TYPE zfi_pay_notif-status VALUE 'PENDING',
        process   TYPE zfi_pay_notif-status VALUE 'PROCESS',
        sent      TYPE zfi_pay_notif-status VALUE 'SENT',
        error     TYPE zfi_pay_notif-status VALUE 'ERROR',
        no_email  TYPE zfi_pay_notif-status VALUE 'NO_EMAIL',
        cancelled TYPE zfi_pay_notif-status VALUE 'CANCELLED',
      END OF gc_status.

    "! Parâmetros TVARVC (STVARV)
    CONSTANTS:
      BEGIN OF gc_tvarvc,
        active    TYPE rvari_vnam VALUE 'ZFI_PAY_NOTIF_ACTIVE',
        sender    TYPE rvari_vnam VALUE 'ZFI_PAY_NOTIF_SENDER',
        test_rcpt TYPE rvari_vnam VALUE 'ZFI_PAY_NOTIF_TEST_RCPT',
        "! Selecção (tipo S): códigos externos PAIN.002 que disparam a notificação
        stscd     TYPE rvari_vnam VALUE 'ZFI_PAY_NOTIF_STSCD',
      END OF gc_tvarvc.

    "! Usado quando ZFI_PAY_NOTIF_STSCD não está mantido em STVARV.
    "! Decisão HCB: o mapeamento BCM não é alterado; PAIN_ACTC (aceitação
    "! técnica) também leva a BAC/IBC17 e por isso NÃO pode ser gatilho.
    CONSTANTS gc_default_stscd TYPE bnk_com_stscd VALUE 'PAIN_ACSP'.

    "! Chamado pela BAdI. Nunca levanta excepções nem faz COMMIT.
    CLASS-METHODS register_from_badi
      IMPORTING
        iv_batch_no TYPE bnk_com_btch_no
        iv_item_no  TYPE bnk_com_btch_cnt
        iv_stscd    TYPE bnk_com_stscd.

    CLASS-METHODS is_active
      RETURNING VALUE(rv_active) TYPE abap_bool.

    "! O código externo recebido é um gatilho autorizado?
    "! Inicial = registo manual (modo Registar do ZFI_PAY_NOTIFY).
    CLASS-METHODS is_trigger_stscd
      IMPORTING iv_stscd          TYPE bnk_com_stscd
      RETURNING VALUE(rv_allowed) TYPE abap_bool.

    METHODS constructor.

    "! Processa as notificações PENDING de um lote (chamado pelo tRFC)
    METHODS process_batch
      IMPORTING iv_batch_no TYPE bnk_com_btch_no
                iv_commit   TYPE abap_bool DEFAULT abap_false.

    "! Processa uma lista (job de reprocessamento); COMMIT por registo
    METHODS process_list
      IMPORTING it_notif TYPE tt_notif.

    "! Reenvio autorizado de uma notificação já enviada
    METHODS resend
      IMPORTING is_notif TYPE zfi_pay_notif
      RAISING   zcx_fi_pay_notify.

  PROTECTED SECTION.
  PRIVATE SECTION.
    CLASS-DATA gt_triggered TYPE SORTED TABLE OF bnk_com_btch_no WITH UNIQUE KEY table_line.

    DATA mo_data      TYPE REF TO zcl_fi_pay_notify_data.
    DATA mo_mail      TYPE REF TO zcl_fi_pay_notify_mail.
    DATA mv_test_rcpt TYPE ad_smtpadr.

    CLASS-METHODS get_param
      IMPORTING iv_name         TYPE rvari_vnam
      RETURNING VALUE(rv_value) TYPE string.

    CLASS-METHODS trigger_send
      IMPORTING iv_batch_no TYPE bnk_com_btch_no.

    CLASS-METHODS now
      RETURNING VALUE(rv_ts) TYPE timestamp.

    METHODS process_entry
      IMPORTING is_notif  TYPE zfi_pay_notif
                iv_commit TYPE abap_bool.

    METHODS claim
      IMPORTING is_notif          TYPE zfi_pay_notif
      RETURNING VALUE(rv_claimed) TYPE abap_bool.

    METHODS find_item
      IMPORTING is_notif       TYPE zfi_pay_notif
      RETURNING VALUE(rs_item) TYPE bnk_str_batch_item
      RAISING   zcx_fi_pay_notify.
ENDCLASS.



CLASS zcl_fi_pay_notify IMPLEMENTATION.

  METHOD register_from_badi.
    DATA: lo_data     TYPE REF TO zcl_fi_pay_notify_data,
          lt_items    TYPE bnk_tab_batch_item,
          ls_item     TYPE bnk_str_batch_item,
          ls_notif    TYPE zfi_pay_notif,
          lv_inserted TYPE abap_bool.

    TRY.
        IF is_active( ) = abap_false.
          RETURN.
        ENDIF.

        " Defesa contra customizing: mesmo que alguém ponha a categoria
        " ZFI_PAY_NOTIF noutro código (ex.: PAIN_ACTC), só os códigos
        " autorizados geram notificação.
        IF is_trigger_stscd( iv_stscd ) = abap_false.
          RETURN.
        ENDIF.

        CREATE OBJECT lo_data.
        lt_items = lo_data->get_batch_items( iv_batch_no ).

        " ITEM_NO inicial = estado ao nível do lote (grupo): todos os itens
        " são registados e a elegibilidade de cada um é confirmada depois,
        " no envio, pelo estado interno BCM do próprio item.
        IF iv_item_no IS NOT INITIAL.
          DELETE lt_items WHERE item_no <> iv_item_no.
        ENDIF.

        LOOP AT lt_items INTO ls_item.
          " Apenas pagamentos a fornecedores; HCM (LAUFI 'xxxxxP') fica de fora.
          IF ls_item-lifnr IS INITIAL OR ls_item-laufi+5(1) = 'P'.
            CONTINUE.
          ENDIF.

          CLEAR ls_notif.
          ls_notif-mandt       = sy-mandt.
          ls_notif-batch_no    = ls_item-batch_no.
          ls_notif-item_no     = ls_item-item_no.
          ls_notif-zbukr       = ls_item-zbukr.
          ls_notif-laufd       = ls_item-laufd.
          ls_notif-laufi       = ls_item-laufi.
          ls_notif-vblnr       = ls_item-vblnr.
          ls_notif-lifnr       = ls_item-lifnr.
          ls_notif-bank_status = iv_stscd.
          ls_notif-status      = gc_status-pending.
          ls_notif-created_at  = now( ).
          ls_notif-created_by  = sy-uname.

          " Chave = lote + item BCM: um registo por instrução, sem duplicados.
          INSERT zfi_pay_notif FROM ls_notif.
          IF sy-subrc = 0.
            lv_inserted = abap_true.
          ENDIF.
        ENDLOOP.

        IF lv_inserted = abap_true.
          trigger_send( iv_batch_no ).
        ENDIF.

      CATCH cx_root.                                     "#EC CATCH_ALL
        " Nada é propagado: o estado BCM tem prioridade absoluta.
        " O que não ficou registado pode ser recuperado no programa
        " ZFI_PAY_NOTIFY (opção de recuperação por lote).
    ENDTRY.
  ENDMETHOD.


  METHOD trigger_send.
    " Um tRFC por lote e por sessão. Só é executado depois do COMMIT WORK
    " do programa standard; se a LUW for anulada, o tRFC também é.
    READ TABLE gt_triggered TRANSPORTING NO FIELDS WITH TABLE KEY table_line = iv_batch_no.
    IF sy-subrc = 0.
      RETURN.
    ENDIF.
    INSERT iv_batch_no INTO TABLE gt_triggered.

    CALL FUNCTION 'ZFI_PAY_NOTIFY_SEND'
      IN BACKGROUND TASK
      AS SEPARATE UNIT
      DESTINATION 'NONE'
      EXPORTING
        iv_batch_no = iv_batch_no.
  ENDMETHOD.


  METHOD is_active.
    IF get_param( gc_tvarvc-active ) = 'X'.
      rv_active = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD is_trigger_stscd.
    DATA lt_stscd TYPE STANDARD TABLE OF tvarvc-low.

    IF iv_stscd IS INITIAL.
      rv_allowed = abap_true.
      RETURN.
    ENDIF.

    SELECT low FROM tvarvc INTO TABLE lt_stscd
      WHERE name = gc_tvarvc-stscd
        AND type = 'S'
        AND sign = 'I'
        AND opti = 'EQ'.

    IF lt_stscd IS INITIAL.
      APPEND gc_default_stscd TO lt_stscd.
    ENDIF.

    READ TABLE lt_stscd TRANSPORTING NO FIELDS WITH KEY table_line = iv_stscd.
    IF sy-subrc = 0.
      rv_allowed = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD get_param.
    DATA lv_low TYPE tvarvc-low.

    SELECT SINGLE low FROM tvarvc INTO lv_low
      WHERE name = iv_name
        AND type = 'P'
        AND numb = '0000'.
    rv_value = lv_low.
    CONDENSE rv_value.
  ENDMETHOD.


  METHOD now.
    GET TIME STAMP FIELD rv_ts.
  ENDMETHOD.


  METHOD constructor.
    DATA lv_sender TYPE ad_smtpadr.

    lv_sender    = get_param( gc_tvarvc-sender ).
    mv_test_rcpt = get_param( gc_tvarvc-test_rcpt ).

    CREATE OBJECT mo_data.
    CREATE OBJECT mo_mail EXPORTING iv_sender = lv_sender.
  ENDMETHOD.


  METHOD process_batch.
    DATA: lt_notif TYPE tt_notif,
          ls_notif TYPE zfi_pay_notif.

    SELECT * FROM zfi_pay_notif INTO TABLE lt_notif
      WHERE batch_no = iv_batch_no
        AND status   = gc_status-pending.

    LOOP AT lt_notif INTO ls_notif.
      process_entry( is_notif = ls_notif iv_commit = iv_commit ).
    ENDLOOP.
  ENDMETHOD.


  METHOD process_list.
    DATA ls_notif TYPE zfi_pay_notif.

    LOOP AT it_notif INTO ls_notif.
      process_entry( is_notif = ls_notif iv_commit = abap_true ).
    ENDLOOP.
  ENDMETHOD.


  METHOD resend.
    DATA ls_notif TYPE zfi_pay_notif.

    AUTHORITY-CHECK OBJECT 'S_TCODE' ID 'TCD' FIELD 'ZFI_PAY_NOTIF_MON'.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_fi_pay_notify
        EXPORTING iv_text = 'Sem autorização para reenviar notificações'.
    ENDIF.

    ls_notif = is_notif.
    process_entry( is_notif = ls_notif iv_commit = abap_true ).
  ENDMETHOD.


  METHOD claim.
    " Bloqueio optimista: só um processo (tRFC ou job) consegue passar o
    " registo para PROCESS. O bloqueio de linha da BD dura até ao COMMIT.
    UPDATE zfi_pay_notif
       SET status     = gc_status-process
           changed_by = sy-uname
     WHERE batch_no = is_notif-batch_no
       AND item_no  = is_notif-item_no
       AND status   = is_notif-status.
    IF sy-dbcnt = 1.
      rv_claimed = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD find_item.
    DATA: lt_items TYPE bnk_tab_batch_item,
          lv_text  TYPE string.

    lt_items = mo_data->get_batch_items( is_notif-batch_no ).
    READ TABLE lt_items INTO rs_item WITH KEY item_no = is_notif-item_no.
    IF sy-subrc <> 0.
      lv_text = |Item { is_notif-item_no } não existe no lote { is_notif-batch_no }|.
      RAISE EXCEPTION TYPE zcx_fi_pay_notify EXPORTING iv_text = lv_text.
    ENDIF.
  ENDMETHOD.


  METHOD process_entry.
    DATA: ls_notif     TYPE zfi_pay_notif,
          ls_item      TYPE bnk_str_batch_item,
          ls_payment   TYPE zcl_fi_pay_notify_data=>ty_payment,
          lv_state     TYPE char1,
          lv_recipient TYPE ad_smtpadr,
          lx_error     TYPE REF TO zcx_fi_pay_notify,
          lx_root      TYPE REF TO cx_root.

    IF claim( is_notif ) = abap_false.
      RETURN.
    ENDIF.

    ls_notif = is_notif.

    TRY.
        ls_item  = find_item( ls_notif ).
        lv_state = mo_data->get_item_bcm_state( ls_item ).

        CASE lv_state.
          WHEN zcl_fi_pay_notify_data=>gc_bcm_state-rejected.
            ls_notif-status     = gc_status-cancelled.
            ls_notif-last_error = 'Pagamento rejeitado pelo banco (IBC19)'.

          WHEN zcl_fi_pay_notify_data=>gc_bcm_state-pending.
            " Ainda sem confirmação positiva: fica à espera do próximo PAIN.002.
            ls_notif-status     = gc_status-pending.
            ls_notif-last_error = 'Aguarda estado BCM IBC17 (banco aceitou)'.

          WHEN zcl_fi_pay_notify_data=>gc_bcm_state-accepted.
            ls_payment = mo_data->read_payment( ls_item ).

            ls_notif-payment_date = ls_payment-zaldt.
            ls_notif-amount       = ls_payment-amount.
            ls_notif-waers        = ls_payment-waers.
            ls_notif-email        = mo_data->get_vendor_email( ls_payment-lifnr ).

            IF ls_notif-email IS INITIAL.
              ls_notif-status     = gc_status-no_email.
              ls_notif-last_error = 'Fornecedor sem e-mail válido (LFA1/ADR6)'.
            ELSE.
              " Em QAS o destinatário real é substituído pelo endereço de teste.
              lv_recipient = ls_notif-email.
              IF mv_test_rcpt IS NOT INITIAL.
                lv_recipient = mv_test_rcpt.
              ENDIF.

              ls_notif-message_id = mo_mail->send( is_payment   = ls_payment
                                                   iv_recipient = lv_recipient ).
              ls_notif-status     = gc_status-sent.
              ls_notif-sent_at    = now( ).
              CLEAR ls_notif-last_error.
            ENDIF.
        ENDCASE.

      CATCH zcx_fi_pay_notify INTO lx_error.
        ls_notif-status      = gc_status-error.
        ls_notif-retry_count = ls_notif-retry_count + 1.
        ls_notif-last_error  = lx_error->get_text( ).
      CATCH cx_root INTO lx_root.                        "#EC CATCH_ALL
        ls_notif-status      = gc_status-error.
        ls_notif-retry_count = ls_notif-retry_count + 1.
        ls_notif-last_error  = lx_root->get_text( ).
    ENDTRY.

    ls_notif-changed_at = now( ).
    ls_notif-changed_by = sy-uname.
    UPDATE zfi_pay_notif FROM ls_notif.

    IF iv_commit = abap_true.
      COMMIT WORK.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
