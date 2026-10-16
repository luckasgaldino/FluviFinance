# Evidência — Remodelagem v2.2, fase R4b (edição, categorias e extrato)

**Data:** 16/10/2026 · **Branch:** `remodelagem/r4b-edicao-categorias`

## O que entrou

- **Migration `20261017000600_edit_and_categories.sql`:**
  - **Edição de lançamento (FF-02)** com `edit_transaction`. Numa única transação idempotente:
    - anula o original (motivo "substituído por edição", com compensação na data original);
    - registra o novo, que aponta o original em `replaces_transaction_id`.

    Só receitas e despesas são editáveis; compras no cartão seguem com ajuste de parcelas, estorno e anulação. Editar exige desbloqueio. Outro membro da família pode editar; outra família recebe o mesmo erro de inexistente.
  - **Categorias da família (FF-08)** com `family_categories`, `create_category` e `set_category_active`:
    - não deixa duplicar nome, inclusive em relação às categorias padrão e sem diferenciar maiúsculas;
    - arquivar tira a categoria dos novos lançamentos e preserva o histórico;
    - categorias padrão não são arquivadas por uma família;
    - não é preciso desbloqueio, porque só há nomes.
- **Web:**
  - Lançamentos ganha **Editar**, com o original marcado "Editado" e o novo como "versão editada".
  - **Filtros do extrato (FF-10)** por tipo, conta e categoria.
  - Configurações ganha **Categorias da família**: criar, arquivar e reativar.

## Testes (local)

| Suíte | Resultado |
|---|---|
| pgTAP | novo `12_v22_edit_categories` (25 asserções): edição, histórico, saldo, consumo, idempotência, regras, desbloqueio, outra família; categorias criadas, duplicadas, arquivadas e isoladas |
| E2E | novo `edit-categories`: categoria da família, filtro por categoria, edição de R$ 70 para R$ 50 (original "Editado", saldo R$ 930), arquivar remove a categoria do lançamento rápido |

**Bateria local:** pgTAP **417/417** (12 arquivos), integração 58/58, E2E **43/43**, unitários 33/33, build e `db lint` ok, restauração **PASS** (417 pgTAP no restaurado).

## Deploy no fluvi-dev (16/10/2026, ~01:40–01:55 BRT)

| Passo | Resultado |
|---|---|
| CI da branch | verde (`e31dcf8`, 38851320802) |
| Backup pré-deploy + restauração isolada | `2026-10-16T04-40-11-729Z.dump.enc`; **PASS** (392 pgTAP da suíte pré-R4b) |
| `db push` | `20261017000600_edit_and_categories.sql` aplicada |
| `supabase test db --linked` | **417/417 PASS** |
| Testes remotos | **11/11 PASS** |
| Merge na `main` → deploy | `deploy-dev` e CI verdes (`e31dcf8`) |
| Backup pós-deploy + restauração isolada | `2026-10-16T04-49-45-536Z.dump.enc`; **PASS** (417 pgTAP) |
