# Evidência — Fase 2, parte 1: implantação na data de corte

**Data:** 16/10/2026 · **Branch:** `fase2/implantacao-corte`
**Contexto:** o responsável e a Bia passam a usar com dados reais a partir de 01/11/2026 (decisão do responsável, 16/10). SMTP próprio e itens jurídicos (G3/C-4) ficam para a abertura a mais pessoas.

## O que entrou

- **Contas:** o saldo inicial com data de corte já existia ("Saldo inicial" + "Data de abertura"). O que acontece antes do corte não altera o saldo.
- **Cartões:** novo tipo de lançamento `card_opening_balance` ("Saldo anterior do cartão") e a RPC `create_card_opening_balance(cartão, descrição, valor da parcela, parcelas, mês do primeiro vencimento)`. Três usos:
  - **fatura fechada a pagar:** 1 parcela na fatura daquele vencimento. Se a fatura já fechou, ela é fechada na hora e fica disponível para pagamento;
  - **fatura aberta até hoje:** 1 parcela na fatura aberta;
  - **parcelas de compra antiga:** N parcelas, uma por fatura, a partir do vencimento informado.
- **Regras:**
  - entra na **dívida** e nas **faturas** (EQ-1 conciliado) e aparece em Parcelas e nos compromissos futuros;
  - **não** é consumo (competência, categorias, autoria) e **não** mexe no caixa;
  - pagar a fatura reduz caixa e dívida;
  - anular desfaz as parcelas;
  - não registra em fatura que já está fechada no app.
- **Web:** botão "Saldo anterior" na tela do cartão, com as três opções. O tipo aparece em Lançamentos como "Saldo anterior do cartão" e entra no filtro "Cartão".

## Testes

| Suíte | Resultado |
|---|---|
| pgTAP | **437/437**; nova suíte `13_fase2_opening` (20 asserções): dívida, EQ-1, fatura fechada disponível para pagamento, faturas de destino, consumo zero, caixa intacto, Parcelas, pagamento, anulação, validações, isolamento |
| E2E | novo `opening-flow`: fatura aberta + 3 parcelas antigas → dívida R$ 900, consumo R$ 0, Parcelas mostra R$ 600 |

**Bateria local:** pgTAP 437/437, integração 58/58, E2E 58/58 (4 projetos), unitários 33/33, build e `db lint` ok (sem avisos), restauração **PASS** (437 pgTAP).
