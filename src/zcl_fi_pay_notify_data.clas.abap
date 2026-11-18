"! Leitura de dados para a notificação de pagamento:
"! itens do lote BCM, estado interno BCM do item, pagamento F110
"! (REGUH/REGUP) e e-mail do fornecedor (LFA1/ADR6).
CLASS zcl_fi_pay_notify_data DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    TYPES:
      BEGIN OF ty_doc,
        bukrs TYPE regup-bukrs,
        belnr TYPE regup-belnr,
        gjahr TYPE regup-gjahr,
        xblnr TYPE regup-xblnr,
        bldat TYPE regup-bldat,
        wrbtr TYPE regup-wrbtr,
        shkzg TYPE regup-shkzg,
        waers TYPE regup-waers,
      END OF ty_doc,
      tt_doc TYPE STANDARD TABLE OF ty_doc WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_payment,
        batch_no TYPE bnk_com_btch_no,
        item_no  TYPE bnk_com_btch_cnt,
        zbukr    TYPE reguh-zbukr,
        laufd    TYPE reguh-laufd,
        laufi    TYPE reguh-laufi,
        vblnr    TYPE reguh-vblnr,
        lifnr    TYPE reguh-lifnr,
        name1    TYPE lfa1-name1,
        zaldt    TYPE reguh-zaldt,
        amount   TYPE reguh-rwbtr,
        waers    TYPE reguh-waers,
        docs     TYPE tt_doc,
      END OF ty_payment.

    "! Estado BCM do item, simplificado para a regra de negócio
    CONSTANTS:
      BEGIN OF gc_bcm_state,
        accepted TYPE char1 VALUE 'A',
        rejected TYPE char1 VALUE 'R',
        pending  TYPE char1 VALUE 'P',
      END OF gc_bcm_state.

    "! Lê os itens de um lote BCM com a API standard CL_BNK_PROC_BATCH
    METHODS get_batch_items
      IMPORTING iv_batch_no     TYPE bnk_com_btch_no
      RETURNING VALUE(rt_items) TYPE bnk_tab_batch_item
      RAISING   zcx_fi_pay_notify.

    "! Estado interno activo do item (IBC17 = banco aceitou, IBC19 = rejeitado)
    METHODS get_item_bcm_state
      IMPORTING is_item         TYPE bnk_str_batch_item
      RETURNING VALUE(rv_state) TYPE char1
      RAISING   zcx_fi_pay_notify.

    "! Dados do pagamento F110 e documentos liquidados
    METHODS read_payment
      IMPORTING is_item           TYPE bnk_str_batch_item
      RETURNING VALUE(rs_payment) TYPE ty_payment
      RAISING   zcx_fi_pay_notify.

    "! E-mail do endereço geral do fornecedor (LFA1-ADRNR -> ADR6)
    METHODS get_vendor_email
      IMPORTING iv_lifnr        TYPE lifnr
      RETURNING VALUE(rv_email) TYPE ad_smtpadr.

    CLASS-METHODS is_valid_email
      IMPORTING iv_email        TYPE ad_smtpadr
      RETURNING VALUE(rv_valid) TYPE abap_bool.

  PROTECTED SECTION.
  PRIVATE SECTION.
    CONSTANTS:
      gc_stat_bank_accepted TYPE j_istat VALUE 'IBC17',
      gc_stat_bank_rejected TYPE j_istat VALUE 'IBC19'.
ENDCLASS.



CLASS zcl_fi_pay_notify_data IMPLEMENTATION.

  METHOD get_batch_items.
    DATA: lo_batch     TYPE REF TO cl_bnk_proc_batch,
          lt_batch_no  TYPE bnk_tab_batch_no,
          lt_header    TYPE bnk_tab_batch_header,
          lv_no_auth   TYPE char1,
          lx_bnk       TYPE REF TO cx_bnk_proc,
          lv_text      TYPE string.

    APPEND iv_batch_no TO lt_batch_no.

    TRY.
        cl_bnk_proc_batch=>s_instance(
          IMPORTING e_ref_bnk_proc_batch = lo_batch ).

        lo_batch->read(
          EXPORTING i_tab_batch_no     = lt_batch_no
          IMPORTING e_tab_batch_header = lt_header
                    e_tab_batch_items  = rt_items
                    e_no_auth          = lv_no_auth ).
      CATCH cx_bnk_proc INTO lx_bnk.
        RAISE EXCEPTION TYPE zcx_fi_pay_notify
          EXPORTING previous = lx_bnk.
    ENDTRY.

    IF lv_no_auth IS NOT INITIAL.
      lv_text = |Sem autorização para ler o lote BCM { iv_batch_no }|.
      RAISE EXCEPTION TYPE zcx_fi_pay_notify EXPORTING iv_text = lv_text.
    ENDIF.
  ENDMETHOD.


  METHOD get_item_bcm_state.
    DATA: lv_guid     TYPE bnk_com_btch_guid,
          lt_sys_stat TYPE bnk_tab_sys_stat,
          lt_return   TYPE bapiret2_t,
          ls_return   TYPE bapiret2,
          lv_text     TYPE string.

    lv_guid = is_item-status.

    CALL FUNCTION 'BNK_API_GET_STATUS'
      EXPORTING
        i_object_id    = lv_guid
        i_flag_active  = abap_true
      IMPORTING
        e_tab_sys_stat = lt_sys_stat
        e_tab_rc       = lt_return.

    READ TABLE lt_return INTO ls_return WITH KEY type = 'E'.
    IF sy-subrc = 0.
      lv_text = ls_return-message.
      IF lv_text IS INITIAL.
        lv_text = |Erro ao ler estado BCM do item { is_item-item_no }|.
      ENDIF.
      RAISE EXCEPTION TYPE zcx_fi_pay_notify EXPORTING iv_text = lv_text.
    ENDIF.

    " A rejeição prevalece sobre qualquer outro estado activo.
    READ TABLE lt_sys_stat TRANSPORTING NO FIELDS
         WITH KEY sys_stat = gc_stat_bank_rejected.
    IF sy-subrc = 0.
      rv_state = gc_bcm_state-rejected.
      RETURN.
    ENDIF.

    READ TABLE lt_sys_stat TRANSPORTING NO FIELDS
         WITH KEY sys_stat = gc_stat_bank_accepted.
    IF sy-subrc = 0.
      rv_state = gc_bcm_state-accepted.
    ELSE.
      rv_state = gc_bcm_state-pending.
    ENDIF.
  ENDMETHOD.


  METHOD read_payment.
    DATA: lv_laufd TYPE reguh-laufd,
          lv_laufi TYPE reguh-laufi,
          lv_text  TYPE string.

    rs_payment-batch_no = is_item-batch_no.
    rs_payment-item_no  = is_item-item_no.
    rs_payment-zbukr    = is_item-zbukr.
    rs_payment-vblnr    = is_item-vblnr.
    rs_payment-lifnr    = is_item-lifnr.

    " A ligação item BCM -> REGUH é feita primeiro pela execução do item
    " (LAUFD/LAUFI) e, se não existir, pela execução original (LAUFD_O/LAUFI_O).
    lv_laufd = is_item-laufd.
    lv_laufi = is_item-laufi.

    SELECT SINGLE zaldt rwbtr waers
      FROM reguh
      INTO (rs_payment-zaldt, rs_payment-amount, rs_payment-waers)
      WHERE laufd = lv_laufd
        AND laufi = lv_laufi
        AND xvorl = space
        AND zbukr = is_item-zbukr
        AND lifnr = is_item-lifnr
        AND kunnr = is_item-kunnr
        AND empfg = is_item-empfg
        AND vblnr = is_item-vblnr.

    IF sy-subrc <> 0 AND is_item-laufd_o IS NOT INITIAL.
      lv_laufd = is_item-laufd_o.
      lv_laufi = is_item-laufi_o.

      SELECT SINGLE zaldt rwbtr waers
        FROM reguh
        INTO (rs_payment-zaldt, rs_payment-amount, rs_payment-waers)
        WHERE laufd = lv_laufd
          AND laufi = lv_laufi
          AND xvorl = space
          AND zbukr = is_item-zbukr
          AND lifnr = is_item-lifnr
          AND kunnr = is_item-kunnr
          AND empfg = is_item-empfg
          AND vblnr = is_item-vblnr.
    ENDIF.

    IF sy-subrc <> 0.
      lv_text = |Pagamento { is_item-vblnr } não encontrado em REGUH|.
      RAISE EXCEPTION TYPE zcx_fi_pay_notify EXPORTING iv_text = lv_text.
    ENDIF.

    rs_payment-laufd  = lv_laufd.
    rs_payment-laufi  = lv_laufi.
    " RWBTR é negativo nos pagamentos a fornecedores.
    rs_payment-amount = abs( rs_payment-amount ).

    SELECT bukrs belnr gjahr xblnr bldat wrbtr shkzg waers
      FROM regup
      INTO CORRESPONDING FIELDS OF TABLE rs_payment-docs
      WHERE laufd = lv_laufd
        AND laufi = lv_laufi
        AND xvorl = space
        AND zbukr = is_item-zbukr
        AND lifnr = is_item-lifnr
        AND kunnr = is_item-kunnr
        AND empfg = is_item-empfg
        AND vblnr = is_item-vblnr.

    SORT rs_payment-docs BY gjahr belnr.

    SELECT SINGLE name1 FROM lfa1 INTO rs_payment-name1
      WHERE lifnr = is_item-lifnr.
  ENDMETHOD.


  METHOD get_vendor_email.
    TYPES:
      BEGIN OF ty_adr6,
        consnumber TYPE adr6-consnumber,
        flgdefault TYPE adr6-flgdefault,
        flg_nouse  TYPE adr6-flg_nouse,
        smtp_addr  TYPE adr6-smtp_addr,
      END OF ty_adr6.

    DATA: lv_adrnr TYPE lfa1-adrnr,
          lt_adr6  TYPE STANDARD TABLE OF ty_adr6,
          ls_adr6  TYPE ty_adr6.

    SELECT SINGLE adrnr FROM lfa1 INTO lv_adrnr WHERE lifnr = iv_lifnr.
    IF sy-subrc <> 0 OR lv_adrnr IS INITIAL.
      RETURN.
    ENDIF.

    " Endereço geral da organização (sem pessoa), válido à data de hoje.
    SELECT consnumber flgdefault flg_nouse smtp_addr
      FROM adr6
      INTO TABLE lt_adr6
      WHERE addrnumber = lv_adrnr
        AND persnumber = space
        AND date_from <= sy-datum.

    DELETE lt_adr6 WHERE flg_nouse IS NOT INITIAL OR smtp_addr IS INITIAL.

    " Primeiro o endereço marcado como padrão; caso não exista, o de
    " menor número sequencial. A regra final está por confirmar (dossier §16).
    SORT lt_adr6 BY flgdefault DESCENDING consnumber ASCENDING.

    LOOP AT lt_adr6 INTO ls_adr6.
      IF is_valid_email( ls_adr6-smtp_addr ) = abap_true.
        rv_email = ls_adr6-smtp_addr.
        RETURN.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD is_valid_email.
    DATA lv_email TYPE string.

    lv_email = iv_email.
    CONDENSE lv_email.
    FIND REGEX '^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$' IN lv_email.
    IF sy-subrc = 0.
      rv_valid = abap_true.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
