# Evidência — Atualizar saldo da conta e saldo inicial no início do dia

**Data:** 19/10/2026 · **Branch:** `ajustes/atualizar-saldo` · **Origem:** pedido do responsável ("não consigo atualizar o saldo da conta que cadastrei")

## O que entrou

- **Saldo inicial no início do dia de abertura** (`account_balance`): os lançamentos do **próprio dia de abertura passam a contar**.
  - Antes, o dia de abertura era tratado como já incluído no saldo inicial e esses lançamentos eram ignorados. Abrir as contas em 01/11 e lançar no mesmo dia não mudaria o saldo.
  - O que é anterior à abertura continua fora do saldo.
  - Todos os 464 testes pgTAP anteriores continuaram passando com a regra nova.
- **"Atualizar saldo"** (`adjust_account_balance`, FF-03): o usuário informa o saldo real e a data, e a diferença para o saldo calculado vira um lançamento identificado.
  - Os tipos são `adjustment_in`/`adjustment_out` ("Ajuste de saldo"): não são receita nem despesa, ficam no histórico e podem ser anulados.
  - Mesmo saldo não gera lançamento; a operação é idempotente.
  - Exige desbloqueio; datas antes da abertura e futuras são recusadas; contas de cartão e outra família também são recusadas.
- **Web:** botão **"Atualizar saldo"** em cada conta da lista e na tela da conta. O formulário mostra o saldo atual e aceita valor negativo. O texto do saldo inicial explica a regra nova.
- **Correção encontrada pelo E2E:** o **lançamento rápido** não atualizava as telas financeiras, e a lista de contas mostrava o saldo antigo do cache por até 15 s. Agora o cache financeiro é renovado ao salvar.

## Testes

| Suíte | Resultado |
|---|---|
| pgTAP | nova `15_account_adjustment` (20): despesa do dia de abertura conta, anterior não; ajuste para mais e para menos; saldo em datas anteriores preservado; sem mudança não lança; idempotência; não é receita nem consumo; anulação; validações; desbloqueio; outra família |
| E2E | novo `adjust-flow`: conta aberta hoje, despesa do dia reduz o saldo, ajuste +R$ 350 e para −R$ 50, ajustes listados em Lançamentos, receitas do mês continuam R$ 0 |

**Bateria local:** pgTAP **484/484** (15 arquivos), integração 58/58, E2E **60/60**, unitários 57/57, build e `db lint` sem avisos, restauração **PASS** (484 pgTAP).
