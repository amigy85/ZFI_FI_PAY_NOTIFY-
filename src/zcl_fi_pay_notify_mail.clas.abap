"! Construção e envio do e-mail de aviso de pagamento via CL_BCS / SAPconnect.
"! O envio efectivo ocorre no COMMIT WORK de quem chama (job ou tRFC).
CLASS zcl_fi_pay_notify_mail DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    METHODS constructor
      IMPORTING
        iv_sender  TYPE ad_smtpadr
        "! Texto HTML (já com entidades), não é escapado
        iv_company TYPE string DEFAULT 'Hidroel&eacute;ctrica de Cahora Bassa, S.A.'.

    "! Envia a notificação; devolve o OID do pedido BCS (visível na SOST)
    METHODS send
      IMPORTING
        is_payment    TYPE zcl_fi_pay_notify_data=>ty_payment
        iv_recipient  TYPE ad_smtpadr
      RETURNING
        VALUE(rv_oid) TYPE os_guid
      RAISING
        zcx_fi_pay_notify.

    METHODS build_subject
      IMPORTING is_payment        TYPE zcl_fi_pay_notify_data=>ty_payment
      RETURNING VALUE(rv_subject) TYPE string.

    METHODS build_html
      IMPORTING is_payment     TYPE zcl_fi_pay_notify_data=>ty_payment
      RETURNING VALUE(rv_html) TYPE string.

  PROTECTED SECTION.
  PRIVATE SECTION.
    DATA mv_sender  TYPE ad_smtpadr.
    DATA mv_company TYPE string.

    CLASS-METHODS html
      IMPORTING iv_text        TYPE csequence
      RETURNING VALUE(rv_html) TYPE string.

    CLASS-METHODS fmt_amount
      IMPORTING iv_amount      TYPE any
                iv_waers       TYPE waers
      RETURNING VALUE(rv_text) TYPE string.

    CLASS-METHODS fmt_date
      IMPORTING iv_date        TYPE d
      RETURNING VALUE(rv_text) TYPE string.
ENDCLASS.



CLASS zcl_fi_pay_notify_mail IMPLEMENTATION.

  METHOD constructor.
    mv_sender  = iv_sender.
    mv_company = iv_company.
  ENDMETHOD.


  METHOD send.
    DATA: lo_request   TYPE REF TO cl_bcs,
          lo_document  TYPE REF TO cl_document_bcs,
          lo_sender    TYPE REF TO if_sender_bcs,
          lo_recipient TYPE REF TO if_recipient_bcs,
          lt_body      TYPE soli_tab,
          lv_subject   TYPE string,
          lv_title     TYPE so_obj_des,
          lv_sent      TYPE os_boolean,
          lx_bcs       TYPE REF TO cx_bcs,
          lv_text      TYPE string.

    IF zcl_fi_pay_notify_data=>is_valid_email( iv_recipient ) = abap_false.
      lv_text = |Destinatário inválido: { iv_recipient }|.
      RAISE EXCEPTION TYPE zcx_fi_pay_notify EXPORTING iv_text = lv_text.
    ENDIF.

    lv_subject = build_subject( is_payment ).
    lv_title   = lv_subject.
    lt_body    = cl_bcs_convert=>string_to_soli( build_html( is_payment ) ).

    TRY.
        lo_request = cl_bcs=>create_persistent( ).

        lo_document = cl_document_bcs=>create_document(
          i_type    = 'HTM'
          i_text    = lt_body
          i_subject = lv_title ).
        lo_request->set_document( lo_document ).
        " Assunto longo (> 50 caracteres) sem truncar
        lo_request->set_message_subject( ip_subject = lv_subject ).

        lo_sender = cl_cam_address_bcs=>create_internet_address( mv_sender ).
        lo_request->set_sender( lo_sender ).

        lo_recipient = cl_cam_address_bcs=>create_internet_address( iv_recipient ).
        lo_request->add_recipient( i_recipient = lo_recipient
                                   i_express   = abap_false ).

        lo_request->set_send_immediately( abap_true ).

        lv_sent = lo_request->send( i_with_error_screen = abap_false ).
        IF lv_sent <> abap_true.
          RAISE EXCEPTION TYPE zcx_fi_pay_notify
            EXPORTING iv_text = 'CL_BCS não aceitou o pedido de envio'.
        ENDIF.

        rv_oid = lo_request->oid( ).

      CATCH cx_bcs INTO lx_bcs.
        RAISE EXCEPTION TYPE zcx_fi_pay_notify EXPORTING previous = lx_bcs.
    ENDTRY.
  ENDMETHOD.


  METHOD build_subject.
    rv_subject = |Notificação de Pagamento - HCB - Ref. { is_payment-vblnr }|.
  ENDMETHOD.


  METHOD build_html.
    DATA: ls_doc    TYPE zcl_fi_pay_notify_data=>ty_doc,
          lv_rows   TYPE string,
          lv_value  TYPE wrbtr,
          lv_vendor TYPE string.

    lv_vendor = is_payment-lifnr.
    SHIFT lv_vendor LEFT DELETING LEADING '0'.

    LOOP AT is_payment-docs INTO ls_doc.
      " Factura (crédito no fornecedor) positiva, nota de crédito negativa
      lv_value = ls_doc-wrbtr.
      IF ls_doc-shkzg = 'S'.
        lv_value = - lv_value.
      ENDIF.
      lv_rows = lv_rows
        && |<tr><td>{ html( ls_doc-belnr ) }/{ ls_doc-gjahr }</td>|
        && |<td>{ html( ls_doc-xblnr ) }</td>|
        && |<td>{ fmt_date( ls_doc-bldat ) }</td>|
        && |<td style="text-align:right">{ fmt_amount( iv_amount = lv_value iv_waers = ls_doc-waers ) }</td></tr>|.
    ENDLOOP.

    IF lv_rows IS INITIAL.
      lv_rows = '<tr><td colspan="4">-</td></tr>'.
    ENDIF.

    rv_html =
         |<html><body style="font-family:Arial,sans-serif;font-size:13px;color:#222">|
      && |<p>Prezado(a) Fornecedor,</p>|
      && |<p>Informamos que foi efectuado um pagamento a favor da vossa empresa, |
      && |referente aos documentos abaixo identificados.</p>|
      && |<h4 style="margin-bottom:4px">Dados do pagamento</h4>|
      && |<table cellpadding="4" style="border-collapse:collapse">|
      && |<tr><td><b>Fornecedor</b></td><td>{ html( lv_vendor ) } - { html( is_payment-name1 ) }</td></tr>|
      && |<tr><td><b>Refer&ecirc;ncia do pagamento</b></td><td>{ html( is_payment-vblnr ) }</td></tr>|
      && |<tr><td><b>Data</b></td><td>{ fmt_date( is_payment-zaldt ) }</td></tr>|
      && |<tr><td><b>Montante</b></td><td>{ fmt_amount( iv_amount = is_payment-amount iv_waers = is_payment-waers ) }</td></tr>|
      && |</table>|
      && |<h4 style="margin-bottom:4px">Documentos liquidados</h4>|
      && |<table border="1" cellpadding="4" style="border-collapse:collapse">|
      && |<tr style="background:#eee"><th>Documento</th><th>Refer&ecirc;ncia da factura</th><th>Data</th><th>Valor</th></tr>|
      && lv_rows
      && |</table>|
      && |<p>Agradecemos a vossa colabora&ccedil;&atilde;o.</p>|
      && |<p>Com os melhores cumprimentos,<br>{ mv_company }</p>|
      && |<p style="font-size:11px;color:#777">Mensagem autom&aacute;tica. Por favor, n&atilde;o responda directamente a este e-mail.</p>|
      && |</body></html>|.
  ENDMETHOD.


  METHOD html.
    rv_html = escape( val = iv_text format = cl_abap_format=>e_html_text ).
  ENDMETHOD.


  METHOD fmt_amount.
    DATA lv_out TYPE c LENGTH 30.

    WRITE iv_amount TO lv_out CURRENCY iv_waers.
    rv_text = lv_out.
    CONDENSE rv_text.
    rv_text = |{ rv_text } { iv_waers }|.
  ENDMETHOD.


  METHOD fmt_date.
    IF iv_date IS INITIAL.
      rv_text = '-'.
    ELSE.
      rv_text = |{ iv_date+6(2) }/{ iv_date+4(2) }/{ iv_date(4) }|.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
