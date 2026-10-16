# Evidência — Remodelagem v2.2, fase R4 (fluxos com dados reais)

**Data:** 15/10/2026 · **Branch:** `remodelagem/r4-fluxos`

## O que entrou

- **Migration `20261017000300_family_reports.sql`:**
  - `family_overview(família, mês)`:
    - caixa (saldo das contas);
    - receitas e consumo do mês por competência;
    - consumo por categoria;
    - faturas por cartão (atual, fechadas em aberto, dívida);
    - evolução de 6 meses;
    - parcelas a faturar em 12 meses.
  - `family_installments(família)`: compras parceladas com quanto falta faturar e próxima parcela; calendário de 36 meses.
  - `family_report(família, de, até)`: consumo por categoria, receitas × consumo por mês, consumo por quem lançou e compromissos; período de até 36 meses.
  - Todas exigem leitura da família, ou seja, membro ativo e desbloqueio vigente.
  - Usam uma única definição de **consumo**: `competence_summary.recognized_total_cents`, que soma despesas diretas, compras no cartão líquidas de estorno e contas reconhecidas.
- **Web:**
  - Visão geral, Parcelas e Relatórios com dados reais. Os dados de demonstração (`lib/demo.ts`) foram removidos.
  - Navegação por mês na Visão geral.
  - Relatórios com períodos de 1, 3, 6 e 12 meses, quatro visões e CSV.
  - **Pagamento de fatura** (integral ou parcial) na tela do cartão, via `settle_obligation`.

## Definições sem dupla contagem (§6.10)

| Métrica | Fonte | Observação |
|---|---|---|
| Caixa | saldo das contas | a compra no cartão não reduz; o pagamento da fatura reduz |
| Consumo | competência | a compra entra inteira no mês dela; parcela que vence e pagamento de fatura **não** somam de novo |
| Compromisso | faturas e parcelas a faturar | dívida, separada de consumo e de caixa |

## Testes (local)

| Suíte | Resultado |
|---|---|
| pgTAP | **384/384**; nova suíte 11 com 26 asserções de números conhecidos, pagamento de fatura, autoria, limite de período, desbloqueio e isolamento |
| Integração | 57/57 |
| E2E | **39/39**; novo `insights-flow`: lançamentos pelo formulário rápido; Visão geral com saldo R$ 2.850, receitas R$ 1.000 e consumo R$ 750; Parcelas; Relatórios com CSV; pagamento de R$ 100 pela tela do cartão, com saldo R$ 2.750 e consumo inalterado |
| Unitários | 33/33 |
| Build e `db lint` | ok |
| Exercício de restauração | **PASS** (384 pgTAP no restaurado) |

## Ainda não coberto (próximas entregas)

- **Edição de lançamento (FF-02):** hoje há anulação e reversão com histórico; falta a edição como "anular e recriar" numa única operação.
- **Categorias personalizadas por família com arquivamento (FF-08):** o banco aceita categorias por família; falta a tela.
- **Extrato com filtros por conta e cartão (FF-10):** o extrato por conta e a lista mensal de lançamentos existem; faltam filtros combinados.
- **R5:** convites, aceite e troca de família no admin.
- **R6:** PWA instalável (manifest e service worker sem cache de API) e homologação no iPhone.

## Deploy no fluvi-dev (15–16/10/2026, ~23:50 BRT)

Sob a autorização do responsável para executar as ações pertinentes. O ambiente tem só dados fictícios.

| Passo | Resultado |
|---|---|
| CI da branch | verde (`4ff7a2e`, execução 38842194363) |
| Backup pré-deploy + restauração isolada | `2026-10-16T02-52-34-942Z.dump.enc`; **PASS** (68 itens, 358 pgTAP da suíte pré-R4) |
| `db push` | `20261017000300_family_reports.sql` aplicada sem erro |
| `supabase test db --linked` | **384/384 PASS** |
| Testes remotos | **11/11 PASS** |
| Merge na `main` → deploy | `deploy-dev` e CI verdes (`4ff7a2e`); `/relatorios` 200 |
| Backup pós-deploy + restauração isolada | `2026-10-16T03-02-39-937Z.dump.enc`; **PASS** (384 pgTAP no restaurado) |
