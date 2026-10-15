# Fluvi — Gestão Financeira Pessoal e Familiar

> *Seu dinheiro em movimento. Seus planos em crescimento.* (nome e marca provisórios)

Aplicação web/PWA para controle financeiro individual e familiar. A construção
segue a [Especificação Técnica e Funcional v1.2](docs/Fluvi_Especificacao_Tecnica_Funcional_v1.2.md),
dividida em marcos (A–E).

## Estado atual

| Marco | Situação |
|---|---|
| **A — Fundação e Segurança** | **em andamento.** Testados **localmente**: identidade, ativação, permissões, RLS, isolamento, backup/restauração, recuperação de senha, rate limiting, recuperação do Admin, bloqueio no login e telas de login/administração ([D1–D3](docs/evidencias/2026-10-15-marco-a-d1-d2-d3.md), [D4–D5](docs/evidencias/2026-10-15-marco-a-d4-d5.md)). Abertos: D6 (CI no GitHub), D7 (projetos hospedados) e o que depende deles |
| B — Operação financeira | não iniciado |
| C — Mobile/PWA | não iniciado |
| D — Inteligência analítica | não iniciado |
| E — Evoluções | não iniciado |

Os termos seguem a especificação: *implementado ≠ testado ≠ homologado ≠ produção*.
Nada está em produção e nenhum dado real deve entrar no sistema antes do gate de
produção (§10 da especificação).

## Pré-requisitos

- **Node 24.19.0** (veja `.nvmrc`)
- **pnpm 12.8.1** (`corepack enable` ou instalação global)
- **Docker Desktop** em execução

## Primeiros passos

```bash
pnpm install          # instala o Supabase CLI, o frontend e as dependências de teste
pnpm db:start         # sobe Postgres, Auth, API e Edge Functions locais (portas 553xx)
pnpm web:dev          # abre o app em http://127.0.0.1:5173
pnpm test             # pgTAP + integração + E2E
pnpm db:stop          # desliga a stack
```

Na primeira vez, instale o navegador dos testes E2E:
`pnpm --filter @fluvi/tests exec playwright install chromium`.

Para entrar no app localmente, crie o primeiro Admin seguindo o
[procedimento de bootstrap](docs/operacao/bootstrap-admin.md). Localmente, os
e-mails de convite chegam no Mailpit.

Outros comandos:

| Comando | O que faz |
|---|---|
| `pnpm db:reset` | recria o banco local e reaplica todas as migrations |
| `pnpm db:lint` | verifica funções e schema (plpgsql_check) |
| `pnpm test:db` | testes pgTAP de RLS e isolamento (`supabase/tests/database`) |
| `pnpm test:integration` | Auth real, convite e recuperação por e-mail, MFA, rate limit, PostgREST e Edge Functions (`tests/integration`) |
| `pnpm test:e2e` | Playwright: fluxos completos pela interface, acessibilidade (axe) e 360 px (`tests/e2e`) |
| `pnpm web:build` | typecheck + build de produção do frontend (`apps/web`) |
| `pnpm backup:drill` | exercício completo de backup cifrado e restauração isolada, com dados fictícios ([detalhes](docs/operacao/backup-restauracao.md)) |
| `pnpm backup` | backup cifrado do banco local (exige `FLUVI_BACKUP_KEY`) |

E-mails enviados localmente (convites, recuperação) aparecem no Mailpit: <http://127.0.0.1:55324>.

Rode `pnpm backup:drill` com o banco sem Admin gravado (logo após `pnpm db:reset`
ou depois da suíte de integração, que limpa o que cria).

## Estrutura

```
apps/web/            # React + Vite: login, MFA, painel administrativo
supabase/
  migrations/        # schema, RLS, funções de autorização e RPCs administrativas
  functions/         # Edge Functions (provision-user)
  tests/database/    # pgTAP
tests/integration/   # Vitest contra a stack local
scripts/             # backup cifrado e exercício de restauração
docs/
  decisoes/          # ADRs
  operacao/          # procedimentos: bootstrap e recuperação do Admin, backup, rate limiting
  evidencias/        # resultados de testes efetivamente executados
  matriz-rls.md      # quem pode o quê, e qual teste prova
```

`packages/domain` e `packages/data` serão criados quando o domínio
financeiro começar.

## Princípios de segurança

- O cadastro público é desativado. O primeiro Admin é criado manualmente
  ([procedimento](docs/operacao/bootstrap-admin.md)) e os outros usuários entram por convite.
- Convite não ativa: a conta fica `pending` até o convidado comprovar o e-mail e definir a senha.
- O Admin só administra com MFA (`aal2`) e **não tem acesso a dados financeiros**.
- Toda permissão é decidida no PostgreSQL (RLS + `private.can_access_owner`),
  nunca na interface nem em `user_metadata`.
- A chave `service_role` existe apenas nas Edge Functions, nunca no navegador.
- Auditoria sem UPDATE/DELETE para a aplicação, guardando só digests (sem valores
  sensíveis). Isso não é garantia absoluta contra o dono do banco (§19.4).

Detalhes em [ADR-0002](docs/decisoes/ADR-0002-modelo-de-autorizacao.md) e na
[matriz RLS](docs/matriz-rls.md).
