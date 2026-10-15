# Marco B — Proposta técnica revisada (rev. 2)

- **Estado:** revisão 2. Estrutura geral aprovada; ajustes da avaliação de 15/10/2026 incorporados. **Nada está implementado.**
- **Base:** Especificação v1.1 (§6, §7.1–7.8, §8 FIN-02 a FIN-05, §11, §13) + avaliação da rev. 1.
- **Escopo:** só Marco B. **Não** antecipa BI, IA nem PWA. A conciliação com extratos (Marco D) entra só como ponto de extensão (campos e estados), sem importação.
- **Dados reais:** esta aprovação **não autoriza** dados financeiros reais. A homologação do Marco A e o gate §10 continuam obrigatórios. Toda execução usa dados fictícios.
- **Próximo passo:** com esta revisão validada → DDL nas migrations → testes-oráculo (pgTAP e integração) **antes** das telas.

### Mudanças em relação à rev. 1

| Avaliação | Mudança | Onde |
|---|---|---|
| 1. Cartões | política por cartão para compras no dia do fechamento; quatro posições distintas (dívida, fatura, futuras, limite); datas confirmadas prevalecem; ciclos fechados, pagos ou confirmados são imutáveis | §5 |
| 2. Parcelas e estornos | estorno é crédito e não cancela parcelas; ajuste de parcelas é operação explícita com soma fechada; conciliação dívida = obrigações + aberto + futuras − créditos | §6, §7 |
| 3. Cancelamento e reversão | razão somente-acréscimo; **anulação** (compensação com data efetiva da original) × **reversão** (movimento real na data em que ocorreu); bloqueio por dependentes | §8 |
| 4. Competência | competência, vencimento e liquidação em campos distintos; consumo de contas a pagar reconhecido por pagamento, sem dupla contagem; indicadores sempre derivados | §4, §9 |
| 5. Permissões | transferência entre titulares exige `create` nas duas pontas; erros não revelam existência; endurecimento de funções verificado por teste | §10, §12 |
| 6. Concorrência e jobs | testes concorrentes de pagamento, estorno e ajuste de parcelas; obrigações idempotentes; registro de execução e falha dos jobs | §11, §14 |

---

## 1. Escopo do Marco B

| Entra | Não entra |
|---|---|
| FIN-02 contas, saldo inicial, saldo, extrato | metas e orçamentos (D) |
| FIN-03 cartões, ciclos, faturas, parcelas, posições do cartão | importação e conciliação automática (D) |
| FIN-04 receitas, despesas, transferências, compras parceladas (online) | offline/PWA (C) |
| FIN-05 obrigações, pagamentos totais e parciais, recorrências | dashboards, BI, IA (D/E) |
| estornos, anulação, reversão, ajuste de parcelas | juros, rotativo, antecipação e renegociação |
| categorias iniciais editáveis | anexos (MB-15: fim do B ou C) |
| auditoria e registro de jobs | alertas e push (E) |

---

## 2. Princípios

1. **O razão (`ledger_entries`) é somente-acréscimo e é a verdade do caixa e da dívida.** Nenhuma linha é alterada ou apagada, nem pela aplicação nem pelas RPCs. Correção = nova linha de compensação. Saldos e indicadores são sempre **derivados**, e nenhum agregado é gravado como fonte.
2. **Três visões, nunca misturadas:**
   - **consumo**: competência;
   - **comprometimento**: vencimentos e parcelas;
   - **caixa**: lançamentos em contas de caixa na data efetiva.
3. **Operação com mais de uma linha = uma RPC transacional**, idempotente por `client_operation_id`.
4. **Centavos `bigint`** com `CHECK`; moeda `BRL`.
5. **Autorização pelo titular** via `private.can_access_owner`. Quem não tem leitura não recebe dados, nem por retorno de RPC, nem por mensagem de erro.

---

## 3. Modelo contábil

### 3.1 Contas e sinal (MB-01, ratificada)

- `financial_accounts.type`: `checking`, `savings`, `cash` (ativos) e `credit_card` (passivo, 1:1 com `credit_cards`).
- **Positivo aumenta o saldo da conta, negativo diminui.** A dívida do cartão aparece como saldo negativo.

### 3.2 Contrapartida nominal (MB-02, ratificada) e regra de soma por tipo

| `transactions.type` | Lançamentos no razão | Σ | Consumo | Caixa |
|---|---|---|---|---|
| `income` | caixa `+v` | `+v` | — (receita) | entrada |
| `expense` | caixa `−v` | `−v` | **+v** na competência | saída |
| `card_purchase` | cartão `−total` | `−total` | **+total uma vez** na competência | — |
| `card_bill_payment` | caixa `−v`, cartão `+v` | 0 | — | saída |
| `transfer_out` / `transfer_in` | origem `−v` / destino `+v` | 0 no par | — | eliminada no consolidado |
| `refund` | cartão `+v` **ou** caixa `+v` | `+v` | **−v** sobre a compra original | entrada (se for em caixa) |
| `reversal` | espelho real, na data do evento | `−Σ origem` | anula a origem | movimento real |
| `installment_adjustment` | cartão `±Δ` | `±Δ` | `±Δ` sobre a compra | — |

Lançamentos de **compensação** (anulação, §8.1) espelham a origem com a mesma data efetiva e marca `kind = 'void'`.

### 3.3 Bitemporalidade do razão

Cada lançamento tem `posted_on` (data efetiva) e `recorded_at` (quando foi gravado). Com isso o banco responde duas perguntas:

- **"Qual é o saldo correto em D?"** Σ por `posted_on ≤ D`, incluindo compensações. Uma anulação some com o efeito desde a origem.
- **"O que o sistema mostrava em D?"** Σ por `posted_on ≤ D` e `recorded_at ≤ D`. É o histórico reconstruível para auditoria.

### 3.4 Saldo inicial (MB-03, ratificada)

`saldo(D) = opening_balance_cents + Σ amount_cents (posted_on > opening_date e ≤ D)`. A abertura não é receita. Lançamentos com data ≤ corte entram no consumo, mas não no saldo.

---

## 4. Tempo: competência, vencimento e liquidação

| Conceito | Campo | Onde vive | Regra |
|---|---|---|---|
| fato | `occurred_at` (UTC) + `local_date` + `timezone` | `transactions` | `local_date` define o ciclo do cartão e a competência padrão |
| **competência** | `competence_month` (dia 1) | `transactions`, `obligations` | padrão = mês de `local_date` (ou o mês de referência da obrigação). Editável e auditado |
| **vencimento** | `due_date` | `obligations`, `billing_cycles.due_on` | não muda a competência |
| **liquidação** | `posted_on` / `paid_at` | `ledger_entries`, `payments` | caixa e saldo usam só esta data |

"Hoje" = data em `America/Sao_Paulo`. Relatórios escolhem **explicitamente** a base: competência ou caixa.

---

## 5. Cartões, ciclos e faturas

### 5.1 Configuração por cartão

| Campo | Valores | Uso |
|---|---|---|
| `closing_day`, `due_day` | 1–31 | dia inexistente no mês → último dia |
| `closing_day_policy` | `current_cycle` \| `next_cycle` | compra **no dia do fechamento** entra no ciclo que fecha nesse dia ou no seguinte. Padrão `current_cycle`, ajustável por cartão |
| `credit_limit_cents` | ≥ 0 | limite cadastrado |
| `rule_revision` | inteiro | incrementa a cada mudança de dia ou política |

### 5.2 Ciclos

- `billing_cycles`: `starts_on`, `closes_on`, `due_on`, `status` (`open` → `closed` → `paid`, derivado da obrigação), `date_source` (`estimated` \| `confirmed`), `confirmed_at/by`, `rule_revision`.
- **Regra estimada:**
  - fechamento do mês M = `closing_day` de M (ajustado ao fim do mês);
  - o ciclo vai do fechamento anterior + 1 dia até o fechamento de M;
  - vencimento = primeiro `due_day` **depois** do fechamento (ajustado ao fim do mês).
- **Fechamento de ciclo:** um job (ou o primeiro acesso após `closes_on`) passa o ciclo a `closed` e cria a obrigação `card_bill`. É idempotente: `UNIQUE(billing_cycle_id)` em `obligations`.

### 5.3 Datas confirmadas pelo banco prevalecem

- A RPC `confirm_billing_cycle(cycle, closes_on, due_on, valor_fatura_informado)` grava as datas reais (`date_source = 'confirmed'`). No B ela é manual; no D, a conciliação a usa.
- Ao confirmar, compras na fronteira entre ciclos **abertos** são reatribuídas pelas datas reais. A operação é recusada se mover parcela para ciclo `closed`/`paid` ou se o ciclo já tiver pagamento.
- O valor de fatura informado pelo banco é **comparado** com o calculado. Diferença é **registrada** como divergência (`cycle_discrepancies`), nunca compensada automaticamente (§7.3: "nunca inventar movimentação compensatória").
- Ciclo confirmado **não** é recalculado por mudança de regra.

### 5.4 Mudança de dia ou política

Recalcula só ciclos `open`, `estimated`, sem pagamento e com `closes_on ≥ hoje`. Ciclos `closed`, `paid` ou `confirmed` são **imutáveis** (gatilho). As parcelas dos ciclos recalculados são reatribuídas na mesma transação, com auditoria e nova `rule_revision`.

### 5.5 Quatro posições do cartão (`v_card_position`, security_invoker)

| Posição | Definição |
|---|---|
| **Dívida total** | `−saldo da conta do cartão` = compras e ajustes − estornos − pagamentos (pelo razão) |
| **Fatura atual** | fatura do ciclo `closed` mais antigo com saldo devedor; se não houver, a prévia do ciclo `open` |
| **Fatura em aberto (prévia)** | Σ parcelas do ciclo `open` − créditos aplicados a ele |
| **Parcelas futuras** | Σ parcelas válidas em ciclos posteriores ao `open` |
| **Limite disponível** | `credit_limit − dívida total`. Pode ficar negativo; aí é exibido como "acima do limite" |

**Conciliação (invariante INV-C3):** `dívida total = Σ restante das obrigações card_bill + prévia do ciclo open + parcelas futuras − créditos não aplicados`. Verificada por teste em todos os cenários-oráculo.

### 5.6 Fatura

- Valor da fatura do ciclo = Σ parcelas válidas do ciclo − Σ créditos aplicados ao ciclo.
- **Créditos (estornos) — MB-08 revisada:** o crédito é aplicado ao ciclo `open` na data do estorno. Se exceder a prévia daquele ciclo, o **excedente fica como crédito não aplicado** e é consumido pelos ciclos seguintes em ordem. Nunca vira saldo de caixa no B.
- Pagamento acima do devido é recusado (MB-06, ratificada). Sem rotativo nem juros: a fatura não paga continua devida e atrasada.

---

## 6. Compras parceladas

- **Distribuição (MB-05):** `q = total ÷ n`, resto nas primeiras parcelas. Σ parcelas = total.
- **Parcela válida** = parcela da revisão vigente da compra com `status ≠ 'superseded'`.
- **Ajuste de parcelas** (`adjust_installments`), operação explícita e auditada:
  - só altera parcelas em ciclos `open` ou futuros, não confirmados e sem pagamento. Parcelas em ciclo `closed`/`paid` são **preservadas**;
  - cria nova revisão: as parcelas abertas antigas viram `superseded` e as novas são geradas;
  - **exige** Σ (parcelas preservadas + novas) = novo total da compra. Diferença de total gera lançamento `installment_adjustment` (±Δ) no cartão, para a dívida acompanhar;
  - recusado se deixasse divergência entre total e parcelas, ou se mexesse em parcela de ciclo fechado ou pago.
- **Estorno em compra parcelada não cancela parcelas.** O crédito é registrado (§5.6). Se o banco de fato cancelou as parcelas futuras, o usuário registra isso como **ajuste de parcelas** com a confirmação do banco, e não como estorno. Cada fato fica registrado uma única vez.

---

## 7. Estornos e reembolsos (§7.6)

- `refunds` liga o estorno à compra ou despesa original. A soma é limitada ao **líquido estornável**: `original − Σ estornos − Σ ajustes negativos`.
- **Estorno no cartão:** crédito (§5.6). **Em conta:** entrada de caixa marcada como **recuperação de gasto**, nunca receita.
- Consumo líquido da compra = original ± ajustes − estornos. A visão `v_purchase_net` mostra bruto, ajustes, estornos e líquido.

---

## 8. Cancelamento, anulação e reversão

### 8.1 Duas operações distintas — MB-09 revisada

| Operação | Quando | Efeito no razão | Data |
|---|---|---|---|
| **Anulação** (`void_transaction`) | o fato **não aconteceu** (erro de lançamento) e não há efeito liquidado nem conciliado | compensação espelho (`kind = 'void'`) + `status = 'voided'` | **mesma data efetiva** da origem: o saldo correto desde a origem; histórico preservado via `recorded_at` |
| **Reversão** (`reverse_transaction`) | o fato aconteceu e houve **movimento real contrário** (dinheiro devolvido, chargeback, pagamento devolvido pelo banco) | nova operação `reversal` ligada à origem | **data em que o movimento real ocorreu** |

- **Reversão contábil × movimentação bancária:** a anulação é contábil (corrige um registro errado) e não representa dinheiro entrando ou saindo. A reversão representa dinheiro entrando ou saindo de fato. Elas aparecem com rótulos diferentes no extrato.
- Nenhuma linha é apagada. O `status` da operação muda (`active` → `voided`/`reversed`) com `cancelled_at/by/reason`.

### 8.2 Elegibilidade e dependentes

| Operação-alvo | Anular | Reverter | Bloqueio por dependentes |
|---|---|---|---|
| `expense`/`income` | se não conciliada | sim | estornos ativos ligados → anular ou reverter os estornos antes |
| `card_purchase` | só se **nenhuma** parcela estiver em ciclo `closed`/`paid` e não houver estorno ativo | não se aplica (usar estorno ou ajuste) | parcelas em ciclo fechado ou pago; estornos ativos |
| `card_bill_payment` / pagamento de conta | se não conciliado (ex.: lançado por engano) | sim (pagamento devolvido) | reabre a obrigação; recusado se o ciclo tiver sido confirmado com esse pagamento |
| `refund` | se o crédito **não** tiver sido consumido por fatura paga | sim | crédito já aplicado a ciclo `paid` |
| transferência | sempre o **par**, nunca uma ponta | sim, o par | — |

Repetir a mesma operação de sync ou importação **não reativa** uma operação anulada (idempotência por `client_operation_id`).

---

## 9. Obrigações, pagamentos e recorrências

### 9.1 Obrigações

- Tipos: `card_bill` (1 por ciclo fechado), `bill` (conta a pagar), `receivable` (previsão de receita).
- Campos: `competence_month`, `due_date`, `original_amount_cents`, `adjustments_cents` (alterados só por RPC auditada), origem (`billing_cycle_id` \| `occurrence_id` \| manual).
- **Estado derivado** (`v_obligations_status`):
  - `remaining = original + ajustes − Σ pagamentos ativos`;
  - `settlement_status ∈ {open, partial, paid}`;
  - `is_overdue = remaining > 0 ∧ due_date < hoje`.

### 9.2 Pagamentos sem dupla contagem

| Obrigação | Cada pagamento gera | Consumo | Caixa |
|---|---|---|---|
| `card_bill` | `card_bill_payment` (caixa −v, cartão +v) | **nenhum**: o consumo já foi contado na compra | −v em `paid_at` |
| `bill` | `expense` de valor v, com `competence_month` **da obrigação** | +v na competência da obrigação | −v em `paid_at` |
| `receivable` | `income` de valor v | — (receita realizada) | +v |

- Pagamentos parciais de uma `bill` somam no máximo o devido. O consumo reconhecido de uma `bill` é a soma do que foi pago, e o saldo restante aparece só no comprometimento.
- Anular ou reverter um pagamento reabre a obrigação, e o consumo e o caixa se corrigem pela compensação.
- **Indicadores:** saldo, consumo, comprometimento e fatura são **views sobre o razão e os vínculos**, nunca valores gravados. Ajustes, estornos, anulações e reversões se refletem automaticamente. Os testes O28–O30 provam isso.

### 9.3 Recorrências (MB-10/11 ratificadas)

- Regras mensais ou anuais; `revision`; estados `active`/`paused`/`cancelled`.
- `recurrence_occurrences` com `UNIQUE(rule_id, period_key)` e obrigação com `UNIQUE(occurrence_id)`. Gerar duas vezes resulta numa só.
- Geração até 60 dias à frente, pelo job da §11.
- "Esta e as futuras" → nova revisão; regenera só ocorrências futuras **sem pagamento**.

---

## 10. Permissões

### 10.1 Escopos (MB-13 ratificada)

- `accounts`: contas, saldos, extrato, transferências;
- `cards`: cartões, ciclos, posições, faturas;
- `transactions`: operações, parcelas, estornos, obrigações, pagamentos, recorrências.

### 10.2 Transferência entre titulares — MB-07 revisada

Exige do chamador **`accounts/create` nas duas pontas**: titular de origem **e** titular de destino. Sendo o próprio titular de uma ponta, a permissão é implícita nela, mas a outra exige grant explícito. Sem as duas, nada é gravado.

### 10.3 Regras para todas as RPCs

1. Verificar `can_access_owner` para **cada** titular envolvido e **cada** recurso referenciado: conta, cartão, categoria, obrigação.
2. **Retorno mínimo:** quem só tem `create` recebe `{id, status}`. Saldos, faturas e posições só são devolvidos a quem tem `read` no escopo correspondente.
3. **Erro sem vazamento:** recurso inexistente e recurso sem permissão devolvem **o mesmo** código (`P0002 not_found_or_forbidden`).
4. `security definer` + `search_path = ''` + objetos qualificados; `EXECUTE` revogado de `public`/`anon` e concedido só a `authenticated` (RPCs de usuário) ou `service_role` (jobs).
5. Views com `security_invoker = true`. Funções auxiliares fora do schema exposto (`private`).
6. **Verificação automática:** um teste pgTAP percorre o catálogo e falha se alguma função `security definer` não fixar `search_path`, se alguma tiver `EXECUTE` para `public`/`anon`, se alguma view expor sem `security_invoker` ou se alguma tabela financeira não tiver RLS.

---

## 11. Concorrência e jobs

### 11.1 Concorrência

| Situação | Mecanismo |
|---|---|
| pagamentos simultâneos na mesma obrigação | `SELECT … FOR UPDATE` na obrigação; Σ verificada após a trava |
| estornos simultâneos na mesma compra | trava na compra; limite de estornável verificado após a trava |
| ajuste de parcelas × pagamento de fatura × fechamento de ciclo | ordem fixa de travas: cartão → ciclos (por data) → compra → obrigação |
| mesma `client_operation_id` em paralelo | `UNIQUE(owner, client_operation_id)`: o segundo recebe o resultado do primeiro ou 409 |

Todos são testados com conexões **reais em paralelo** (integração), como o bootstrap do Marco A.

### 11.2 Jobs (MB-12)

- `close_due_cycles` (fecha ciclos e cria `card_bill`) e `apply_recurring_occurrences`, ambos idempotentes.
- **`job_runs`** registra job, início, fim, `status` (`running`/`succeeded`/`failed`), itens criados, erro **sem dados financeiros** e `request_id`. Uma trava consultiva impede duas execuções simultâneas do mesmo job.
- Falha → `status = failed` + evento de auditoria. O alerta externo entra no gate de produção (§10.1 item 9); no B fica visível ao Admin como estado operacional, **sem valores**.
- Agendador: `pg_cron`, se disponível no plano. Senão, GitHub Actions chamando RPC de serviço. Verificar antes de configurar.

---

## 12. Modelo de dados (lógico, rev. 2)

Tabelas no padrão do Marco A: UUID, `owner_user_id`, RLS por `can_access_owner`, auditoria, escrita só por RPC.

| Tabela | Novidades da rev. 2 |
|---|---|
| `categories` | — |
| `financial_accounts` | — |
| `credit_cards` | `closing_day_policy`, `rule_revision` |
| `billing_cycles` | `date_source`, `confirmed_at/by`, imutável quando `closed`/`paid`/`confirmed` |
| `cycle_discrepancies` | **nova**: ciclo, valor informado, valor calculado, diferença, `resolved_at` |
| `transactions` | `status ∈ {active, voided, reversed}`, `reverses_transaction_id`, `voided_by_entry_group` |
| `ledger_entries` | `kind ∈ {normal, void}`, `posted_on`, `recorded_at`; **somente-acréscimo** |
| `card_purchases` | `revision`, `total_cents` da revisão vigente |
| `installments` | `revision`, `status ∈ {valid, superseded}` |
| `card_credits` | **nova**: crédito, ciclo de origem, aplicações por ciclo (o excedente fica não aplicado) |
| `obligations` | `competence_month`, `adjustments_cents`, `UNIQUE(billing_cycle_id)`, `UNIQUE(occurrence_id)` |
| `payments` | `status ∈ {active, voided, reversed}` |
| `transfers` | — |
| `refunds` | `status` |
| `recurrence_rules` / `recurrence_occurrences` | — |
| `financial_operations` | idempotência (já previsto) |
| `job_runs` | **nova** |

Views (todas `security_invoker`): `v_account_balances`, `v_account_statement`, `v_card_position`, `v_card_cycles`, `v_obligations_status`, `v_purchase_net`.

---

## 13. Matriz de invariantes do banco

Mecanismos:
- **C** = `CHECK`/`UNIQUE`/FK;
- **T** = gatilho;
- **R** = verificação dentro da RPC (após travas);
- **V** = derivado por view (não armazenado);
- **P** = teste pgTAP;
- **I** = teste de integração com concorrência real.

### Razão e saldos

| ID | Invariante | Mecanismo | Teste |
|---|---|---|---|
| INV-L1 | `ledger_entries` nunca sofre UPDATE nem DELETE | T (recusa) + sem privilégio | P |
| INV-L2 | todo lançamento tem `amount_cents ≠ 0` e conta do **mesmo titular** da operação | C + T | P |
| INV-L3 | Σ dos lançamentos de cada operação obedece à regra do tipo (§3.2) | R (ao fim da RPC) + P (varredura) | P |
| INV-L4 | anulação: compensação espelha exatamente a origem com a mesma `posted_on`; Σ(origem + compensação) = 0 | R | P |
| INV-L5 | saldo de qualquer conta = abertura + Σ razão (pós-corte), sem tabela de saldo | V | P (O1, O2) |
| INV-L6 | o saldo "como era visto em D" é reconstruível (`recorded_at ≤ D`) | V | P (O25) |

### Cartão

| ID | Invariante | Mecanismo | Teste |
|---|---|---|---|
| INV-C1 | Σ parcelas válidas da compra = `total_cents` da revisão vigente | R + P | P (O3, O4, O21, O22) |
| INV-C2 | ciclos de um cartão não se sobrepõem nem têm buraco | C (exclusion `daterange`) + R | P |
| INV-C3 | dívida total = Σ restante `card_bill` + prévia do ciclo aberto + parcelas futuras − créditos não aplicados | V + P (em todo oráculo de cartão) | P |
| INV-C4 | ciclo `closed`/`paid`/`confirmed` não muda datas nem parcelas | T | P (O10, O20) |
| INV-C5 | parcela de ciclo `closed`/`paid` nunca é alterada nem `superseded` | T | P (O21) |
| INV-C6 | uma obrigação `card_bill` por ciclo fechado | C (`UNIQUE`) | P |
| INV-C7 | crédito aplicado a ciclos ≤ valor do crédito; aplicação nunca deixa fatura negativa | R + C | P (O23) |
| INV-C8 | o cartão nunca guarda PAN nem CVV (`last_four` = 4 dígitos) | C | P |

### Obrigações e pagamentos

| ID | Invariante | Mecanismo | Teste |
|---|---|---|---|
| INV-O1 | Σ pagamentos ativos ≤ `original + ajustes` | R (após `FOR UPDATE`) | P (O6) + I (O13) |
| INV-O2 | `settlement_status` e `is_overdue` são derivados, nunca gravados | V | P |
| INV-O3 | pagamento de `card_bill` não gera consumo; pagamento de `bill` gera consumo = valor pago, na competência da obrigação | R + V | P (O5, O27) |
| INV-O4 | uma ocorrência por regra e período; uma obrigação por ocorrência | C (`UNIQUE`) | P + I (O11) |

### Estornos, anulação e reversão

| ID | Invariante | Mecanismo | Teste |
|---|---|---|---|
| INV-R1 | Σ estornos ativos ≤ líquido estornável da origem | R (após trava) | P (O17) + I (O24) |
| INV-R2 | estorno nunca é receita; aparece como recuperação de gasto | C (tipo) + V | P (O7) |
| INV-R3 | anulação recusada se houver dependente liquidado, conciliado ou crédito consumido | R | P (O9, O26) |
| INV-R4 | transferência só é anulada ou revertida em par | R | P |
| INV-R5 | `client_operation_id` repetido não cria nem reativa operação | C (`UNIQUE`) + R | P + I (O16) |

### Permissão e superfície

| ID | Invariante | Mecanismo | Teste |
|---|---|---|---|
| INV-P1 | toda tabela financeira tem RLS e nenhum privilégio de escrita para `authenticated` | C (catálogo) | P (varredura do catálogo) |
| INV-P2 | toda função `security definer` fixa `search_path` e não tem `EXECUTE` para `public`/`anon` | catálogo | P (varredura) |
| INV-P3 | toda view é `security_invoker` | catálogo | P (varredura) |
| INV-P4 | transferência entre titulares exige `accounts/create` nas duas pontas | R | P (O19) |
| INV-P5 | quem só tem `create` recebe apenas `{id, status}` | R | P (O15) |
| INV-P6 | "inexistente" e "sem permissão" geram o mesmo erro | R | P (O31) |
| INV-P7 | Admin não lê nem grava nenhuma tabela financeira | RLS (`can_access_owner`) | P |

### Jobs

| ID | Invariante | Mecanismo | Teste |
|---|---|---|---|
| INV-J1 | um job do mesmo tipo não roda em paralelo | trava consultiva | I (O32) |
| INV-J2 | toda execução gera `job_runs` com estado final; falha registrada sem dados financeiros | R | P (O33) |

---

## 14. Casos-oráculo

### Mantidos da rev. 1

| # | Entrada | Esperado |
|---|---|---|
| O1 | abertura R$ 1.000 em 01/10; despesa R$ 70 em 02/10 | saldo R$ 930; abertura fora das receitas |
| O2 | despesa R$ 50 em 25/09 (antes do corte) | saldo R$ 930; consumo de setembro +50 |
| O3 | R$ 1.200 em 6x | 6 × 200; Σ = 1.200; consumo +1.200 uma vez |
| O4 | R$ 100 em 3x | 33,34 + 33,33 + 33,33 |
| O5 | fatura R$ 200 paga | caixa −200; dívida −200; consumo inalterado |
| O6 | obrigação R$ 500, paga R$ 200 | restante 300; `partial`; atrasada após vencimento |
| O7 | compra R$ 300, estorno R$ 100 | líquido 200; estorno ≠ receita |
| O8 | transferência R$ 100 A→B | A −100, B +100; consolidado sem receita ou despesa |
| O9 | anular pagamento conciliado | recusado; exige reversão |
| O10 | mudar vencimento com fatura paga | ciclo pago intacto; só abertos recalculados |
| O11 | job de recorrência 2× | 1 ocorrência e 1 obrigação |
| O12 | fechamento dia 31, fevereiro de 2028 | fecha 29/02/2028 |
| O13 | 2 pagamentos simultâneos de R$ 300 em obrigação de R$ 500 | um aceito, outro recusado (**I**) |
| O14 | `transactions/read` sem `accounts/read` | vê lançamentos, não saldo |
| O15 | só `create` sobre Bia | recebe `{id, status}`; não lê nada |
| O16 | mesma `client_operation_id` 10× | 1 operação |
| O17 | estornos acima da compra | recusado |
| O18 | compra no dia do fechamento, política `current_cycle` | ciclo que fecha nesse dia |

### Novos da rev. 2

| # | Cenário | Esperado |
|---|---|---|
| O18b | compra no dia do fechamento, política `next_cycle` | entra no ciclo seguinte |
| O19 | Luck transfere para conta de Bia **sem** `accounts/create` em Bia | recusado; nada gravado em nenhuma ponta |
| O19b | com `create` nas duas pontas | par gravado; Bia vê "recebida" sem dados de Luck que não possa ler |
| O20 | `confirm_billing_cycle` move fechamento de 05 para 04 com compra em 05 | compra reatribuída ao ciclo seguinte (abertos); fatura recalculada; ciclo confirmado deixa de ser recalculado por regra |
| O20b | confirmação que moveria parcela para ciclo pago | recusada |
| O20c | banco informa fatura R$ 1.010, sistema calcula R$ 1.000 | divergência de R$ 10 registrada; **nenhum** lançamento automático |
| O21 | 6x de R$ 200 com 2 parcelas pagas; ajuste para 3x restantes de R$ 266,67 | 2 pagas intactas; novas somam 800 (266,67 + 266,67 + 266,66); total mantido |
| O21b | ajuste que deixaria Σ ≠ total | recusado |
| O22 | ajuste reduzindo o total em R$ 100 (desconto confirmado pelo banco) | lançamento `installment_adjustment` +100 no cartão; dívida e parcelas conciliadas (INV-C3) |
| O23 | estorno de R$ 500 com prévia do ciclo aberto de R$ 300 | ciclo atual 0; R$ 200 de crédito não aplicado consumidos pelo próximo ciclo; parcelas futuras intactas |
| O24 | 2 estornos simultâneos de R$ 200 em compra de R$ 300 | um aceito, outro recusado (**I**) |
| O25 | despesa lançada em 02/10 e anulada em 10/10 | saldo correto em 05/10 sem a despesa; "como era visto em 05/10" mostra a despesa; razão com 2 linhas |
| O26 | anular estorno cujo crédito já foi consumido por fatura paga | recusado |
| O27 | conta a pagar (competência outubro) de R$ 500 paga 200 em 10/10 + 300 em 05/11 | consumo de outubro = 500 (200 + 300); caixa out −200, nov −300; nenhum duplicado |
| O28 | O27 + anulação do pagamento de 300 | consumo de outubro = 200; obrigação `partial`; caixa de novembro corrigido |
| O29 | compra R$ 300, estorno R$ 100, reversão do estorno (banco desfez) | líquido volta a 300; dívida e fatura corrigidas |
| O30 | pagamento de fatura revertido pelo banco | obrigação reabre; caixa +v na data da reversão; consumo inalterado |
| O31 | RPC com id de conta inexistente × conta de outro titular sem permissão | mesmo erro `not_found_or_forbidden` |
| O32 | dois `close_due_cycles` simultâneos | um executa, outro sai sem efeito; `job_runs` registra ambos (**I**) |
| O33 | job falha no meio (erro forçado) | nenhuma obrigação parcial; `job_runs.status = failed` com erro sanitizado |
| O34 | ajuste de parcelas concorrente com pagamento da fatura do mesmo ciclo | ordem de travas garante um resultado consistente; INV-C1 e INV-C3 válidos (**I**) |
| O35 | Admin chama qualquer RPC financeira | negado; nenhum dado retornado |

---

## 15. Decisões — situação

| Código | Situação |
|---|---|
| MB-01, 02, 03, 05, 06, 10, 11, 12, 13, 14, 15 | **ratificadas** |
| MB-04 | **revisada**: política por cartão (`closing_day_policy`), padrão `current_cycle` |
| MB-07 | **revisada**: `accounts/create` nas duas pontas |
| MB-08 | **revisada**: crédito no ciclo aberto, excedente não aplicado consumido pelos ciclos seguintes; não cancela parcelas |
| MB-09 | **revisada**: anulação (compensação na data da origem) × reversão (movimento real na data do evento) |
| **MB-16** (nova) | razão somente-acréscimo e bitemporal (`posted_on` + `recorded_at`) |
| **MB-17** (nova) | consumo de conta a pagar reconhecido por pagamento, na competência da obrigação |
| **MB-18** (nova) | divergência entre fatura informada e calculada é registrada, nunca compensada automaticamente |

## 16. Próximos passos (após validação desta revisão)

1. DDL nas migrations, com RLS, gatilhos, views `security_invoker` e RPCs.
2. Testes O1–O35 (pgTAP e integração concorrente) e varreduras de catálogo (INV-P1 a P3), escritos **antes** das telas e validados por mutação.
3. Telas e E2E de contas, cartões, lançamentos, faturas e pagamentos.
4. Evidência por FIN-02 a FIN-05. Tudo com dados **fictícios**.
