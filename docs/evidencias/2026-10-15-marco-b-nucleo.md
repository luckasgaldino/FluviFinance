# Evidência — Marco B: núcleo financeiro (migrations, RPCs e testes)

- **Data/hora da execução final:** 2026-10-15T14:14:37-03:00 (suíte completa), exercício de backup às 14:27
- **Ambiente:** stack Supabase **local**; dados 100% fictícios. Nada do Marco B foi aplicado ao hospedado `fluvi-dev`
- **Base normativa:** `docs/marco-b/proposta-tecnica.md` rev. 3 (§17 prevalece)
- **Branch:** `marco-b/nucleo-financeiro` (commit: ver histórico do git)
- **Escopo desta entrega:** banco (schema, guardas, RLS, funções, RPCs, jobs) e testes. **Telas ainda não implementadas.**

## Migrations

| Arquivo | Conteúdo |
|---|---|
| `20261016000100_fin_core_schema.sql` | tipos, 20 tabelas, constraints (centavos, sinais, FKs compostas de titular, exclusão de sobreposição de ciclos), categorias padrão (MB-14) |
| `20261016000200_fin_guards_rls.sql` | razão somente-acréscimo e `recorded_at` do banco; imutabilidade de ciclo fechado/confirmado e dos seus itens; fatura congelada; sem DELETE físico; RLS por escopo; auditoria |
| `20261016000300_fin_domain_functions.sql` | relógio de negócio; acesso com erro único; idempotência; regra de ciclos; valor de ciclo; crédito não aplicado; **EQ-1**; saldo bitemporal; competência; views `security_invoker` |
| `20261016000400_fin_rpcs_core.sql` | contas, cartões, regras do cartão, lançamentos, compras parceladas, fechamento e confirmação de ciclo |
| `20261016000500_fin_rpcs_settlement.sql` | obrigações, pagamentos, estornos, transferências, anulação × reversão, ajuste de parcelas, recorrências, jobs (`pg_cron`) |

## Resultados efetivamente executados

| Comando | Resultado |
|---|---|
| `pnpm db:lint` | sem erros |
| `pnpm test:db` | **293/293 PASS**: 137 do Marco A + 156 do Marco B (04: 14 · 05: 32 · 06: 65 · 07: 45) |
| `pnpm test:integration` | **52/52 PASS** (inclui `fin-concurrency` 7 e `fin-jobs` 4) |
| `pnpm test:e2e` (Marco A) | 16/16 PASS em 2 de 3 execuções; **1 falha intermitente** numa execução logo após `db reset`, não reproduzida. Fica em observação |
| `pnpm backup:drill` | **PASS**: fotografia idêntica (66 itens), isolamento, **pgTAP 293/293 no banco restaurado** |

## Oráculos cobertos

| Oráculos | Onde |
|---|---|
| O1, O2, O8, O14, O15, O16, O19, O19b, O31, O35, O37 | `05_fin_accounts.test.sql` |
| O3, O4, O5, O10, O12, O18, O18b, O20, O20b, O20c, O21, O21b, O22, O23, **O36**, O39, O39b, O41, O42 | `06_fin_cards.test.sql` |
| O6, O7, O11, O17, O27, O28, O29, O30, O38, O9 | `07_fin_obligations.test.sql` |
| O13, O24, O16 (paralelo), O34 | `fin-concurrency.test.ts` (transações sobrepostas determinísticas + estresse pela API) |
| O11 (via job), O32, O33/O40 | `fin-jobs.test.ts` (CALL com COMMIT) |
| INV-P1, P2, P3, L1, L2, L7, C8 | `04_fin_hardening.test.sql` (varredura do catálogo) |

**Mapeamentos:**
- **O9** ("anular operação conciliada"): a conciliação com extrato é do Marco D. No B, o equivalente testado é "compra com parcela faturada não é anulável" (O36) e "compra no cartão não é revertida, usa estorno" (07).
- **O26** é coberto por O39b.

## Testes de mutação (regressão proposital, depois revertida)

| Mutação | Detectada por |
|---|---|
| M1: `settle_obligation` sem `FOR UPDATE` | O13 (B não esperou a trava) |
| M2: `refund_transaction` sem travas | O24 (B não esperou a trava) |
| M3: reversão sem absorver o crédito liberado | 07/O29, pela **verificação EQ-1 dentro da própria RPC** ("conciliação do cartão falhou") |
| M4: job sem subtransação de rollback | O40/O33 |
| M5: view sem `security_invoker` | 04 (varredura) |
| M6: razão sem gatilho de somente-acréscimo | 04 |

O M2 só passou a ser detectado depois de reescrever O13 e O24 com transações sobrepostas. Na primeira versão, as requisições HTTP "paralelas" raramente se sobrepunham, e o teste não comprovava a trava. A falha foi corrigida.

## Defeitos encontrados e corrigidos durante a implementação

1. `account_balance` usava `now()` (início da transação) como "conhecido até" padrão e omitia lançamentos da própria transação. Agora, sem instante informado, considera todo o conhecimento registrado.
2. A reversão de crédito liberava aplicações sem absorvê-las: o crédito revertido continuaria abatendo dívida. Corrigido e coberto (M3).
3. Somas em views devolviam `numeric`. Agora a API devolve sempre inteiros (`bigint`).
4. A restauração exigia a extensão `btree_gist`. O manifesto registra `required_extensions` e o exercício as cria antes do `pg_restore`.

## Decisões de implementação (dentro da rev. 3)

- **Relógio de negócio:** `private.today()` (America/Sao_Paulo). `fluvi.today` só pode ser definido em sessão SQL direta (testes e jobs), não pela API.
- **Mudança de regra do cartão:** itens já atribuídos ficam no ciclo do seu mês; datas de ciclos abertos e estimados são recalculadas; novas compras seguem a regra nova.
- **Horizonte de recorrências:** contado pelo **vencimento** (60 dias).
- **Anulação ou reversão de transferência:** sempre o par; exige `cancel` nas duas pontas.
- **Jobs:** `pg_cron` às 03:10 e 03:20 UTC; erro gravado só como `SQLSTATE` + marcador, sem valores.

## Limitações e pendências (não comprovadas por esta evidência)

- **Telas do Marco B** (contas, cartões, lançamentos, faturas, pagamentos) e seus E2E: próximos passos.
- **Aplicação ao `fluvi-dev`:** pendente da revisão destes resultados.
- **Dívida pré-existente de cartão** na data de corte: no B entra como compras. Não há saldo inicial de cartão.
- **Exclusão de identidade com histórico financeiro** é bloqueada pelo razão somente-acréscimo. Um pedido de exclusão de titular (LGPD) vai exigir um **procedimento de anonimização** próprio, a definir no gate de produção.
- **Restauração:** o schema `cron` não está no backup. Após restaurar um ambiente real, os jobs precisam ser reagendados (procedimento a acrescentar em `backup-restauracao.md`).
- **E2E:** a falha intermitente observada uma vez fica sob acompanhamento no CI.
