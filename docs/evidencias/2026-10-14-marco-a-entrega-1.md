# Evidência — Marco A, entrega 1 (identidade, permissões e isolamento)

- **Data/hora da execução:** 2026-10-14T23:56:59-03:00
- **Ambiente:** stack Supabase **local** (`project_id = fluvi`, Docker Desktop, Windows 10), dados 100% fictícios (`@fluvi.test`)
- **Commit:** pendente (a entrega ainda não foi commitada)
- **Versões:** Node 24.19.0 · pnpm 12.8.1 · Supabase CLI 2.118.0 · PostgreSQL 17.6.1.171

## Comandos e resultados efetivamente executados

| Comando | Resultado |
|---|---|
| `pnpm db:reset` | 3 migrations aplicadas sem erro |
| `pnpm test:db` | **56/56 PASS** (pgTAP) |
| `pnpm test:integration` | **19/19 PASS** (Auth real, convite por e-mail via Mailpit, MFA TOTP, PostgREST, Edge Function) |
| `pnpm db:lint` | sem erros de schema |
| Teste de mutação (política de leitura trocada por `using (true)`) | **11/56 falharam**, como esperado: os testes detectam a quebra de isolamento |
| `POST /auth/v1/signup` direto | `422 signup_disabled` |

## Aceites do FIN-01 cobertos nesta entrega

- [x] Luck não lê Bia sem autorização
- [x] Depois do grant, lê apenas o escopo concedido (e só na direção concedida)
- [x] A revogação impede novas consultas imediatamente, com o mesmo token
- [x] Admin sem grant não lê linhas financeiras (nem com MFA)
- [x] Cliente não altera grants pela API (insert direto e RPC administrativa negados)
- [x] Sem signup público; convite real do Admin; MFA obrigatório para administrar

## Lacunas e o que esta evidência NÃO comprova

- A prova de linhas financeiras usa uma tabela-sonda criada só dentro da transação
  do teste pgTAP, porque as tabelas financeiras são do Marco B. Pela API, o
  isolamento foi provado com `accessible_owners`, `profiles` e `data_grants`.
- **Backup e restauração ainda não foram executados.** Ficam para a entrega 2 do Marco A.
- O CI foi escrito (`.github/workflows/ci.yml`), mas **ainda não rodou** no GitHub.
- A recuperação de senha, o rate limiting das funções e o ban no Auth ao bloquear
  usuário não foram testados.
- Nada foi verificado em projeto Supabase remoto (dev/prod): eles ainda não existem.
