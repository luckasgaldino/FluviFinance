# Evidência — Remodelagem v2.2, fase R2 (família como titular)

**Data:** 15/10/2026 · **Branch:** `remodelagem/r2-familia`
**Estado:** testado localmente. **Não aplicado** no fluvi-dev: a migração no ambiente hospedado depende de autorização e de backup prévio.

## O que entrou

- **Migration** `20261017000100_family_ownership.sql` ([ADR-0005](../decisoes/ADR-0005-familia-titular.md)):
  - regra `private.can_access_family`;
  - mapeamento 1:1 de titular para família;
  - `owner_user_id` → `family_id` em 19 tabelas, e `from_/to_family_id` em `transfers`;
  - FKs compostas recriadas, com a família `ON DELETE RESTRICT`;
  - views e políticas de leitura por família;
  - 38 funções recriadas a partir do catálogo, só com troca de nomes;
  - `my_families()`;
  - `admin_set_data_grant` revogada;
  - parcelas de 1 a 36;
  - privilégios fechados de novo.
- **Web:**
  - contexto de família ativa (`lib/family.tsx`): lista de `my_families`, escolha guardada só como id, e a troca de família bloqueia a área financeira e limpa o cache;
  - telas filtram por família ativa e criam com `p_family`;
  - seleção de família em Configurações quando há mais de uma;
  - aviso para quem não tem família;
  - tela de Permissões removida do admin;
  - limite de 36 parcelas na interface.
- **Docs:** ADR-0005 e matriz RLS atualizada.

## Validação da migração

| Verificação | Resultado |
|---|---|
| Aplicada sobre o banco local **com os dados existentes** (`migration up`) | ok |
| Nenhuma coluna `owner_*` fora de `data_grants`; nenhuma função ou política usando a regra antiga | ok |
| Lançamentos com família inexistente | 0 |
| Razão × lançamento com família divergente | 0 |
| EQ-1 (conciliação do cartão) em todos os 14 cartões existentes | ok |
| Banco zerado (`db reset`) + `db lint` | sem erros |

## Testes (local)

| Suíte | Antes | Agora |
|---|---|---|
| pgTAP | 312 | **319/319** |
| Integração | 52 | **52/52** |
| E2E | 37 | **36/36** (saiu o fluxo da tela de Permissões) |
| Unitários | 33 | **33/33** |
| Build web | ok | ok |
| Exercício de backup e restauração (`pnpm backup:drill`) | PASS | **PASS**: isolamento por família no banco restaurado e 319 pgTAP sobre a restauração |

**Mudanças nas suítes:**

- **01:** reescrito para família.
  - FAM-01: visão única, inclusive do que outro membro registrou.
  - FAM-02: isolamento entre famílias.
  - Admin sem finanças (PRIV-10).
  - Membro bloqueado não apaga o histórico da família.
  - Suspensão de vínculo corta o acesso na hora.
  - Realocação não leva histórico (FAM-03, parte do banco).
  - Duas famílias e fim das permissões individuais.
- **05:** O14, O15 e O19b viraram cenários de família: transferência na mesma família, FIN-05 e mesmo erro para família alheia.
- **04, 06, 07, 08:** família com o mesmo UUID do usuário; troca de nomes.
- **09 (novo):** aceites FIN-01..05 pela API real, limite de 36 parcelas e FAM-01/02.
- **Exercício de restauração:** a fixture virou família (sem `data_grants`); as checagens usam `my_families` e `can_access_family`. O CI da primeira versão da branch falhou só nesse passo, que ainda usava `accessible_owners`.
- **Integração:** `createFinanceUser`/`createFamily`. O caso de permissão individual virou "não há permissão individual; suspender o vínculo corta a família com o mesmo token", com auditoria.

**Mutação:** com `can_access_family` sem o filtro de família (qualquer membro acessaria qualquer família), 30 asserções falham em 5 suítes (01, 05, 06, 07, 09). Com a regra restaurada, tudo volta a passar.

## Para aplicar no fluvi-dev (pendente de autorização)

1. Backup cifrado do fluvi-dev (`pnpm backup`) e conferência no R2.
2. `supabase db push` da migration.
3. pgTAP no hospedado e deploy do frontend (merge na `main`).

Os usuários fictícios existentes ganham, cada um, a própria "Família de \<nome\>".
