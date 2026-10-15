# Evidência — Marco B: telas de Contas e Lançamentos (FIN-02, FIN-04)

- **Data/hora:** 2026-10-15T16:52-03:00 · **Ambiente:** local (stack Supabase + Vite + Chromium); dados fictícios
- **Branch:** `marco-b/telas-contas-lancamentos` · **Não publicado** no `fluvi-dev` (depende de autorização; ver abaixo)

## Entregue

| Item | Conteúdo |
|---|---|
| `packages/domain` (§4.1) | `parseBRL`/`formatBRL` em centavos **sem ponto flutuante**; `splitCents` igual ao banco (MB-05); datas de negócio em America/Sao_Paulo |
| Migration `20261016000700_fin_transaction_time.sql` | FIN-04: hora opcional no lançamento (`occurred_at` no fuso do lançamento; data de negócio inalterada) |
| Tela **Contas** | saldos de hoje (só contas visíveis pela RLS); nova conta com saldo inicial e data de abertura (titular selecionável se houver grant `accounts/create`) |
| Tela **Extrato** | movimentos por data financeira, incluindo compensações de anulação; descrição só para quem lê lançamentos |
| Tela **Lançamentos** | lista por **competência** ou **data do lançamento**, navegação por mês, status (Anulado/Revertido) e motivo |
| **Novo lançamento** | grupos Principal / Detalhes / Adicionais (§3.3): tipo, valor, descrição, categoria, conta, data, hora, competência, titular, observação; operação idempotente por formulário |
| **Anular × Reverter** | painéis distintos explicando a diferença (§20.1); motivo obrigatório; reversão com data do evento |

Localização e anexo ficam para o Marco C (MB-15), indicados no formulário.

## Resultados efetivamente executados

| Comando | Resultado |
|---|---|
| `pnpm test:unit` | **33/33** (inclui 0,10 + 0,20 sem erro de float; virada do dia em São Paulo) |
| `pnpm test:db` | **312/312** (inclui hora do lançamento) |
| `pnpm test:integration` | **52/52** |
| `pnpm test:e2e` | **23/23**: novos `finance-flow` (6: criar conta, valor inválido, despesa → saldo e extrato, anulação, reversão, isolamento entre titulares) e telas financeiras a 360 px com axe |
| `pnpm web:build` | ok |
| `pnpm backup:drill` | PASS, pgTAP 312 no restaurado |

## Para publicar no `fluvi-dev` (requer autorização)

1. Aplicar a migration `…0700` ao `fluvi-dev`. Sem ela, o formulário falha, porque envia a hora.
2. Levar a branch para a `main`. O workflow de deploy publica as telas em `fluvi-dev.pages.dev`.

## Publicação no `fluvi-dev` (15/10/2026, autorizada)

| Passo | Resultado |
|---|---|
| CI da branch | 1ª execução falhou por **YAML inválido** (nome de passo com `: ` sem aspas) e foi corrigida; execução 38803038339 verde |
| Backup pré-publicação | `2026-10-15T20-28-04-422Z.dump.enc`, sha256 `7302b50a5c1f2be2aab80fe5f2d41b7d1f988803121bd0567f3226306de180f6`; restauração PASS (fotografia idêntica, pgTAP 278 compatíveis com o schema do backup, sem o 05, que já usa a hora) |
| Migration `…0700` no `fluvi-dev` | aplicada; `supabase test db --linked` **312/312** |
| `main` + deploy do Pages | deploy `success`; `/contas` responde 200; bundle publicado contém as telas novas |
| Usuário de validação | `luck.teste@fluvi.test` (fictício, sem núcleo nem grants), senha definida pelo responsável via link de uso único |
