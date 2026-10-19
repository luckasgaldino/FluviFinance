# Evidência — Excluir (arquivar) e reativar cartão

**Data:** 19/10/2026 · **Branch:** `ajustes/excluir-cartao` · **Origem:** pedido do responsável ("preciso ter a opção de excluir cartão")

## O que entrou

- **Migration `20261017001300_card_archive.sql`:** `set_card_active(cartão, ativo)`.
  - Excluir = **arquivar**: o cartão e a conta interna dele ficam inativos e saem das listas, do lançamento rápido, da compra no cartão e da Visão geral.
  - **O histórico das compras e faturas é preservado**; nada financeiro é apagado.
  - **Só é permitido sem dívida.** Com fatura a pagar ou parcela a faturar, a resposta é "cartão com dívida em aberto: pague as faturas ou anule os lançamentos antes de excluir". Assim nenhuma dívida some das contas.
  - Cartão excluído não recebe compras. Reativar devolve o cartão às listas.
  - Exige desbloqueio; outra família e cartão inexistente recebem o mesmo erro.
- **Web:**
  - "Excluir cartão" na tela do cartão, com confirmação;
  - a lista de Cartões mostra só os ativos e uma seção "Cartões excluídos" com "Reativar";
  - a compra no cartão não oferece cartões excluídos.
- **Correção encontrada pelo E2E:** as opções do **lançamento rápido** ficavam em cache por 60 s. Um cartão ou conta criado ou excluído demorava até um minuto para aparecer ou sumir do formulário. Agora as opções são buscadas sempre que o formulário abre.

## Testes

| Suíte | Resultado |
|---|---|
| pgTAP | nova `16_card_archive` (14): desbloqueio, recusa com dívida, exclusão após anular a compra, cartão e conta inativos, some do lançamento rápido e da Visão geral, histórico preservado, sem compras novas, reativação, outra família, inexistente |
| E2E | novo `archive-card`: recusa com dívida (mensagem), exclusão sem dívida, seção "Cartões excluídos", some do "Pagar com", reativação |

### Bateria local completa

pgTAP 498/498 (16 suítes) · integração 58/58 · E2E 61/61 (4 projetos) · unitários 57/57 · build ok · `db lint` sem achados · `backup:drill` PASS (498 no banco restaurado).
