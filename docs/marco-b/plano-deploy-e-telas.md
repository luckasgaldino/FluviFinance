# Marco B — Plano de deploy controlado no `fluvi-dev` e sequência das telas

- **Data:** 15/10/2026 · **Base:** Especificação v1.2 (§20), evidência `docs/evidencias/2026-10-15-marco-b-nucleo.md`
- **Estado:** plano. **Nenhum deploy foi executado.** Execução só com autorização explícita.
- **Dados:** somente fictícios, também no `fluvi-dev`.

---

## 1. Pré-condição: itens de conformidade (§20.17)

Antes do deploy, implementar e testar no repositório (branch `marco-b/nucleo-financeiro`):

| Código | Ajuste | Teste novo |
|---|---|---|
| C-1 | `adjust_installments` preserva parcelas de ciclo **confirmado** (elegíveis só em ciclos estimados) | ajuste com ciclo confirmado aberto → recusado / preservado |
| C-2 | `update_card_rules` devolve e registra o relatório de itens fora da nova janela, sem mover itens | regra nova que deixa compra fora da janela → listada, não movida; EQ-1 = 0 |
| C-3 | script idempotente de (re)agendamento dos jobs | rodar 2× → uma entrada por job |

O C-4 (anonimização) não bloqueia o deploy no `fluvi-dev`, porque lá só há dados fictícios. Ele bloqueia o gate de dados reais.

---

## 2. Plano de deploy controlado no `fluvi-dev`

### 2.1 Pré-validações (antes de tocar o projeto)

1. CI verde na branch, com C-1 a C-3 incluídos: lint, pgTAP, integração, E2E e exercício de backup.
2. `supabase migration list --linked`: confirmar que o `fluvi-dev` está exatamente nas 7 migrations do Marco A e que as 5 do Marco B são as únicas pendentes.
3. `supabase db push --dry-run`: revisar a lista de migrations.
4. Conferir no `fluvi-dev` a disponibilidade de `btree_gist` e `pg_cron` (já verificada em 15/10/2026: 1.7 e 1.6.4).
5. Confirmar que o `fluvi-dev` só tem dados fictícios: o Admin do responsável e nenhuma conta financeira.

### 2.2 Ponto de recuperação

1. Backup cifrado manual imediatamente antes (`node scripts/backup.mjs --remote`).
2. Restaurar esse backup no container isolado (`pnpm backup:drill --backup …`) e confirmar PASS. Só então seguir.
3. Registrar o hash do backup na evidência.

### 2.3 Aplicação

1. `supabase db push` com as 5 migrations do Marco B, numa janela única.
2. Habilitar `pg_cron` e agendar os jobs pelo script idempotente (C-3), **desligados** até o passo 2.5.
3. Nenhuma alteração de Auth, Edge Function ou frontend nesta etapa.

### 2.4 Testes de segurança e integridade no hospedado

1. `supabase test db --linked`: suíte pgTAP completa (293+), cada arquivo em transação revertida.
2. Varredura de endurecimento (arquivo 04) no hospedado: RLS, privilégios, `search_path`, `EXECUTE`, `security_invoker`.
3. Teste remoto ampliado (`tests/remote`): com usuário fictício, criar conta, cartão e compra parcelada; pagar fatura; estornar; anular; verificar EQ-1 = 0; confirmar que o Admin não lê nada financeiro e que outro titular sem grant recebe `not_found_or_forbidden`. Remover o usuário fictício ao final (ou anonimizá-lo, se tiver histórico).
4. Execução controlada dos jobs (`CALL private.run_job(...)`), com conferência de `job_runs` = `succeeded` e da EQ-1 de todos os cartões. Só então habilitar o agendamento.

### 2.5 Verificação final e evidência

- Backup pós-deploy + exercício de restauração com pgTAP no restaurado.
- Evidência em `docs/evidencias/` com: hashes dos backups pré e pós, lista de migrations, resultados, `job_runs`.

### 2.6 Estratégia de recuperação

| Falha | Ação |
|---|---|
| `db push` falha no meio | cada migration é transacional, então a que falhou não fica parcialmente aplicada. Corrigir e reaplicar, ou restaurar o backup pré-deploy |
| testes de segurança ou integridade falham após aplicar | desligar os agendamentos; **restaurar o backup pré-deploy** no `fluvi-dev` (só há dados fictícios); corrigir no repositório e repetir o plano |
| job falha após habilitar | o job já faz rollback e registra a falha; desligar o agendamento, investigar `job_runs`, corrigir e reexecutar manualmente |

Não há "rollback por migration reversa" para o razão (somente-acréscimo). A recuperação é sempre por restauração do backup pré-deploy.

---

## 3. Sequência de implementação das telas do Marco B

Cada etapa entra com testes E2E (desktop e 360 px), verificação axe, mensagens de erro pela tabela `errors.ts` e retorno mínimo respeitado (quem só tem `create` não vê detalhes).

| # | Tela | Conteúdo | RPCs / views |
|---|---|---|---|
| 1 | **Contas** | lista com saldo; criar conta com abertura; extrato com data financeira | `create_account`, `v_account_balances`, `ledger_entries`, `account_balance` |
| 2 | **Lançamentos (receita/despesa)** | formulário completo (Principal / Detalhes / Adicionais, §3.3); lista por competência e por caixa; anular e reverter com motivo | `create_transaction`, `void_transaction`, `reverse_transaction` |
| 3 | **Cartões** | cadastro (dias, política, limite, final do cartão); posição: dívida, fatura atual, prévia, futuras, limite disponível | `create_card`, `update_card_rules`, `v_card_position` |
| 4 | **Compras e parcelamentos** | compra parcelada com prévia das parcelas e do ciclo estimado; detalhe da compra (bruto, estornos, líquido); ajuste de parcelas | `create_card_purchase`, `adjust_installments`, `v_purchase_net`, `installments` |
| 5 | **Faturas** | ciclos (estimado/confirmado), itens, valor, pago, restante; confirmar datas e valor do banco; divergências | `v_card_cycles`, `confirm_billing_cycle`, `cycle_discrepancies` |
| 6 | **Obrigações e pagamentos** | contas a pagar e previsões; pagamento parcial ou total; status e atraso; estornos | `create_obligation`, `settle_obligation`, `adjust_obligation`, `cancel_obligation`, `refund_transaction`, `v_obligations_status` |
| 7 | **Transferências** | entre contas próprias e entre titulares (create nas duas pontas); visão da ponta visível | `transfer_funds` |
| 8 | **Recorrências** | regras, pausa e cancelamento; "esta e as futuras" | `create_recurrence_rule`, `set_recurrence_status`, `update_recurrence_amount` |

Fora desta sequência, sem antecipar: BI e dashboards (Marco D), importação e dívida anterior de cartão (Marco D), offline/PWA e anexos (Marco C).

---

## 4. Dependências e impedimentos técnicos

| # | Item | Impacto | Recomendação |
|---|---|---|---|
| D-1 | C-1 a C-3 (§1) | o deploy no `fluvi-dev` não atende integralmente à v1.2 sem eles | implementar antes do deploy (escopo pequeno, com testes) |
| D-2 | SMTP próprio (pendente do Marco A) | no `fluvi-dev`, convites só chegam ao e-mail do responsável, o que limita testar telas com Luck e Bia reais (fictícios) | escolher provedor antes da homologação das telas; até lá, usar usuários fictícios criados por fixture |
| D-3 | Identidades com histórico financeiro não são apagáveis | usuários de teste remoto acumulam no `fluvi-dev` | usar e-mails de teste dedicados; o procedimento de anonimização (C-4) resolve no médio prazo |
| D-4 | Bundle do frontend (~560 kB) | cresce com 8 telas novas | dividir por rota ao iniciar as telas (sem custo de escopo) |
| D-5 | Falha intermitente de E2E (G4) | pode mascarar regressões nas telas novas | manter traces no CI; investigar na primeira recorrência |

Nenhum impedimento exige nova decisão de produto. São todos de execução.

---

## 5. Próxima entrega recomendada

1. Implementar **C-1, C-2 e C-3** com testes e mutação.
2. Com autorização, executar o **deploy controlado no `fluvi-dev`** (§2), com evidência.
3. Iniciar as **telas 1 e 2** (Contas e Lançamentos).
