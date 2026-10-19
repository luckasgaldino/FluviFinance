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

## Deploy no fluvi-dev (19/10/2026, ~16:40–16:55 BRT) — ambiente com dados reais

| Passo | Resultado |
|---|---|
| CI da branch | verde (`3dc3853`, 39313367667) |
| Backup pré-deploy (cifrado) + restauração isolada | `2026-10-19T19-44-07-944Z.dump.enc`; **PASS** (484 pgTAP da suíte anterior). Restauração só num container isolado e descartado; nenhum dado foi lido |
| `db push` | `20261017001300_card_archive.sql` |
| `supabase test db --linked` | **498/498 PASS** (fixtures em transação revertida) |
| Merge na `main` → deploy Cloudflare Pages + CI | ambos verdes (39314317813, 39314317602) |
| Backup pós-deploy + restauração isolada | `2026-10-19T19-50-48-651Z.dump.enc`; **PASS** (498 pgTAP) |
