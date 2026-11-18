*&---------------------------------------------------------------------*
*& Report ZFI_PAY_NOTIFY
*&---------------------------------------------------------------------*
*& Notificações de pagamento a fornecedores (F110 + BCM + PAIN.002)
*&
*&  Modo "Processar"  : job ZFI_PAY_NOTIFY_JOB. Envia PENDING e reenvia
*&                      ERROR até ao número máximo de tentativas.
*&  Modo "Monitor"    : transacção ZFI_PAY_NOTIF_MON. Consulta em ALV.
*&  Modo "Reenviar"   : reenvio autorizado dos registos seleccionados.
*&  Modo "Registar"   : recuperação. Regista lotes BCM que não passaram
*&                      pela BAdI (ex.: mapeamento sem categoria de alerta
*&                      na altura da importação).
*&---------------------------------------------------------------------*
REPORT zfi_pay_notify.

TABLES zfi_pay_notif.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-b01.
SELECT-OPTIONS: s_batch FOR zfi_pay_notif-batch_no,
                s_zbukr FOR zfi_pay_notif-zbukr,
                s_lifnr FOR zfi_pay_notif-lifnr,
                s_laufd FOR zfi_pay_notif-laufd,
                s_stat  FOR zfi_pay_notif-status.
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-b02.
PARAMETERS: p_proc  RADIOBUTTON GROUP mode DEFAULT 'X',
            p_disp  RADIOBUTTON GROUP mode,
            p_resnd RADIOBUTTON GROUP mode,
            p_reg   RADIOBUTTON GROUP mode.
PARAMETERS: p_maxtr TYPE i DEFAULT 3.
SELECTION-SCREEN END OF BLOCK b2.

CLASS lcl_app DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS run.

  PRIVATE SECTION.
    DATA mt_notif TYPE zcl_fi_pay_notify=>tt_notif.

    METHODS select_data.
    METHODS do_process.
    METHODS do_resend.
    METHODS do_register.
    METHODS display.
ENDCLASS.

CLASS lcl_app IMPLEMENTATION.

  METHOD run.
    CASE abap_true.
      WHEN p_proc.
        do_process( ).
      WHEN p_disp.
        select_data( ).
        display( ).
      WHEN p_resnd.
        do_resend( ).
      WHEN p_reg.
        do_register( ).
    ENDCASE.
  ENDMETHOD.


  METHOD select_data.
    SELECT * FROM zfi_pay_notif INTO TABLE mt_notif
      WHERE batch_no IN s_batch
        AND zbukr    IN s_zbukr
        AND lifnr    IN s_lifnr
        AND laufd    IN s_laufd
        AND status   IN s_stat
      ORDER BY batch_no item_no.
  ENDMETHOD.


  METHOD do_process.
    DATA lo_notify TYPE REF TO zcl_fi_pay_notify.

    SELECT * FROM zfi_pay_notif INTO TABLE mt_notif
      WHERE batch_no IN s_batch
        AND zbukr    IN s_zbukr
        AND lifnr    IN s_lifnr
        AND laufd    IN s_laufd
        AND ( status = zcl_fi_pay_notify=>gc_status-pending
           OR ( status = zcl_fi_pay_notify=>gc_status-error
            AND retry_count < p_maxtr ) ).

    CREATE OBJECT lo_notify.
    lo_notify->process_list( mt_notif ).

    select_data( ).
    display( ).
  ENDMETHOD.


  METHOD do_resend.
    DATA: lo_notify TYPE REF TO zcl_fi_pay_notify,
          ls_notif  TYPE zfi_pay_notif,
          lx_error  TYPE REF TO zcx_fi_pay_notify,
          lv_text   TYPE string.

    IF s_batch[] IS INITIAL.
      MESSAGE 'Indique o(s) lote(s) a reenviar' TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    select_data( ).
    CREATE OBJECT lo_notify.

    LOOP AT mt_notif INTO ls_notif
         WHERE status = zcl_fi_pay_notify=>gc_status-sent
            OR status = zcl_fi_pay_notify=>gc_status-no_email
            OR status = zcl_fi_pay_notify=>gc_status-error.
      TRY.
          lo_notify->resend( ls_notif ).
        CATCH zcx_fi_pay_notify INTO lx_error.
          lv_text = lx_error->get_text( ).
          MESSAGE lv_text TYPE 'S' DISPLAY LIKE 'E'.
          RETURN.
      ENDTRY.
    ENDLOOP.

    select_data( ).
    display( ).
  ENDMETHOD.


  METHOD do_register.
    DATA: lt_batch TYPE STANDARD TABLE OF bnk_com_btch_no,
          lv_batch TYPE bnk_com_btch_no,
          lv_item  TYPE bnk_com_btch_cnt,
          lv_stscd TYPE bnk_com_stscd.

    IF s_batch[] IS INITIAL.
      MESSAGE 'Indique o(s) lote(s) BCM a registar' TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    SELECT batch_no FROM bnk_batch_header INTO TABLE lt_batch
      WHERE batch_no IN s_batch.

    " Item inicial = todos os itens do lote. A elegibilidade (IBC17) é
    " verificada no envio, item a item.
    LOOP AT lt_batch INTO lv_batch.
      zcl_fi_pay_notify=>register_from_badi( iv_batch_no = lv_batch
                                             iv_item_no  = lv_item
                                             iv_stscd    = lv_stscd ).
    ENDLOOP.
    COMMIT WORK.

    MESSAGE 'Registo concluído; o envio corre em tRFC (ver SM58/SOST)' TYPE 'S'.
  ENDMETHOD.


  METHOD display.
    DATA: lo_alv  TYPE REF TO cl_salv_table,
          lx_salv TYPE REF TO cx_salv_msg.

    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = lo_alv
                                CHANGING  t_table      = mt_notif ).
        lo_alv->get_functions( )->set_all( abap_true ).
        lo_alv->get_columns( )->set_optimize( abap_true ).
        lo_alv->display( ).
      CATCH cx_salv_msg INTO lx_salv.
        MESSAGE lx_salv TYPE 'S' DISPLAY LIKE 'E'.
    ENDTRY.
  ENDMETHOD.

ENDCLASS.

START-OF-SELECTION.
  DATA go_app TYPE REF TO lcl_app.
  CREATE OBJECT go_app.
  go_app->run( ).
