# Evidência — Marco B: telas de Cartões e Compras/Parcelamentos (FIN-03)

- **Data/hora:** 2026-10-15T18:07-03:00 · **Ambiente:** local; dados fictícios
- **Branch:** `marco-b/telas-cartoes` · **Banco:** sem migration nova (usa RPCs e views já publicadas)

## Entregue

| Tela | Conteúdo |
|---|---|
| **Cartões** | lista com dívida e limite disponível; novo cartão (dias de fechamento e vencimento, política do dia do fechamento, limite, bandeira, 4 últimos dígitos validados; nunca o número completo) |
| **Cartão** (detalhe) | posições (§5.5): dívida total, faturas fechadas em aberto, prévia da fatura atual, parcelas futuras, crédito não aplicado, limite, limite disponível (com aviso "acima do limite"); faturas com estado (Aberta estimada/confirmada, Fechada, Paga); compras do cartão; edição de regras com relatório de revisão (§20.9) |
| **Nova compra** | cartão, valor, parcelas (1–48) com **prévia exata** das parcelas (mesma distribuição do banco), descrição, categoria, data (define a fatura estimada), competência, observação |
| **Compra** (detalhe) | bruto, estornos, líquido, situação; parcelas por fatura (faturada/confirmada/substituída); **Estornar** (crédito sem cancelar parcelas), **Ajustar parcelas** (mostra o que é preservado, §20.4), **Anular** (só não faturada) |

## Resultados efetivamente executados

| Comando | Resultado |
|---|---|
| `pnpm test:unit` | 33/33 |
| `pnpm web:build` | ok |
| `pnpm test:db` | 312/312 |
| `pnpm test:integration` | 52/52 |
| `pnpm test:e2e` | **29/29**; novos `cards-flow` (6: dígitos inválidos recusados e cartão criado; compra 6x com prévia, posições e 6 faturas; prévia 100,00 em 3x = 1 × 33,34 + 2 × 33,33; estorno sem cancelar parcelas; ajuste 1.100 em 4x = 275 com 6 substituídas; anulação devolvendo a dívida; isolamento) e telas de cartão a 360 px com axe |

## Não incluído (próximas telas)

Faturas como tela própria (confirmação de datas e valor pelo banco; pagamento de fatura), contas a pagar, transferências, recorrências.
