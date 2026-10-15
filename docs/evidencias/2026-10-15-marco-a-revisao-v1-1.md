# Evidência — Marco A, revisão para a Especificação v1.1

- **Data/hora da execução:** 2026-10-15T08:00:53-03:00
- **Ambiente:** stack Supabase **local** (`project_id = fluvi`, Docker Desktop, Windows 10), dados 100% fictícios (`@fluvi.test`)
- **Commit:** pendente (nada commitado até esta execução)
- **Versões:** Node 24.19.0 · pnpm 12.8.1 · Supabase CLI 2.118.0 · PostgreSQL 17.6 · supabase-js 2.117.2 · Vitest 5.0.2 · pg 8.23.0
- **Escopo:** migration `20261015000400_spec_v1_1_adjustments.sql`, Edge Function `provision-user` em duas fases e testes da §19.9

## Comandos e resultados efetivamente executados

| Comando | Resultado |
|---|---|
| `pnpm db:reset` | 4 migrations aplicadas sem erro |
| `pnpm db:lint` | sem erros de schema |
| `pnpm test:db` | **97/97 PASS** (pgTAP) |
| `pnpm test:integration` | **25/25 PASS**, 2 arquivos, nenhum pulado |
| `pnpm test:integration` (2ª execução seguida) | **25/25 PASS**; a limpeza deixa 0 Admins, e o teste de concorrência não foi pulado |

## Testes de mutação (regressão proposital, depois revertida com `db reset`)

| Mutação | Resultado |
|---|---|
| Bootstrap sem `pg_advisory_xact_lock` | teste de concorrência **falhou** (nenhuma espera na trava) |
| Ativação sem exigir senha | **5 testes pgTAP falharam** (11, 27, 30, 31, 32) |
| `shares_household_with` sem exigir perfil ativo | teste pgTAP 27 **falhou** (nome de pendente visível) |
| (entrega 1) política de leitura `using (true)` | 11 testes falharam |

## Ajustes da v1.1 implementados e testados localmente

| Item | Situação |
|---|---|
| B8/§19.2: convite não ativa; `activation_completed_at`; guarda transversal na RLS | testado |
| B13/§19.2: retomada só de identidade vinculada à mesma operação | testado |
| B15/§19.6: trava, alvo único, recusa Admin pendente, idempotente | testado (inclusive concorrência real) |
| §19.3: `admin_operations` com `pending/succeeded`; revisão otimista; último Admin protegido | testado (a proteção do último Admin é coberta indiretamente pela proibição de alterar o próprio status) |
| B4: nomes só de membros com perfil ativo | testado. **Bug encontrado e corrigido nesta revisão**: pendentes do núcleo apareciam |
| B2: `RETURNING` negado em create sem read | testado |
| B11: textos ajustados ("não é garantia absoluta contra o dono do banco") | documentado |
| B14: senha mínima de 12 caracteres | **mantida provisoriamente a exigência de composição**. A checagem de senhas vazadas do Supabase hospedado depende de plano pago, e a decisão é sua |

## O que esta evidência NÃO comprova

- **D1 a D7 continuam abertos:** backup e restauração, recuperação de senha,
  rate limiting, bloqueio no login, telas de login e administração, CI no GitHub
  e projetos remotos.
- O teste de concorrência do bootstrap depende de um banco sem Admin gravado.
  Se houver um, ele é **pulado** e aparece como `skipped`, nunca como aprovado.
- Nada foi verificado em Supabase hospedado.
