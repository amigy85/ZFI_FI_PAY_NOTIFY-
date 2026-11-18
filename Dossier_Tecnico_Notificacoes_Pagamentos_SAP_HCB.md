# Dossier Técnico --- Notificações Automáticas de Pagamentos SAP HCB

**Estado:** Diagnóstico e desenho funcional/técnico em curso\
**Sistema:** SAP ECC 6.0 EHP7\
**Componentes:** FI, BCM, F110, PAIN.002, ABAP e SAPconnect\
**Organização:** Hidroeléctrica de Cahora Bassa (HCB)

------------------------------------------------------------------------

## 1. Objectivo

Foi identificada uma oportunidade de melhoria no processo de Pagamentos
Automáticos: enviar automaticamente um e-mail ao fornecedor com o aviso
de pagamento, no momento adequado do ciclo bancário.

Benefícios esperados: - Melhorar a comunicação com fornecedores. -
Reduzir pedidos manuais de comprovativos. - Aumentar a transparência do
processo. - Reduzir tarefas manuais de Finanças e Procurement.

## 2. Decisões confirmadas

  -----------------------------------------------------------------------
  Dimensão                            Decisão
  ----------------------------------- -----------------------------------
  Processo                            F110 + Bank Communication
                                      Management (BCM)

  Momento de envio                    Após confirmação bancária

  Origem do e-mail                    Dados gerais/endereço do fornecedor
                                      (LFA1/endereço associado)

  Formato do retorno                  ISO 20022 PAIN.002

  Confirmação actualmente utilizada   Estado no BCM
  -----------------------------------------------------------------------

**Ponto por confirmar:** qual o estado interno BCM que representa
liquidação efectiva, em vez de mera aceitação da instrução.

## 3. Fluxo funcional proposto

1.  F110 executa o pagamento.
2.  BCM gere lotes, aprovações e instruções.
3.  A instrução é transmitida ao banco.
4.  O banco devolve PAIN.002.
5.  SAP processa o retorno e actualiza os estados BCM.
6.  Um componente Z identifica pagamentos individualmente elegíveis.
7.  São obtidos e validados os dados do fornecedor e o e-mail.
8.  O e-mail é enviado através de SAPconnect/CL_BCS.
9.  O resultado é registado para auditoria, prevenção de duplicações e
    reprocessamento.

### Regra fundamental

A notificação não deve ser desencadeada apenas pela criação/aprovação do
lote ou transmissão ao banco. Deve ocorrer apenas quando existir
confirmação que, segundo o mapeamento e processo da HCB, represente
liquidação efectiva.

Um lote pode conter vários fornecedores e resultados diferentes. A
elegibilidade deve ser avaliada por instrução/pagamento individual.

  -----------------------------------------------------------------------
  Situação                            Tratamento
  ----------------------------------- -----------------------------------
  Lote criado/aprovado                Não notificar

  Instrução transmitida               Não notificar

  Banco aceitou, liquidação pendente  Aguardar

  Pagamento confirmado como liquidado Elegível

  Pagamento rejeitado                 Não enviar notificação de sucesso

  Lote parcialmente processado        Avaliar cada pagamento
                                      individualmente
  -----------------------------------------------------------------------

## 4. Conteúdo proposto do e-mail

Dados a apresentar:

  Informação                Origem técnica a validar
  ------------------------- ---------------------------------------
  Código do fornecedor      Dados do pagamento/FI
  Nome                      LFA1
  E-mail                    ADR6/endereço associado
  Referência do pagamento   Dados do pagamento/BCM
  Data efectiva             Retorno bancário ou estado confirmado
  Montante                  Informação confirmada/documento FI
  Moeda                     Documento FI
  Documentos liquidados     REGUP/documentos FI
  Referência bancária       Retorno, quando disponível

O valor comunicado deve reflectir o montante efectivamente confirmado,
quando disponível, e não apenas o montante originalmente instruído.

### Exemplo de mensagem

**Assunto:** Notificação de Pagamento --- HCB

> Prezado(a) Fornecedor,
>
> Informamos que foi efectuado um pagamento a favor da vossa empresa,
> referente aos documentos abaixo identificados.
>
> **Dados do pagamento:** fornecedor, referência, data, moeda e
> montante.
>
> **Documentos liquidados:** número do documento, referência da factura
> e valor.
>
> Agradecemos a vossa colaboração.
>
> Com os melhores cumprimentos,\
> Hidroeléctrica de Cahora Bassa, S.A.
>
> Mensagem automática. Por favor, não responda directamente a este
> e-mail.

## 5. Arquitectura técnica proposta

### Componentes standard identificados

  -----------------------------------------------------------------------
  Componente                          Responsabilidade
  ----------------------------------- -----------------------------------
  F110                                Execução dos pagamentos

  BCM                                 Gestão de lotes e estados

  PAIN.002                            Retorno bancário de estado

  `RBNK_IMPORT_PAYM_STATUS_REPORT`    Programa standard identificado para
                                      importação do relatório

  `BNK_MONI`                          Monitorização BCM

  LFA1/ADR6                           Dados do fornecedor e endereços

  `CL_BCS`                            Construção e envio de mensagens

  SCOT                                Configuração SAPconnect/SMTP

  SOST                                Monitorização de mensagens
  -----------------------------------------------------------------------

### Objectos Z propostos --- ainda não desenvolvidos

  --------------------------------------------------------------------------
  Objecto                    Tipo                    Responsabilidade
  -------------------------- ----------------------- -----------------------
  `ZFI_PAY_NOTIFY`           Programa                Orquestração

  `ZCL_FI_PAY_NOTIFY`        Classe                  Regras de negócio e
                                                     controlo

  `ZCL_FI_PAY_NOTIFY_DATA`   Classe                  Obtenção dos dados de
                                                     pagamento/fornecedor

  `ZCL_FI_PAY_NOTIFY_MAIL`   Classe                  Construção e envio do
                                                     e-mail

  `ZFI_PAY_NOTIF`            Tabela                  Histórico e prevenção
                                                     de duplicações

  `ZFI_PAY_NOTIFY_JOB`       Job                     Processamento periódico

  `ZFI_PAY_NOTIF_MON`        Transacção              Consulta e gestão das
                                                     notificações
  --------------------------------------------------------------------------

### Estratégia

A solução deve ser desacoplada do processamento financeiro: - O standard
BCM continua responsável pelo PAIN.002. - A solução Z identifica
pagamentos elegíveis. - O envio é independente do processamento do
pagamento. - Falhas de e-mail não podem reverter ou bloquear
pagamentos. - Deve existir reprocessamento controlado.

Um job Z periódico é a opção de referência caso não seja identificado um
ponto de extensão standard adequado.

## 6. Estados PAIN.002 a validar

  Código   Interpretação geral                 Tratamento proposto
  -------- ----------------------------------- -------------------------
  ACTC     Aceitação técnica                   Não notificar
  ACCP     Aceite pelo cliente                 Não notificar
  ACSP     Processamento/liquidação em curso   Aguardar
  ACSC     Liquidação concluída                Potencialmente elegível
  RJCT     Rejeitado                           Não enviar sucesso
  PART     Parcialmente aceite                 Avaliar individualmente

Esta tabela é uma referência de análise, não uma confirmação do
mapeamento HCB. Os códigos recebidos do banco e o mapeamento
externo/interno devem ser confirmados no sistema. `ACSC` é candidato a
estado de liquidação, mas a sua utilização depende do retorno e
configuração reais.

## 7. Diagnóstico técnico realizado

### 7.1 Programa de importação

Foi identificado `RBNK_IMPORT_PAYM_STATUS_REPORT`, relacionado com a
importação do PAIN.002. A execução deste programa não implica que todas
as BAdIs do BCM sejam chamadas; cada uma tem contexto e condições
próprias.

### 7.2 Configuração SPRO visualizada

No ecrã Administração de status de pagamento foram observadas as
actividades: - Definir directórios para upload do file. - Atribuir
status externo a status interno. - Timeout para actualização de status
de batch. - BAdI: partição de um file importado. - BAdI: implementação
para categorias do alerta. - BAdI: ações após erro na criação de um file
de pagamento. - BAdI: ampliação do Enterprise Service CPON.

A actividade **Atribuir status externo a status interno** é prioritária
para a próxima análise.

### 7.3 BAdI CPON

Foi analisada a implementação/classe `ZCL_BNK_BADI_CPON_ENHANCE`.

Interface: `IF_EX_BNK_CPON_ENHANCE`

Métodos: - `FIND_BATCH` - `ITEM_TAB_BUILD` - `IGNORE_STATUS_CHANGE`

A documentação apresentada indica que esta BAdI influencia a localização
do batch e dos pagamentos no Enterprise Service
`CollectivePaymentOrderNotification` (CPON), e permite ignorar mensagens
individuais.

Conclusão provisória: não há evidência de que seja o ponto de integração
apropriado para enviar notificações durante a importação directa do
PAIN.002.

### 7.4 BAdI de divisão de ficheiros PSR

Foi visualizada a classe `ZCL_BNK_SPLIT_FILE_EXAMPLE`, método:

`IF_BNK_SPLIT_FILE_2_PSRS~SPLIT_PSR_FILE`

Descrição no Class Builder: "Split file into individual XML Payment
Status Reports".

Foi colocado breakpoint, mas o método não foi executado no teste. Isto
pode ser normal se o ficheiro não precisar de ser dividido, por exemplo,
se já contiver apenas um relatório PSR. A não execução não prova erro.

### 7.5 BAdI de alertas de estado de pagamento

Foi identificada uma implementação activa:

  Elemento        Valor
  --------------- ---------------------------
  BAdI            `BNK_BADI_PAYM_ALRT`
  Implementação   `Z_BNK_BADI_PAYM_ALRT`
  Interface       `IF_EX_BNK_PAYM_ALRT`
  Classe          `ZCL_IF_EX_BNK_PAYM_ALRT`

Métodos: - `IF_EX_BNK_PAYM_ALRT~SEND_ALERT` -
`IF_EX_BNK_PAYM_ALRT~SEND_TIMEOUT_ALERT`

O método `SEND_ALERT` foi visualizado e estava vazio:

``` abap
METHOD if_ex_bnk_paym_alrt~send_alert.
ENDMETHOD.
```

Assinatura observada:

  Parâmetro       Tipo                          Descrição
  --------------- ----------------------------- -----------------------------
  `I_BATCH_NO`    `BNK_COM_BTCH_NO`             Batch Identification Number
  `I_ITEM_NO`     `BNK_COM_BTCH_CNT_OPTIONAL`   Item Count Number
  `I_ITEM_GUID`   `BNK_COM_BTCH_GUID`           GUID to identify the batch
  `I_STATS_CD`    `BNK_COM_STSCD`               Status Code
  `FLT_VAL`       `STRING`                      Valor do filtro

Foi colocado breakpoint em `SEND_ALERT`, mas não foi atingido no teste
relatado.

Conclusão provisória: a BAdI pertence ao mecanismo de alertas de estado
do BCM. Não se deve assumir que é chamada para todas as alterações de
estado ou estados positivos. É necessário verificar a associação às
categorias de alerta e as condições de chamada.

### 7.6 Objectos indicados para rastrear a chamada da BAdI

Foram apontados para investigação: - Classe `CL_BNK_PROC_STATUS`. -
Grupo de funções `BNK_API_HANDLE_PAYM_STAT`.

Pesquisar chamadas `CALL BADI` relacionadas com
`IF_EX_BNK_PAYM_ALRT~SEND_ALERT`. Confirmar directamente no ECC da HCB.

## 8. Resultados dos breakpoints

  -------------------------------------------------------------------------------------------
  Teste                                       Resultado               Interpretação
  ------------------------------------------- ----------------------- -----------------------
  `IF_EX_BNK_PAYM_ALRT~SEND_ALERT`            Não parou               Investigar categoria,
                                                                      estado e contexto de
                                                                      execução

  `IF_BNK_SPLIT_FILE_2_PSRS~SPLIT_PSR_FILE`   Não parou               Pode não ter sido
                                                                      necessária divisão do
                                                                      ficheiro

  Importação via                              Programa utilizado      Rastrear sequência de
  `RBNK_IMPORT_PAYM_STATUS_REPORT`                                    chamadas e actualização
                                                                      de estados
  -------------------------------------------------------------------------------------------

Se o processamento ocorrer em background ou noutra sessão, considerar
breakpoint externo e confirmar o utilizador técnico que executa o
processamento.

## 9. Regras de negócio e controlos propostos

1.  Só pagamentos com confirmação positiva e estado interno elegível
    podem gerar notificação.
2.  O controlo é feito por instrução individual.
3.  Cada pagamento gera no máximo uma notificação de sucesso, salvo
    reenvio autorizado.
4.  O e-mail é validado antes do envio.
5.  Sem e-mail válido, o pagamento continua concluído e a notificação
    fica pendente de correcção.
6.  Falha SAPconnect não afecta o pagamento.
7.  Deve existir reprocessamento.
8.  Todas as tentativas e resultados são registados.
9.  Pagamentos rejeitados não geram notificação de sucesso.
10. Pagamentos parciais são tratados individualmente.

## 10. Tabela Z proposta

Tabela: `ZFI_PAY_NOTIF`.

  Campo          Descrição
  -------------- ----------------------------------
  MANDT          Mandante
  BUKRS          Empresa
  LAUFD          Data da execução F110
  LAUFI          Identificação da execução
  LIFNR          Fornecedor
  ZPAYMENT_ID    Identificador único do pagamento
  BANK_STATUS    Estado recebido do banco
  PAYMENT_DATE   Data efectiva do pagamento
  AMOUNT         Valor pago
  WAERS          Moeda
  EMAIL          Destinatário
  STATUS         Estado da notificação
  SENT_DATE      Data/hora de envio
  RETRY_COUNT    Número de tentativas
  LAST_ERROR     Último erro
  MESSAGE_ID     Identificador da mensagem

Estados propostos:

  Estado      Significado
  ----------- -------------------------------------------
  PENDING     Aguardando processamento
  READY       Dados validados
  SENT        Aceite para processamento pelo SAPconnect
  ERROR       Erro no processamento
  NO_EMAIL    Fornecedor sem e-mail válido
  CANCELLED   Notificação cancelada

A chave deve identificar univocamente a instrução de pagamento. Não deve
ser apenas o fornecedor. `SENT` não prova entrega na caixa do
fornecedor; a monitorização posterior deve considerar SOST e os estados
SAPconnect.

## 11. Obtenção do e-mail do fornecedor

Relação conceptual a validar:

-   `LFA1-LIFNR`: código do fornecedor.
-   `LFA1-ADRNR`: número de endereço.
-   `ADR6-ADDRNUMBER`: número do endereço.
-   `ADR6-SMTP_ADDR`: endereço de e-mail.
-   `ADR6-FLGDEFAULT`: indicador de endereço padrão.

A lógica deverá respeitar validade, associação correcta e múltiplos
endereços. Não assumir que o primeiro registo ADR6 é o destinatário
correcto.

## 12. Critérios de aceitação

1.  Pagamento confirmado gera notificação automática.
2.  Conteúdo apresenta os dados correctos.
3.  Destinatário corresponde ao fornecedor.
4.  Pagamentos rejeitados não geram notificação de sucesso.
5.  Pagamentos parciais são tratados individualmente.
6.  Não há notificações duplicadas.
7.  Falha de envio não afecta pagamentos.
8.  Existe histórico e reenvio.
9.  Finanças consegue consultar o estado das notificações.

## 13. Plano de implementação

  Fase   Actividade                           Entregável
  ------ ------------------------------------ -----------------------
  1      Diagnóstico BCM e PAIN.002           Mapeamento técnico
  2      Identificação de estados e tabelas   Especificação técnica
  3      Validação de pontos de extensão      Decisão arquitectural
  4      Desenvolvimento DDIC Z               Estruturas
  5      Desenvolvimento ABAP                 Classes
  6      Template HTML                        Modelo de e-mail
  7      Processamento automático             Job
  8      Monitorização e reprocessamento      Transacção Z
  9      Testes                               Evidências
  10     Transporte e produção                Solução operacional

## 14. Próximas actividades pendentes

### Actividade 1 --- Mapeamento de estados

No SPRO, abrir **Administração de status de pagamento → Atribuir status
externo a status interno**.

Registar: - Código externo recebido no PAIN.002. - Descrição externa. -
Código interno atribuído. - Descrição interna. - Categoria de alerta
associada, se aplicável.

Objectivo: identificar o estado interno que representa liquidação
efectiva.

### Actividade 2 --- Categorias de alerta

No SPRO, abrir **BAdI: implementação para categorias do alerta**.

Verificar: - Categorias configuradas. - Implementações atribuídas. -
Filtros. - Associação da `Z_BNK_BADI_PAYM_ALRT`.

### Actividade 3 --- Chamadas da BAdI

Na SE24, analisar `CL_BNK_PROC_STATUS`. No grupo de funções
`BNK_API_HANDLE_PAYM_STAT`, procurar chamadas relacionadas com
`IF_EX_BNK_PAYM_ALRT~SEND_ALERT`.

### Actividade 4 --- Log PAIN.002

Utilizar SLG1. Foi sugerido verificar: - Objecto `FBNK`. - Subobjecto
`STATUSREPORT`.

Confirmar no sistema se estes identificadores são utilizados pela versão
instalada.

### Actividade 5 --- BNK_MONI

Abrir um lote que tenha recebido PAIN.002 e inspeccionar uma instrução
individual. Registar lote, item, GUID, estados anterior/posterior,
referência FI e data/hora da actualização.

### Actividade 6 --- ST05

Se necessário, executar SQL Trace durante a importação para identificar
tabelas efectivamente consultadas e actualizadas. Não assumir nomes de
tabelas BCM sem confirmação no sistema HCB.

## 15. Decisões arquitecturais actuais

  -----------------------------------------------------------------------
  Tema                                Decisão/posição
  ----------------------------------- -----------------------------------
  Processo                            F110 + BCM

  Retorno                             PAIN.002

  Confirmação                         Estado BCM

  Momento de notificação              Após confirmação de liquidação

  E-mail                              Dados gerais/endereço do fornecedor

  Envio                               `CL_BCS` / SAPconnect

  Monitorização                       SOST

  Duplicações                         Tabela Z

  BAdI CPON                           Não alterar nesta fase

  BAdI split PSR                      Não alterar nesta fase

  BAdI de alertas                     Manter para alertas BCM e
                                      investigar

  Estratégia                          Componente Z desacoplado

  Disparo                             Job Z periódico como opção de
                                      referência, sujeito à validação
  -----------------------------------------------------------------------

## 16. Pontos ainda não confirmados

-   Versão exacta do PAIN.002 recebido.
-   Códigos externos efectivamente utilizados pelo banco.
-   Mapeamento externo/interno no BCM HCB.
-   Estado interno que representa liquidação efectiva.
-   Tabelas BCM que persistem o estado individual.
-   Condições de chamada da BAdI `BNK_BADI_PAYM_ALRT`.
-   Ponto de extensão standard adequado, se existir.
-   Identificador único para idempotência.
-   Regra de selecção de e-mail em fornecedores com múltiplos endereços.

## 17. Instruções para continuidade no Claude Code / VS Code

Utilizar este dossier como contexto funcional e técnico.

1.  Não iniciar desenvolvimento ABAP antes de concluir o mapeamento dos
    estados BCM.
2.  Não inventar tabelas, métodos, BAdIs ou estruturas standard.
3.  Confirmar os objectos directamente no ECC 6.0 EHP7 da HCB.
4.  Separar factos observados, hipóteses e decisões arquitecturais.
5.  Preservar o processamento standard F110/BCM/PAIN.002.
6.  Implementar idempotência e reprocessamento.
7.  Garantir que falhas de comunicação não afectam o pagamento.
8.  Documentar decisões e evidências técnicas.

### Próximo passo imediato

Obter screenshots das configurações: - **Atribuir status externo a
status interno**. - **BAdI: implementação para categorias do alerta**.

Com esses dados, concluir o diagnóstico do estado de liquidação e
decidir o ponto de integração mais seguro.

------------------------------------------------------------------------

## 18. Histórico resumido da conversa

1.  Foi apresentada a oportunidade de melhoria no envio de e-mail de
    aviso de pagamento aos fornecedores.
2.  Foram definidas as decisões: processo BCM, envio após confirmação
    bancária e endereço do fornecedor.
3.  Foi desenhado o fluxo funcional e proposta arquitectura ABAP
    desacoplada.
4.  Foi confirmado o retorno PAIN.002 e a confirmação por estado no BCM.
5.  Foi identificado o programa `RBNK_IMPORT_PAYM_STATUS_REPORT`.
6.  Foram analisadas configurações BCM e a BAdI CPON.
7.  Foi identificada a implementação activa `Z_BNK_BADI_PAYM_ALRT`, com
    `SEND_ALERT` vazio.
8.  Foram colocados breakpoints em `SEND_ALERT` e `SPLIT_PSR_FILE`, sem
    serem atingidos no teste relatado.
9.  Concluiu-se que é necessário verificar condições de chamada,
    categorias de alerta e mapeamento de estados.
10. A próxima etapa é concluir o diagnóstico do estado interno de
    liquidação e fechar o desenho técnico definitivo.

**Fim do dossier --- versão de trabalho, diagnóstico em curso.**
