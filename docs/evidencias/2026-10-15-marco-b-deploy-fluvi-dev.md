# Evidência — Deploy controlado do Marco B (banco) no `fluvi-dev`

- **Data/hora:** 15/10/2026, ~15:40–15:50 (horário de Brasília)
- **Autorização:** do responsável, em 15/10/2026 ("Pode")
- **Projeto:** `fluvi-dev` (ref `wovocbnnpvsxndwjghco`, sa-east-1, Free, PostgreSQL 17.11). **Somente dados fictícios.**
- **Código:** branch `marco-b/nucleo-financeiro`, commit `f4d008d` (CI verde, execução 38785904760)
- **Plano seguido:** `docs/marco-b/plano-deploy-e-telas.md` §2
- **Escopo:** só o banco. Sem alteração de Auth, Edge Functions ou frontend; nenhuma tela do Marco B publicada.

## 2.1 Pré-validações

| Verificação | Resultado |
|---|---|
| Migrations no hospedado | as 7 do Marco A aplicadas; as 6 do Marco B (`20261016000100…0600`) são as únicas pendentes |
| `db push --dry-run` | lista exatamente as 6 migrations do Marco B |
| Extensões | `pg_cron` e `btree_gist` disponíveis |
| Dados existentes | 1 perfil (Admin do responsável); nenhuma tabela financeira |

## 2.2 Ponto de recuperação

| Item | Resultado |
|---|---|
| Backup pré-deploy (cifrado) | `2026-10-15T18-41-19-699Z.dump.enc`, sha256 `6c7ccf21a000845b0bee2bb084864d9fc3bf46a71823a21bff1648819fdb741b` |
| Restauração isolada | **PASS**: fotografia idêntica (25 itens); pgTAP 01–03 (137) no restaurado, a suíte compatível com o schema do backup |

Para validar backups de versões anteriores, o exercício ganhou a opção `--tests` (arquivos pgTAP compatíveis com o schema do backup).

## 2.3 Aplicação

| Passo | Resultado |
|---|---|
| `supabase db push` | 6 migrations aplicadas, sem erro |
| Agendamentos | `private.ensure_job_schedules(false)`: 2 jobs criados **desligados** |

## 2.4 Testes de segurança e integridade no hospedado

| Teste | Resultado |
|---|---|
| `supabase test db --linked` | **310/310 PASS** (inclui varredura de endurecimento 04 e conformidade 08, com C-3 executado contra o `pg_cron` real em transação revertida) |
| `tests/remote/hosted-finance.test.ts` (API hospedada, JWT real, TLS verificado com a CA raiz do Supabase) | **4/4 PASS**: EQ-1 = 0 após compra 6x, estorno e anulação; dívida R$ 700 coerente; conta a pagar parcial (restante 300, `partial`, caixa só o pago); idempotência (3× → 1); outro titular sem grant recebe `P0002` e não lê nenhuma tabela financeira; `anon` recebe `42501` |
| Execução controlada dos jobs | `close_due_cycles` e `generate_recurrences` = `succeeded` (0 itens: não havia ciclo vencido nem regra); EQ-1 = 0 em todos os cartões (2) |
| Agendamento habilitado | `ensure_job_schedules(true)`: `fluvi-close-due-cycles` (03:10 UTC) e `fluvi-generate-recurrences` (03:20 UTC) ativos; uma entrada de cada |

Observação: a primeira execução do teste remoto falhou por TLS no cliente de verificação (o `pg` do Node não reconhecia a cadeia do pooler). A correção usa a **CA raiz oficial do Supabase** (`prod-ca-2021`) com `verify-full`, sem desligar a verificação.

## 2.5 Verificação final

| Item | Resultado |
|---|---|
| Backup pós-deploy | `2026-10-15T18-49-10-109Z.dump.enc`, sha256 `0de11565c8a4795fd2e78b0e0111b35b57775647c3c4b9fe14bcea72e8f0293b`, 13 migrations |
| Restauração isolada | **PASS**: fotografia idêntica (67 itens), **pgTAP 310** no restaurado (C-3 pulado: sem `pg_cron` por desenho) |

## Dados fictícios deixados no `fluvi-dev`

Quatro identidades `remoto-fin-*.…@fluvi.test` (duas da execução válida e duas da execução que falhou por TLS), com histórico financeiro fictício e perfis **bloqueados**. Não podem ser excluídas pelo caminho normal (razão somente-acréscimo). Serão tratadas pelo procedimento de anonimização (C-4) quando implementado.

## O que esta evidência não cobre

- Telas do Marco B (não iniciadas).
- Homologação do Marco B.
- C-4 (anonimização) e demais critérios do gate §10. **Dados reais continuam proibidos.**
- O próximo backup diário automático (03:15 BRT) incluirá o schema do Marco B; será conferido na próxima execução do workflow.
