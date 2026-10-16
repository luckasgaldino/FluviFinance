# ADR-0005 — A família é a titular dos dados financeiros

**Data:** 15/10/2026 · **Estado:** aceita (remodelagem v2.2, fase R2) · **Substitui em parte:** ADR-0002

## Contexto

A especificação v2.2 (§2, §6.2–6.3) define a família como única proprietária dos dados financeiros. Todos os membros ativos veem tudo; não há visão nem permissão individual, e `created_by` é só autoria. O modelo anterior (ADR-0002) usava um titular por usuário (`owner_user_id`), com permissões granulares (`data_grants`) entre membros de um núcleo.

## Decisão

1. **Família = `households`.** A família e seus membros reaproveitam `households` e `household_members`, sem tabela nova, o que evita duplicar a entidade só por nome. Na interface, aparece "Família".
2. **`owner_user_id` → `family_id`** em todas as tabelas financeiras, por `RENAME`. Em `transfers`, as colunas são `from_family_id` e `to_family_id`. As FKs compostas `(id, family_id)` continuam garantindo que operação, conta, cartão e razão sejam da mesma família. A FK para `households` é `ON DELETE RESTRICT`: o histórico nunca cai em cascata.
3. **Acesso:** `private.can_access_family(família, escopo, operação)` exige usuário financeiro ativo, membro ativo e família ativa.
   - O escopo é ignorado, porque a família não tem permissão granular.
   - A operação distingue leitura de escrita. É nesse ponto que a R3 vai exigir o desbloqueio financeiro para leituras.
4. **Funções:** foram recriadas a partir das definições vigentes no catálogo, só trocando nomes (`owner_user_id` → `family_id`, `p_owner` → `p_family`). A lógica financeira não mudou. As que mudaram de assinatura foram removidas e recriadas, com os privilégios fechados de novo.
5. **`data_grants` deixa de conceder acesso.** A tabela e o histórico ficam; `admin_set_data_grant` tem o EXECUTE revogado. `accessible_owners` foi substituída por `my_families()`.
6. **Dados existentes** (só fictícios): cada antigo titular virou uma família "Família de \<nome\>", com ele como membro, num mapeamento 1:1.
7. **Parcelamento:** de 1 a 36 parcelas (FF-05).

## Consequências

- Membros da mesma família compartilham contas, cartões, lançamentos e faturas (FAM-01). Revogar ou suspender o vínculo corta o acesso na hora, com a mesma sessão, sem mover nenhum lançamento (FAM-03, parte do banco).
- Um usuário pode estar em mais de uma família. O banco libera as famílias em que ele é membro ativo; o cliente trabalha sempre com uma família ativa. A partir da R3, o desbloqueio vale para uma família por vez (PRIV-08).
- **Reversão:** enquanto cada família tiver um único membro, a migração inversa (renomear de volta e remapear família → membro) é direta. Depois disso, restaura-se o backup cifrado feito antes da migração no ambiente.
- O admin continua sem nenhum acesso financeiro: não é membro de família, e o gatilho de exclusividade continua valendo.
