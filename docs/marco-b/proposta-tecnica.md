# Marco B — Proposta técnica para revisão (antes do código)

- **Estado:** proposta para validação. **Nada disto está implementado.**
- **Data:** 15/10/2026 · **Base:** Especificação v1.1 (§6, §7.1–7.8, §8 FIN-02 a FIN-05, §11, §13)
- **Pré-condição:** Marco A testado localmente, no CI e no hospedado de desenvolvimento.
  Pendente: SMTP próprio, por decisão do responsável de deixar para depois.
- **Como revisar:** cada decisão tem um código (**MB-xx**). Responda
  aceitar, ajustar ou rejeitar. Depois da validação vêm o DDL completo
  (migrations), os testes-oráculo em pgTAP e só então as telas.

---

## 1. Escopo do Marco B

| Entra | Não entra (marco posterior) |
|---|---|
| FIN-02 contas, saldo inicial e saldo | metas e orçamentos (Marco D) |
| FIN-03 cartões, ciclos, faturas e parcelas | importação de extratos (D) |
| FIN-04 receitas, despesas, transferências e compras parceladas (online) | offline/PWA (C) |
| FIN-05 obrigações, pagamentos totais e parciais, recorrências | dashboards e BI (D) |
| estornos/reembolsos, cancelamento e reversão (§7.6–7.7) | juros, antecipação e renegociação de parcelas |
| categorias iniciais editáveis (pré-requisito de FIN-04) | anexos (exige Storage; proposta: final do B ou C) |
| auditoria de todas as operações financeiras | geolocalização (campos previstos, coleta no C) |

---

## 2. Princípios

1. **O razão (`ledger_entries`) é a verdade do caixa e da dívida.** O saldo de
   qualquer conta é calculado a partir dele. Não existe tabela de saldo
   editável. Se no futuro houver cache de saldo, ele precisa ser reconstruível
   e testado contra o razão.
2. **Três visões, nunca misturadas** (§7.2):
   - **consumo**: o que foi comprado e quando (competência);
   - **comprometimento**: o que vence e quando (obrigações, parcelas);
   - **caixa**: o que saiu ou entrou de fato (lançamentos no razão de contas de caixa).
3. **Toda operação com mais de uma linha** (compra parcelada, pagamento,
   transferência, estorno, reversão) é **uma RPC transacional**. O navegador
   nunca grava razão e cabeçalho em chamadas separadas.
4. **Dinheiro em centavos `bigint`** com `CHECK`. Moeda `BRL` (ISO 4217) por conta.
5. **Autorização pelo titular** (`owner_user_id`) via `private.can_access_owner`,
   no padrão do Marco A, com escopos `accounts`, `cards` e `transactions`.

---

## 3. Modelo contábil

### 3.1 Contas

`financial_accounts.type`:

| Tipo | Natureza | Saldo positivo significa |
|---|---|---|
| `checking`, `savings`, `cash` (carteira/dinheiro) | ativo | dinheiro disponível |
| `credit_card` | passivo | **crédito a favor** (raro); dívida aparece como saldo **negativo** |

Cada cartão (`credit_cards`) tem **uma** conta do tipo `credit_card`, que
registra a dívida dele.

### 3.2 Convenção de sinais — **MB-01**

Uma única regra para todas as contas: **`amount_cents` positivo aumenta o
saldo da conta; negativo diminui**. Em conta de cartão, compra é negativa (a
dívida cresce) e pagamento de fatura é positivo (a dívida cai). O saldo de
qualquer conta é `abertura + Σ amount_cents`.

### 3.3 Contrapartida — **MB-02**

O razão registra só **contas reais** (caixa e dívida). A contrapartida de
receitas e despesas é **nominal**: é a **categoria**, gravada no cabeçalho da
operação (`transactions.category_id`). Proposta: não modelar partidas dobradas
completas com contas de resultado. É mais simples para uso pessoal e atende §7.
Em compensação, cada tipo de operação tem uma **regra de soma** verificada no banco:

| Operação (`transactions.type`) | Lançamentos no razão | Σ do razão | Conta como consumo? | Conta como caixa? |
|---|---|---|---|---|
| `income` | conta de caixa `+v` | `+v` | não (é receita) | entrada |
| `expense` (débito/Pix/dinheiro) | conta de caixa `−v` | `−v` | **sim** | saída |
| `card_purchase` | conta do cartão `−total` | `−total` | **sim, uma vez, pelo total** | não |
| `card_bill_payment` | caixa `−v`, cartão `+v` | **0** | **não** | saída |
| `transfer_out` / `transfer_in` | origem `−v` / destino `+v` (uma por titular) | 0 no par | não | eliminada no consolidado |
| `refund` (estorno) | cartão `+v` ou caixa `+v` | `+v` | **reduz** o consumo da compra original | entrada (se for em caixa) |
| `reversal` (reversão contábil) | espelho exato da original | `−Σ original` | anula a original | anula a original |
| `opening` | — (fica em `financial_accounts`) | — | não | não |

Os exemplos da §7.2 conferem com a tabela:
- compra de R$ 1.200 em 6x = 1 consumo de R$ 1.200;
- pagamento de fatura de R$ 200 = caixa −200 e dívida −200, sem consumo.

### 3.4 Saldo inicial — **MB-03**

Saldo na data D = `opening_balance_cents + Σ lançamentos com data > opening_date e ≤ D`.

- Segue literalmente a §7.3 ("posteriores à data de corte"). Um lançamento **no
  próprio dia** da abertura **não** altera o saldo: entende-se que a abertura é
  o saldo **ao fim** daquele dia. **Confirmar.**
- Lançamentos com data ≤ `opening_date` (histórico importado) entram nas visões
  de consumo, mas **não** no saldo.
- Aceite FIN-02: abertura de R$ 1.000 em 01/10 + despesa de R$ 70 em 02/10 = **R$ 930**.

---

## 4. Tempo (§7.1)

| Campo | Tipo | Uso |
|---|---|---|
| `occurred_at` | `timestamptz` (UTC) | instante do fato, quando houver hora |
| `local_date` | `date` | data do fato no fuso de origem: é ela que define ciclo e competência |
| `timezone` | `text` (IANA) | padrão `America/Sao_Paulo` |
| `competence_month` | `date` (dia 1) | mês de consumo. Padrão: mês de `local_date`; editável |
| `due_date` | `date` | vencimento (obrigações e ciclos) |
| `paid_at` / `posted_on` | `timestamptz` / `date` | liquidação real (caixa) |

"Hoje", para atraso e geração de recorrências, é calculado em `America/Sao_Paulo`.

---

## 5. Cartões, ciclos e faturas (§7.2, FIN-03)

### 5.1 Regra de ciclo — **MB-04**

- **Fechamento** do mês M = dia `closing_day` de M. Se o dia não existir (29, 30, 31), usa-se o último dia do mês.
- **Ciclo** = (fechamento anterior + 1 dia) até o fechamento de M, **inclusive**.
- **Vencimento** = primeiro dia `due_day` **depois** do fechamento (mesmo mês, se
  `due_day` > `closing_day`; senão, mês seguinte), também ajustado ao último dia do mês.
- **Compra** entra no ciclo que contém sua `local_date`. Compra **no dia do
  fechamento** entra no ciclo que fecha nesse dia. **Confirmar com a prática
  dos seus cartões**: alguns bancos consideram o dia do fechamento como do ciclo seguinte.
- Ciclos são **materializados** (`billing_cycles`) sob demanda, até o ciclo da última parcela.
- A data é **estimativa**. A data real do banco prevalece quando a importação
  (Marco D) conciliar, e a interface mostra "ciclo estimado" (§7.2).

### 5.2 Mudança de fechamento ou vencimento

Recalcula só ciclos **abertos e futuros**, ou seja, sem fatura fechada nem
pagamento. Ciclos fechados ou pagos mantêm as datas históricas. Parcelas de
ciclos recalculados são reatribuídas pela mesma regra, com auditoria.

### 5.3 Parcelas — **MB-05**

- Distribuição: `q = total ÷ n` (inteiro), `r = total mod n`; as **r primeiras** parcelas recebem `q + 1`.
  Exemplo: R$ 100,00 em 3x = 33,34 + 33,33 + 33,33.
- A parcela k vai para o ciclo da compra + (k − 1).
- Na conta do cartão, a compra lança o **total** na data da compra. A dívida e o
  limite usado sobem pelo total, como nos bancos. As **parcelas** alimentam a
  visão de comprometimento e o valor de cada fatura.
- Alterar quantidade ou valor: só parcelas de ciclos abertos, com nova revisão e
  auditoria. Nunca uma parcela de ciclo pago.

### 5.4 Fatura

- Valor da fatura do ciclo = Σ parcelas do ciclo − Σ créditos (estornos) atribuídos ao ciclo.
- Cada ciclo fechado gera **uma obrigação** (`obligations.type = 'card_bill'`) com esse valor.
- Pagar a fatura = `settle_obligation`, que gera `card_bill_payment` (caixa −v, cartão +v).
- **MB-06:** pagamento **acima** do devido é recusado no Marco B. Crédito
  rotativo e juros ficam fora: a fatura não paga continua devida e aparece
  como atrasada.

---

## 6. Obrigações e pagamentos (§7.4, FIN-05)

- `obligations`: titular, tipo (`card_bill`, `bill` para conta a pagar, `receivable` para previsão de receita), descrição, `due_date`, `original_amount_cents`, ajustes autorizados e origem (ciclo ou recorrência).
- `payments`: obrigação, conta de caixa, valor (> 0), `paid_at`. Cada pagamento cria **uma** operação no razão, na mesma transação.
- **Estado derivado**, nunca gravado à mão:
  - `remaining = original + ajustes − Σ pagamentos válidos`
  - `settlement_status`: `open` (sem pagamento), `partial` (pago > 0 e restante > 0), `paid` (restante = 0)
  - `is_overdue = remaining > 0 AND due_date < hoje(America/Sao_Paulo)`. É independente do anterior, então "parcial e atrasada" fica representável (§7.4).
- Pagamento de **conta a pagar** (`bill`) gera `expense`, com competência herdada da obrigação e caixa na data do pagamento.
- Recebimento de **previsão** (`receivable`) gera `income`. Antes disso a previsão **não** é receita (§7.8).
- **Concorrência:** pagamentos simultâneos na mesma obrigação travam a linha (`for update`), e a soma nunca ultrapassa o devido.
- Aceite FIN-05: devido R$ 500, pago R$ 200 → restante R$ 300, `partial`; após o vencimento, `is_overdue = true`.

---

## 7. Transferências (§7.5) — **MB-07**

- Um cabeçalho `transfers` gera **duas operações**, uma de cada titular (`transfer_out` e `transfer_in`), na mesma transação. Tudo ou nada.
- Entre contas do mesmo titular: exige `create` no escopo `accounts` desse titular (o próprio, sempre).
- **Entre titulares diferentes:** quem inicia precisa de `create` no titular de
  **destino**, porque está lançando entrada na conta dele. **Confirmar.**
- No consolidado que inclui as duas contas, o par se anula. Quem enxerga só uma
  ponta vê "transferência enviada/recebida" **sem** nome, conta ou saldo do outro lado.

---

## 8. Estornos, cancelamento e reversão (§7.6, §7.7)

### 8.1 Estorno — **MB-08**

- Sempre ligado à compra ou despesa original (`refunds`). A soma dos estornos é ≤ o valor original, garantido com trava e `CHECK`.
- **Estorno em cartão:** crédito na conta do cartão, atribuído ao **ciclo aberto
  na data do estorno**, não ao ciclo da compra. Reduz a fatura desse ciclo.
- **Estorno em conta:** entrada de caixa classificada como **recuperação de gasto**, não receita.
- Consumo líquido da compra = original − Σ estornos. Os relatórios mostram bruto, estornos e líquido.
- Oráculo: compra de R$ 300 com estorno de R$ 100 → consumo líquido R$ 200.

### 8.2 Cancelamento × reversão — **MB-09**

| Situação da operação | Ação permitida | Efeito |
|---|---|---|
| sem efeito liquidado (ex.: despesa lançada por engano, compra cuja fatura ainda não fechou) | **cancelar** (`cancelled_at`, `cancelled_by`, `cancel_reason`) | sai das visões ativas; os lançamentos no razão passam a ser ignorados; auditoria preservada |
| liquidada (pagamento feito, fatura paga) ou conciliada | **cancelar é recusado** → **reverter** (`reverse-transaction`) | nova operação espelho, ligada à original; o caixa já movimentado fica registrado e é anulado contabilmente |
| compra parcelada com parcelas em ciclo pago | cancelar recusado; estorno ou reversão das parcelas **abertas** | — |

Sem exclusão física pela aplicação. Importação ou sync repetidos não reativam operação cancelada (chave de idempotência).

---

## 9. Recorrências (§7.8)

- `recurrence_rules`: modelo (tipo, valor, categoria, conta), frequência (**MB-10**: no B só `monthly`, com dia do mês ajustado ao último dia, e `yearly`; RRULE completa fica para depois), início, fim, estado e `revision`.
- `recurrence_occurrences` com `UNIQUE(rule_id, period_key)` (ex.: `2026-11`). Cada ocorrência gera uma **obrigação** (`bill` ou `receivable`), não um lançamento realizado.
- **Geração:** um job no servidor (`apply_recurring_occurrences`) cria as ocorrências até **60 dias à frente** (**MB-11**). É idempotente: rodar duas vezes cria uma única ocorrência por período.
- **Editar** "só esta" altera a obrigação da ocorrência. "Esta e as futuras" cria nova `revision` e regenera só as ocorrências futuras não liquidadas.
- **Pausar** interrompe novas gerações. **Cancelar** encerra e preserva o histórico.
- **Agendador — MB-12:** usar `pg_cron` no Supabase, que roda no banco e é transacional. Verificar a disponibilidade no plano Free antes de configurar. Alternativa: GitHub Actions agendado chamando uma RPC de serviço.

---

## 10. Modelo de dados (lógico revisado)

As tabelas seguem o padrão do Marco A: UUID, `created_at`/`updated_at`,
`owner_user_id`, RLS com `can_access_owner`, gatilho de auditoria e escrita
**só por RPC**, ou seja, sem INSERT/UPDATE direto para `authenticated`.

| Tabela | Colunas principais (além do padrão) | Constraints-chave |
|---|---|---|
| `categories` | `owner_user_id` (null = padrão do sistema), `parent_id`, `name`, `kind` (`expense`/`income`), `status` | nome único por titular, tipo e pai; padrão do sistema só leitura |
| `financial_accounts` | `type`, `name`, `currency`, `opening_date`, `opening_balance_cents`, `active` | `currency = 'BRL'` no B; conta `credit_card` sem saldo inicial positivo |
| `credit_cards` | `account_id` (1:1), `brand`, `last_four` (`^\d{4}$`), `credit_limit_cents` ≥ 0, `closing_day`/`due_day` (1–31), `active` | nunca PAN completo nem CVV |
| `billing_cycles` | `card_id`, `starts_on`, `closes_on`, `due_on`, `status` (`open`/`closed`/`paid`), `rule_revision` | `UNIQUE(card_id, closes_on)`; sem sobreposição (exclusion constraint em `daterange`) |
| `transactions` | `type`, `description`, `category_id`, `occurred_at`, `local_date`, `timezone`, `competence_month`, `status` (`active`/`cancelled`), `cancelled_*`, `source` (`manual`/`recurrence`/`import`), `reverses_transaction_id`, `client_operation_id` | `UNIQUE(owner_user_id, client_operation_id)`; categoria obrigatória em `income`/`expense`/`card_purchase` |
| `ledger_entries` | `transaction_id`, `account_id`, `amount_cents` (≠ 0), `posted_on` | conta do **mesmo titular** da operação (gatilho); regra de soma por tipo (§3.3, checada ao fim da RPC) |
| `card_purchases` | `transaction_id` (1:1), `card_id`, `total_cents` > 0, `installment_count` 1–48, `revision` | — |
| `installments` | `purchase_id`, `sequence`, `amount_cents` > 0, `billing_cycle_id`, `status` | `UNIQUE(purchase_id, sequence)`; Σ = total (verificado na RPC e por teste) |
| `obligations` | `type`, `description`, `due_date`, `original_amount_cents` > 0, `adjustments_cents`, `billing_cycle_id`/`occurrence_id` | uma obrigação por ciclo |
| `payments` | `obligation_id`, `account_id` (caixa), `amount_cents` > 0, `paid_at`, `transaction_id` | Σ pagamentos ≤ devido (trava + verificação) |
| `transfers` | `from_account_id`, `to_account_id`, `amount_cents` > 0, `executed_on`, `out_transaction_id`, `in_transaction_id`, `status` | contas diferentes |
| `refunds` | `original_transaction_id`, `refund_transaction_id`, `amount_cents` > 0, `refunded_on` | Σ ≤ original |
| `recurrence_rules` / `recurrence_occurrences` | conforme §9 | `UNIQUE(rule_id, period_key)` |
| `financial_operations` | `owner_user_id`, `client_operation_id`, `kind`, `payload_hash`, `status`, `result` | `UNIQUE(owner_user_id, client_operation_id)`; mesma chave com outro payload = 409. Base também do sync offline (C) |

**Visões (todas `security_invoker`, respeitam a RLS):** `v_account_balances`,
`v_account_statement`, `v_card_cycles` (fatura por ciclo), `v_obligations_status`
(estado derivado), `v_purchase_net` (bruto, estornos e líquido).

**Escopo de permissão por tabela — MB-13:**
- `accounts`: contas, saldos, transferências;
- `cards`: cartões, ciclos, faturas;
- `transactions`: operações, parcelas, estornos, obrigações, pagamentos, recorrências.

Um usuário com `transactions/read` e sem `accounts/read` vê os lançamentos do
titular, mas **não** o saldo das contas dele. **Confirmar se é a granularidade desejada.**

---

## 11. Operações (RPCs) do Marco B

Todas: `security definer` com `search_path` vazio, validação de entrada,
verificação de `can_access_owner` para o **titular-alvo**, idempotência por
`client_operation_id`, auditoria e erros estáveis. Seguem os nomes da §11.

| RPC | Faz (numa transação) | Permissão exigida |
|---|---|---|
| `create_account`, `update_account`, `archive_account` | conta com saldo inicial | `accounts` create/update/cancel |
| `create_card`, `update_card_rules` | cartão + conta passiva; recálculo de ciclos futuros (§5.2) | `cards` create/update |
| `create_transaction` | receita ou despesa + lançamento no razão | `transactions/create` no titular; conta do titular |
| `create_card_purchase` | compra + parcelas + ciclos + lançamento no cartão | `transactions/create` + `cards/read` |
| `settle_obligation` | pagamento parcial ou total + operação + lançamento | `transactions/create` |
| `transfer_funds` | cabeçalho + 2 operações + 2 lançamentos | `accounts/create` na origem e no destino |
| `refund_transaction` | estorno ligado + crédito no cartão ou caixa | `transactions/create` |
| `cancel_transaction` | cancelamento lógico, se elegível (§8.2) | `transactions/cancel` |
| `reverse_transaction` | operação espelho ligada | `transactions/cancel` |
| `apply_recurring_occurrences` | job: gera ocorrências e obrigações faltantes | serviço (sem usuário) |

**CREATE sem READ (B2):** quem só tem `create` recebe **apenas** o id opaco e o
estado da operação, nunca saldos, faturas ou outros lançamentos do titular.

---

## 12. Casos-oráculo (viram testes pgTAP antes das telas)

| # | Entrada | Esperado | Origem |
|---|---|---|---|
| O1 | abertura R$ 1.000 em 01/10; despesa R$ 70 em 02/10 | saldo R$ 930; abertura fora das receitas | §13, FIN-02 |
| O2 | despesa de R$ 50 em 25/09 (antes do corte de 01/10) | saldo continua R$ 930; consumo de setembro +50 | §7.3 |
| O3 | R$ 1.200 em 6x | 6 × R$ 200; Σ = 1.200; uma compra; consumo +1.200 uma vez | §7.2 |
| O4 | R$ 100 em 3x | 33,34 + 33,33 + 33,33 | §13 |
| O5 | fatura de R$ 200 paga | caixa −200; dívida −200; consumo inalterado | §13 |
| O6 | obrigação de R$ 500, paga R$ 200 | restante 300; `partial`; atrasada após o vencimento | FIN-05 |
| O7 | compra de R$ 300, estorno de R$ 100 | líquido 200; estorno não é receita | §7.6 |
| O8 | transferência de R$ 100 de A para B | A −100, B +100; consolidado sem receita nem despesa | §13 |
| O9 | cancelar pagamento já liquidado | recusado; reversão exigida e auditada | §13 |
| O10 | mudar vencimento com fatura paga | ciclo pago intacto; só ciclos abertos recalculados | §13 |
| O11 | job de recorrência 2× no mesmo dia | uma ocorrência por regra e período | §13 |
| O12 | fechamento dia 31 em fevereiro de 2028 (bissexto) | fecha em 29/02/2028 | §13 |
| O13 | 2 pagamentos simultâneos de R$ 300 numa obrigação de R$ 500 | um aceito, outro recusado | §13 |
| O14 | Luck com `transactions/read` e sem `accounts/read` sobre Bia | vê lançamentos de Bia, não o saldo | MB-13 |
| O15 | Luck com só `transactions/create` sobre Bia lança despesa | recebe só o id; não lê nada de Bia | B2 |
| O16 | mesma `client_operation_id` repetida 10× | um lançamento | §13 |
| O17 | estornos somando mais que a compra | recusado | §7.6 |
| O18 | compra no dia do fechamento | entra no ciclo que fecha nesse dia (MB-04) | §7.2 |

---

## 13. Decisões para validar

| Código | Proposta |
|---|---|
| **MB-01** | Sinal único: positivo aumenta o saldo da conta; dívida do cartão é saldo negativo |
| **MB-02** | Razão só com contas reais; contrapartida nominal = categoria; regra de soma por tipo |
| **MB-03** | Abertura = saldo ao **fim** de `opening_date`; só lançamentos **posteriores** alteram o saldo |
| **MB-04** | Compra no dia do fechamento entra no ciclo que fecha nesse dia; vencimento = primeiro `due_day` após o fechamento |
| **MB-05** | Resto dos centavos nas primeiras parcelas; compra lança o total na conta do cartão na data da compra |
| **MB-06** | Pagamento acima do devido recusado; rotativo e juros fora do B |
| **MB-07** | Transferência para outro titular exige `create` no titular de destino |
| **MB-08** | Estorno em cartão vai para o ciclo aberto na data do estorno |
| **MB-09** | Cancelar só sem efeito liquidado; senão, reversão explícita |
| **MB-10** | Recorrência no B: mensal e anual (sem RRULE completa) |
| **MB-11** | Gerar ocorrências até 60 dias à frente |
| **MB-12** | Agendador: `pg_cron` (verificar no Free) ou GitHub Actions como alternativa |
| **MB-13** | Escopos: `accounts` (contas/saldos/transferências), `cards` (cartões/ciclos/faturas), `transactions` (o resto) |
| **MB-14** | Categorias padrão do sistema (só leitura) + categorias próprias por titular; a lista inicial vem do Adam ou do responsável |
| **MB-15** | Anexos de lançamento ficam para o fim do B ou para o C (Storage privado, política própria de retenção) |

## 14. Próximos passos depois da validação

1. DDL completo nas migrations `20261016…`, com RLS, gatilhos e RPCs.
2. Testes pgTAP O1–O18, escritos **antes** das telas e validados por mutação.
3. Telas desktop e mobile de contas, cartões, lançamentos, faturas e pagamentos, com E2E.
4. Evidência por FIN (02–05) e homologação com dados **fictícios**. Dados reais só após o gate §10.
