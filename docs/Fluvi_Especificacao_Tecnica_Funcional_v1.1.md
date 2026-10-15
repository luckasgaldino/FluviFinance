# FLUVI — Especificação Técnica e Funcional v1.1

**Produto:** Fluvi — Gestão Financeira Pessoal e Familiar  
**Versão:** 1.1 — revisão normativa do Marco A  
**Data:** 15/10/2026  
**Estado:** especificação de desenvolvimento atualizada a partir do relato da entrega 1 do Marco A; implementação informada não equivale a validação independente ou homologação  
**Origem:** seis rodadas de levantamento com o solicitante; referência arquitetural Portal do Cliente Luis Fronterotta v1.4 (material fornecido pelo solicitante)  
**Marca:** nome provisório; identidade conceitual Fluvi + Broto; verificar disponibilidade e aprovar antes de publicar marca definitiva.

## 1. Objetivo, resultados e limites

Desenvolver uma aplicação web responsiva, instalável como PWA no iPhone, para controle financeiro individual e familiar. Usuários iniciais: uma identidade exclusivamente administrativa, Luck e Bia, com estrutura que permita cadastrar usuários e vínculos no futuro. O sistema permite acompanhar receitas, despesas, contas, cartões, parcelamentos, faturas, pagamentos, metas, histórico de seis meses, BI e automações. Operação real será habilitada **por marcos**, somente após requisitos de segurança e recuperação adequadamente testados.

**Prioridade da experiência:** cadastro eficiente da despesa diária no celular, sem sacrificar um formulário completo. Desktop oferece visão analítica aprofundada. Aplicativo nativo iOS/Android e conexão bancária automática não fazem parte do MVP. Nenhum serviço pago, chave de IA, cobrança ou upgrade será ativado sem aprovação explícita.

**Classificação contratual de cada requisito:**
- **MVP/M-A a M-D:** implementar conforme os marcos e seus critérios de aceite.
- **M-E:** evolução incremental após funcionamento do núcleo (IA avançada, PDF/imagem, push e relatórios adicionais conforme prioridade).
- **Gate produção:** obrigação técnica de operação com dados reais, não um elemento visual nem algo dispensável porque o app funciona.
- **Futuro:** conexão bancária automática e aplicações nativas.

**Definições:** *implementado* = código entregue; *testado* = testes automatizados e cenários documentados passando; *homologado* = aceite funcional com evidências; *produção* = sistema publicado e gate aprovado. Não usar os termos como sinônimos.

## 2. Decisões do levantamento

| Domínio | Decisão fechada |
|---|---|
| Perfis iniciais | Admin separado, Luck, Bia |
| Autorizações | leitura/criação/edição/cancelamento por vínculo, configuradas pelo Admin |
| Consolidação | indivíduo e núcleo familiar, sem divisão automática 50/50 |
| Carteiras | várias contas e cartões, propriedade por usuário |
| Cartão | dia de fechamento e vencimento individuais; parcelas futuras geradas automaticamente |
| Lançamento | valor, descrição, categoria, cartão/conta/meio, data, hora, titular, parcelas, observação, anexo |
| Localização | manual e GPS opcional com consentimento por uso |
| Recorrências | geração, edição, pausa e cancelamento |
| Pagamentos | pendente, pago, atrasado, parcial |
| Metas | economia, objetivo, limite de gasto, quitação de dívidas |
| Metas de acumulação | aportes **manuais**, ainda que originados de movimentações identificadas |
| Categorização | taxonomia inicial editável |
| Histórico | seis meses, via importação assistida com prévia e aprovação |
| Importações | CSV, XLSX, OFX, PDF, imagens (por marcos) |
| IA | híbrida: regras determinísticas antes de serviço externo; sugestões revisáveis |
| BI | fluxo, categorias, cartões, histórico, projeção, metas, recorrências, ranking |
| Exportações | Excel e PDF |
| Alertas | vencimentos, limites, metas, anomalias; central e push PWA |
| Mobile | PWA com inclusão de despesas offline e sincronização ao reconectar/abrir |
| Saldo inicial | lançamento de abertura informado manualmente por conta e data |
| Parcelamento corrigido | ajustes controlados, jamais reescrever fatura liquidada |
| Estorno | vinculado à despesa original, com parcial permitido |
| Exclusão | cancelamento lógico auditável |
| Gestão de arquivos | importar, processar e excluir fonte temporária conforme política; anexos de despesas são outra categoria com política específica |
| Ambientes | separados desenvolvimento e produção |
| Custos | mínimo viável, serviços gratuitos onde suficientes |
| Backups | diário automático externo + restauração testada |
| Acesso | e-mail/senha; MFA obrigatório Admin e opcional para financeiros |
| Design | fusão Fluvi + Broto, cor e dinamismo; marca provisória |

## 3. Identidade visual e UX

### 3.1 Conceito

**Nome de trabalho:** Fluvi. **Tagline:** “Seu dinheiro em movimento. Seus planos em crescimento.” O visual une fluidez e transparência financeira (Fluvi) com progresso, conquistas e vida familiar (Broto). Não representar esta marca como juridicamente disponível até pesquisa e decisão específica.

**Paleta inicial de design tokens:** `--brand-blue:#1266B1`, `--brand-teal:#0D9488`, `--growth-green:#31966D`, `--attention-amber:#E9A23B`, `--canvas:#F5FAF7`, `--danger:#C2414C`, `--ink:#17343B`. Tokens claros/escuros precisam cumprir contraste WCAG 2.2 AA. Verde em indicadores positivos; vermelho reservado a vencimentos/limites críticos ou valores negativos, não como cor exclusiva de despesas. Não codificar estados exclusivamente por cor.

### 3.2 Desktop

Sidebar: Início, Lançamentos, Contas, Cartões e Faturas, Recorrências, Metas, Relatórios, Importações, Alertas, Configurações e Perfil. Admin possui navegação própria: Usuários, Núcleos/Vínculos, Permissões, Auditoria e Operação. Nunca compartilhar página financeira do Admin sem permissão explícita. Topo com período, usuário(s) autorizado(s), saldo, ação Novo lançamento.

### 3.3 Mobile/PWA

Barra inferior com Início, Lançamentos, botão destacado `+`, Metas, Menu; demais módulos no menu. Tela de novo lançamento mantém todos os campos selecionados, agrupados em **Principal** (valor, descrição, categoria, conta/cartão), **Detalhes** (data, hora, titular, parcelas), **Adicionais** (localização, observação, anexo). Campos presentes no mesmo fluxo, com defaults confiáveis e acessibilidade; não eliminar campos. Data/hora preenchidas pelo dispositivo, mas editáveis. Proibir localização automática sem ação/permissão do usuário. Mostrar claramente *pendente de sincronização*, *sincronizando*, *salvo* e *conflito*.

### 3.4 Acessibilidade e responsividade

Mínimo de 360 CSS px sem overflow global; testar 360/390/412/768/1440, texto ampliado, teclado, foco, leitor de telas, contraste, validação de campos, estados vazios e tabelas colapsáveis. Preferência reduzida de movimento respeitada. PWA com manifest, service worker restrito, ícones próprios aprovados; cachear shell estático, **não** respostas financeiras, tokens, faturas, imagens pessoais ou URLs assinadas.

## 4. Arquitetura normativa

- **Frontend:** React + TypeScript + Vite, SPA na Cloudflare Pages, gerenciamento de estado e cache consciente de sessão.
- **Monorepo:** pnpm workspaces com lockfile único, `apps/web`, `packages/domain`, `packages/data`, `packages/ui` (somente se reutilização justificar), `supabase/migrations`, `supabase/functions`, `supabase/tests`, `scripts`, `docs`.
- **Supabase:** PostgreSQL, Auth, Storage privado, Edge Functions e mecanismos de agendamento suportados no plano contratado. Segredos apenas no servidor/Vault.
- **Financeiro:** operações multirregistro (pagamentos, faturas, estornos, transferências, metas) por transações PostgreSQL/RPC ou função server-side que invoca operação transacional. Não atualizar saldo e lançamento em chamadas separadas do browser.
- **Offline:** IndexedDB com fila local criptografada quando solução apropriada e comprovada; não presumir que criptografia local garante confidencialidade se a chave estiver acessível no cliente. Armazenar mínimo estritamente necessário, evitar documentos e tokens na fila. UI explica risco de perda antes da sincronização.
- **IA:** interface `FinancialAIProvider` desacoplada; classificação baseada em regras e estabelecimentos conhecidos no núcleo do produto. API externa somente atrás de Edge Function, controles de custo, consentimento e minimização.
- **Jobs:** agendador para recorrências, alertas, lembretes, expurgo de arquivos, backups/monitoramento, com idempotência e logs. Verificar cotas e disponibilidade efetiva antes da configuração.
- **Ambientes:** Supabase e Pages próprios de desenvolvimento e produção; sem dados reais em testes/seed; migrations idênticas e releases promovidas com CI. Estabelecer preview/development sem abrir autenticação real em origem não autorizada.
- **Ferramentas:** Node 24.19.0 permanece candidato herdado da v1.0, condicionado a `node --version`, build e CI; pnpm **12.8.1** é a versão adotada conforme relato de implementação (A1), ainda a verificar em ambiente e CI. Fixar `packageManager`/lockfile e comandos na versão comprovadamente utilizada; registrar compatibilidade antes de homologar. Não usar `latest` nem múltiplos lockfiles.

### 4.1 Estrutura do repositório: existente vs planejada

**Conforme relato da entrega 1 (não inspecionado independentemente):** `tests/` é pacote do workspace denominado `@fluvi/tests`, com `tests/integration/`; existe `docs/matriz-rls.md`. Ainda **não existem** `apps/web`, `packages/domain` e `packages/data`, nem há evidência de `tests/unit`, `tests/e2e` e dos demais caminhos sugeridos. O Marco A não pode ser declarado completo pela existência de diretórios futuros.

```text
fluvi/
  tests/                     # informado como existente: workspace @fluvi/tests
    integration/             # informado como existente
  docs/
    matriz-rls.md            # informado como existente
  supabase/                 # migrações/RPCs informadas; conferir subpastas no inventário real
  apps/web/                 # PLANEJADO, ainda não criado
  packages/domain/          # PLANEJADO, ainda não criado
  packages/data/            # PLANEJADO, ainda não criado
  tests/unit/               # PLANEJADO
  tests/e2e/                # PLANEJADO
  docs/evidencias/          # PLANEJADO
```

Conservar `@fluvi/tests` como pacote e organizar testes unitários/E2E dentro dele ou em pacotes explicitamente definidos, sem supor que sua localização física esteja validada. Depois da criação das pastas, atualizar inventário e comandos CI.

### 4.2 Baseline de ferramentas informado (A1–A2)

| Ferramenta | Versão relatada | Condição de aceite |
|---|---|---|
| pnpm | 12.8.1 | Confirmar instalação, `packageManager`, lockfile e execução na CI; substitui candidata 10.33.4 |
| Node | 24.19.0 (referência anterior) | Confirmar versão efetivamente usada e compatibilidade com pnpm 12.8.1 |
| Supabase CLI | 2.118.0 | Documentar comando e conferir migrações/testes locais |
| PostgreSQL | 17.6, imagem local | Confirmar versão **e compatibilidade de extensões** dos projetos remotos, não assumir que é idêntica |
| supabase-js | 2.117.2 | Registrar lockfile/resolução do pacote |
| Vitest | 5.0.2 | Testes executados na versão exata |
| pg | 8.23.0 | Apenas dependência de testes, não adicionar ao bundle frontend |

Versões e data de publicação informadas pelo executor não são atestado independente de disponibilidade, suporte ou segurança. Se houver incompatibilidade com Node ou registry, registrar a causa e propor alteração versionada, sem falsificar CI verde.

## 5. Identidades, núcleo financeiro e permissões

### 5.1 Modelo de acesso

Há três contas iniciais: Admin (administração apenas), Luck e Bia (usuários financeiros). Um usuário financeiro pertence a um ou mais núcleos, e pode ter carteiras próprias. Núcleo inicial: família Luck/Bia. Um vínculo ao núcleo **não** concede automaticamente leitura integral dos registros dos demais: permissões explícitas, por pessoa titular e operação, controlam consulta, criação, edição e cancelamento. A visão consolidada consulta somente informações às quais a identidade possui autorização.

**Decisão normativa inicial:** visões consolidadas exigem autorização de leitura de cada fonte. Não permitir que valores agregados revelem gastos não autorizados. O Admin configura vínculos e permissões mas não possui acesso financeiro implícito, inclusive por dashboards, exports e consultas SQL expostas. Somente operação de recuperação excepcional, auditada e fora do painel, quando juridicamente/técnicamente justificada.

### 5.2 Matriz

| Ação | Admin | Usuário titular | Usuário vinculado |
|---|---|---|---|
| Criar, bloquear, vincular usuário | Sim | Não | Não |
| Configurar autorizações | Sim | Não | Não |
| Ler sua carteira | Sem direito implícito | Sim | Somente permissão `read` |
| Registrar receita/despesa | Não como Admin | Sim | Somente permissão `create` no titular-alvo |
| Editar/cancelar | Não como Admin | Sim | `update`/`cancel` específicos |
| Ver consolidação | Não por padrão | Apenas origens autorizadas | Apenas origens autorizadas |
| Exportar dados financeiros | Não por padrão | Apenas escopo legível | Apenas escopo legível |
| Ler auditoria de segurança | Conforme função administrativa | Eventos próprios essenciais | Não |

Todas as verificações devem ocorrer no PostgreSQL/RLS e na autorização das Edge Functions; remover um vínculo deve interromper novas leituras mesmo com JWT ainda válido. Permissões jamais originam do `user_metadata` editável.

### 5.3 Autenticação

Cadastro público desativado. Primeiro Admin provisionado manualmente com conta Auth e atribuição de papel em operação privilegiada documentada, sem segredo em scripts. Administrador cria convites de usuários pela interface. **Enviar convite não conclui ativação**: perfil permanece `pending` até aceite e confirmação efetiva, com guarda adicional de ativação se necessária. E-mail/senha, recuperação com canal realmente configurado, confirmação de e-mail e MFA TOTP obrigatório para Admin antes de acesso a operações administrativas. MFA opcional para Luck e Bia. Bloqueio, revogação e senhas não dependem apenas de ocultar botões; proteger ações por estado persistido e AAL. Logs sem senhas, JWT ou documentos.

## 6. Modelo de dados lógico (PostgreSQL)

Em todas as tabelas: UUID como identificador, `created_at`, `updated_at` quando aplicável, integridade referencial, índices nas colunas de busca, timestamps auditáveis e política RLS. Chaves naturais para idempotência. Valores monetários em **centavos inteiros BIGINT** e moeda ISO 4217 (`BRL` inicialmente); limites CHECK, restrições de sinal, e soma de parcelas com distribuição determinística de centavos. É proibido usar float JavaScript para cálculo/armazenamento monetário.

| Grupo | Tabelas previstas e funções |
|---|---|
| Identidade | `profiles(user_id,status,display_name,status_changed_at,activation_completed_at nullable)`, `administrators(user_id,active)`, `households(id,name,active,created_by)`, `household_members(household_id,user_id,status)`, `data_grants(owner_user_id,grantee_user_id,household_id,resource_scope,can_read,can_create,can_update,can_cancel,revision,revoked_at,revoked_by,created_by)`, `admin_operations(operation_id,actor_user_id,operation_type,payload_hash,status,result,created_at)` |
| Categorias | `categories(id,household_id,owner_user_id,parent_id,name,kind,status)`; padrão inicial e personalização por perfil com regras de visibilidade |
| Carteiras | `financial_accounts(id,owner_user_id,household_id,name,type,currency,opening_date,opening_balance_cents,active)`; saldo reconstruível por postings |
| Cartões | `credit_cards(id,owner_user_id,account_id,brand,last_four,credit_limit_cents,closing_day,due_day,active)`, `billing_cycles(id,card_id,starts_on,closes_on,due_on,status,paid_at)` |
| Operações | `transactions(id,owner_user_id,household_id,type,description,merchant_id,category_id,occurred_at,local_date,timezone,status,source,location fields)`, `ledger_entries(id,transaction_id,account_id,amount_cents,kind,posted_at)` |
| Compras e parcelas | `card_purchases(id,transaction_id,card_id,total_cents,installment_count)`, `installments(id,purchase_id,sequence,amount_cents,billing_cycle_id,status)` |
| Liquidações | `obligations(id,owner_user_id,type,due_date,original_amount_cents,status)`, `payments(id,obligation_id,account_id,amount_cents,paid_at,reference)`; suportar parcial e não pagar acima do devido sem regra específica |
| Transferências | `transfers(id,from_account_id,to_account_id,amount_cents,executed_at,status)` e dois postings atômicos, sem duplicar receita/despesa consolidada |
| Recorrências | `recurrence_rules(id,owner_user_id,template,rrule_or_frequency,start_date,end_date,status,revision)`, `recurrence_occurrences(rule_id,period_key,transaction_id,status)` |
| Metas e orçamento | `goals(id,owner_user_id,household_id,type,target_cents,period,start_date,end_date,status)`, `goal_contributions(id,goal_id,amount_cents,effective_at,linked_transfer_id nullable)`, `budgets(id,owner_user_id,category_id,period,limit_cents)` |
| Reembolsos | `refunds(id,original_transaction_id,refund_transaction_id,amount_cents,refunded_at)`; montante total não excede original líquido ainda estornável |
| Importação | `import_batches(id,owner_user_id,format,institution,status,file_key,uploaded_at,approved_at,expires_at)`, `import_rows(id,batch_id,row_number,raw_fingerprint,normalized_fields,confidence,decision,matched_transaction_id)`, `import_links(import_row_id,transaction_id,match_kind)` |
| Offline | `sync_operations(id,owner_user_id,client_operation_id,payload_hash,result_reference,status,received_at)`; `client_operation_id` único por owner |
| Alertas | `notifications(id,user_id,kind,source_id,created_at,read_at,dedupe_key)`, `push_subscriptions(id,user_id,endpoint_hash,endpoint_encrypted,keys_encrypted,active)`, `notification_jobs(...)` |
| Auditoria | `audit_events(id,actor_id,action,entity_type,entity_id,before_digest,after_digest,created_at,request_id)`; sem valores secretos ou cópia integral de documentos |

O esquema acima é **lógico**, não SQL pronto. Claude deve propor e revisar DDL completo, constraints cruzadas, normalização, índices e políticas antes de construir formulários. `ledger_entries` deve representar a verdade de caixa; definir convenção única de sinais, contrapartida e conciliação. Não manter `account_balances` mutável como fonte primária de verdade. Se utilizar projeção materializada de saldo, atualizar transacionalmente e provar que pode ser reconstruída do razão.

**Tabelas agregadas/views de BI:** `v_cashflow_by_month`, `v_consumption_by_month`, `v_card_commitments`, `v_goal_progress`, sempre *security_invoker* ou consultas/funcões que preservem permissões. Não expor views security-definer que contornem RLS inadvertidamente.

## 7. Regras financeiras normativas e casos de cálculo

### 7.1 Dimensões temporais

Todo lançamento distingue `occurred_at` (instante ou data do fato), `competence_month` (período de consumo), `due_date` (vencimento) e `paid_at` (liquidação real) quando aplicável. Persistir `occurred_at` em UTC, preservar `local_date` e timezone de origem quando necessária; datas sem horário são DATE, nunca converter artificialmente entre fusos. Padrão America/Sao_Paulo. Agrupar por competência **explicitamente escolhida** no relatório, não por `created_at`.

### 7.2 Compras no crédito e faturas

Exemplo A: compra em 20/10 de R$ 1.200,00 dividida em 6 parcelas → seis parcelas de R$ 200,00. É **uma compra de consumo** de R$ 1.200 em outubro na visão de compras, **seis obrigações** de R$ 200 por ciclo na visão de comprometimento, e saídas reais somente ao pagar as faturas na visão de caixa. Pagar uma fatura de R$ 200 reduz banco em R$ 200 e dívida do cartão em R$ 200; **não** soma mais R$ 200 ao consumo.

Fechamento/vencimento por cartão. Ciclos materializados com data inicial/final e data de vencimento calculadas por regra documentada. Para dias 29/30/31 inexistentes, ajustar ao último dia do mês, registrando regra. Mudança de fechamento/vencimento afeta somente ciclos futuros não fechados; ciclos fechados/pagos mantêm datas históricas. Para compras perto do fechamento, a data efetiva da instituição importada prevalece mediante conciliação aprovada; não afirmar infalibilidade do cálculo estimado.

Parcelamento em centavos: distribuir quociente inteiro por parcela e alocar resto determinístico às primeiras parcelas; soma = valor total exato. Alterar quantidade/valor só em parcelas futuras abertas, com revisão/auditoria; nunca reescrever parcela de ciclo liquidado. Parcelas antecipadas, juros e renegociação não entram no primeiro fluxo, mas modelo permite ajustes explícitos e documentados em evolução.

### 7.3 Saldos iniciais

Cada conta recebe um `opening_balance_cents` e uma `opening_date`. A projeção de saldo em data D equivale a abertura + postings posteriores à data de corte e até D. O saldo de abertura não é receita e não entra na taxa de economia. Importar seis meses anteriores ao corte permite histórico de consumo, mas **não altera saldo atual** sem conciliação validada. Permitir conferir saldo informado x extrato reconciliado e registrar diferenças; nunca inventar movimentação compensatória automática.

### 7.4 Pagamentos

Status de obrigação é derivado: `pendente` (saldo restante > 0 e ainda no prazo), `atrasado` (saldo > 0 e vencimento passado), `parcial` (já existe liquidação, saldo > 0; também pode estar atrasado), `pago` (restante = 0). Preferir dois atributos independentes `settlement_status` e `is_overdue` para evitar ambiguidade do parcial atrasado. Valor a pagar = valor devido + ajustes autorizados − soma de pagamentos líquidos. Um pagamento parcial afeta caixa no instante efetivo e reduz a dívida correspondente, sem duplicar despesa.

### 7.5 Transferência entre contas e entre usuários

Uma transferência entre contas do mesmo indivíduo ou entre usuários vinculados é duas movimentações financeiras correlacionadas. Em consolidado que inclui ambas as contas, entrada e saída se anulam; não representam receita ou despesa. Se a origem/destino não está no escopo autorizado, mostrar apenas a ponta visível, sem revelar identidade ou saldo protegido do terceiro. Proibir transferências inconsistentes ou parcialmente aplicadas.

### 7.6 Estornos/reembolsos

Estorno de R$ 100 sobre compra de R$ 300 → consumo líquido atribuído à compra = R$ 200. Estorno parcial ligado à origem, `refunds` com referência explícita e limite acumulado ≤ valor original elegível. Crédito em fatura reduz obrigação; reembolso em conta gera entrada de caixa **classificada como recuperação de gasto**, não receita operacional. Não apagar compra original; dashboards devem permitir bruto, estornos e líquido.

### 7.7 Cancelamento lógico

`cancelled_at`, `cancelled_by`, `cancel_reason`; lançamentos cancelados deixam visões ativas, mas permanecem em auditoria. Cancelamento de operação liquidada ou conciliada exige **reversão/estorno contábil explícito**, não simplesmente ocultar a saída bancária já ocorrida. Importações e sync repetidos não ressuscitam cancelamento. Usuário com `cancel` pode cancelar operações elegíveis, sem hard delete no frontend.

### 7.8 Recorrências

Regra (aluguel, assinatura, salário etc.) cria ocorrência por período com UNIQUE(rule_id, period_key). Próxima ocorrência gerada server-side por job idempotente, não `setTimeout` do navegador. Editar permite `esta ocorrência` ou `ocorrências futuras`; alteração da regra gera `revision` e nunca reescreve movimentos liquidados. Pausar impede futuras gerações; cancelar preserva histórico. Rendimentos futuros são previsão, não receita realizada, até a liquidação ou confirmação conforme tipo.

### 7.9 Metas

- **Economia/objetivo:** `progress = SUM(contributions)` dos aportes manuais válidos, menos retiradas/reversões; percentual = clamp(progress / target * 100), e exibir excedente quando > 100%. Contribuição não é despesa por si só. Se associada a transferência para conta-reserva, contar apenas uma vez.
- **Limite de gasto:** `used = SUM(net_consumption)` na categoria/período/escopo, deduzidos estornos elegíveis; percentual de utilização = used / limite. Orçamentos são limites, não metas de acumulação.
- **Dívida:** progresso = (saldo inicial da dívida − saldo devedor atual) / saldo inicial, contemplando juros/ajustes explicitamente; pagamentos não podem ser contados como novo consumo. Permitir correções auditadas.
- Definir comportamento para metas encerradas, reabertas, alteradas e parcialmente revertidas.

### 7.10 BI: dicionário mínimo de métricas

| Métrica | Regra de cálculo | Cuidados |
|---|---|---|
| Receita realizada | somatório das receitas liquidadas no período de caixa | não contar transferências internas, estornos como salários ou saldo de abertura |
| Despesa de consumo líquida | soma de compras/despesas elegíveis menos estornos vinculados por competência | não somar pagamento de fatura como novo consumo |
| Saída de caixa | soma dos postings de saída real de contas no período | transferência interna requer eliminação no consolidado |
| Saldo bancário | saldo de abertura + entradas/saídas liquidadas | reconciliação por conta e data de corte |
| Fluxo líquido | entradas externas − saídas externas liquidadas | diferenciar visão individual de consolidada |
| Taxa de economia | (receita operacional realizada − despesas relevantes realizadas) / receita operacional realizada | definir explicitamente base contábil, tratar divisor zero, não misturar competência e caixa |
| Limite de cartão usado | obrigações de crédito em aberto por cartão / limite cadastrado | cartão compartilhado e ciclos devem ser deduplicados |
| Comprometimento futuro | obrigações previstas / receita prevista elegível do período | mostrar que é projeção, não caixa confirmado |
| Variação mensal | (mês atual − anterior) / |anterior|, quando comparável | divisor 0 → “sem base”, não infinito |
| Despesa recorrente | soma de ocorrências recorrentes elegíveis por período | separar previstas das pagas |

Cada indicador tem `metric_id`, definição matemática, base temporal, filtros válidos, formato, tratamento de ausência de dados, versionamento da regra e teste de referência. Gráficos não devem consultar dados de usuários sem permissão nem usar IA para inventar números.

## 8. Módulos funcionais e critérios de aceite

### FIN-01 Login e painel administrativo (M-A)

Admin provisona Luck/Bia via convites reais, gerencia status/vínculos/grants; sem signup público. Login e-mail/senha, recuperação verificável, MFA Admin, sessão protegida. RLS por titular/grant. **Aceite:** Luck não lê Bia sem autorização; depois do grant lê apenas escopo concedido; revogação impede imediatamente novas consultas; Admin sem grant não lê linhas financeiras; cliente não altera grant pela API.

### FIN-02 Contas financeiras (M-B)

Cadastrar conta de banco, carteira/dinheiro, saldo inicial, titular, descrição, status. Visões: saldo, movimentos, conciliação. **Aceite:** início com R$ 1.000 em 01/10 e despesa de R$ 70 em 02/10 resulta R$ 930; abertura não é receita; movimento anterior ao corte não altera R$ 930.

### FIN-03 Cartões e faturas (M-B)

Cadastro por titular, bandeira opcional, identificação mascarada, limite, fechamento e vencimento. Exibir ciclos, compras, parcelas e faturas, status de fechamento/pagamento; não guardar PAN completo/CVV. **Aceite:** compra parcelada entra no ciclo correto; distribuição exata de centavos; pagamento de fatura afeta caixa e passivo, não gasto duplicado.

### FIN-04 Lançamentos manuais (M-B/M-C)

Criar receita, despesa, transferência, compra parcelada; valor obrigatório > 0, descrição, categoria, conta/meio, data/hora, titular, parcelas, observação e anexo opcionais. Para meio crédito, selecionar cartão e ciclo estimado; para débito/Pix/dinheiro, conta de origem. Geolocalização opcional e removível. Editar/cancelar por permissão. **Aceite:** lançamento visto em outro dispositivo; ausência de usuário/titular não inferida quando Admin ou grant; tentativa de usar conta de terceiro negada.

### FIN-05 Pagamentos e recorrências (M-B)

Registrar pagamentos completos/parciais, vencimentos, edição/pause de recorrências e histórico. **Aceite:** R$ 500 devido e R$ 200 pago → R$ 300 restante, parcial; ultrapassar vencimento sinaliza atraso mesmo parcial; job repetido não duplica ocorrência.

### FIN-06 Metas (M-D)

Cadastrar quatro tipos, aportes manuais e histórico de evolução; limites vinculados ao consumo da categoria. **Aceite:** meta R$ 5.000 recebe R$ 500 e depois R$ 200 → 14%; limite R$ 1.000 com gasto líquido R$ 850 → 85%; cancelar aporte atualiza resultado e trilha.

### FIN-07 Dashboard e relatórios (M-D)

Desktop traz cartões: receitas, consumo, caixa, faturas, obrigações, metas, evolução e alertas. Gráficos por competência e caixa com rótulos distintos. Filtros: mês/ano/período, pessoa autorizada, cartão/conta, categoria/estabelecimento, forma e situação. Mobile exibe resumo simplificado sem omitir indicadores acessíveis pelo menu. **Aceite:** soma de totais em dashboard = consulta de referência por mesmo escopo; filtros não vazam dados.

### FIN-08 Importação estruturada (M-D)

Suportar CSV, XLSX e OFX: upload privado; validação de tamanho/tipo, parser seguro; seleção de instituição/layout/mapa de colunas; prévia com amostras e erros; matching com lançamentos existentes; categorização sugerida; aprovação de itens/inteiro lote; importação transacional por lote e idempotência. Não presumir um layout universal. **Aceite:** reimportar mesmo arquivo não gera duplicatas; compras distintas de mesmo valor/data não são fundidas sem revisão; erro parcial permite retomar sem perder decisões.

### FIN-09 Importação avançada e IA (M-E)

PDF textual, PDF digitalizado e imagem/recibo com adaptadores. OCR/serviço de visão apenas quando necessário e autorizado. IA fornece `{extracted_fields, suggested_category, confidence, evidence}` estruturados, não valores financeiros finais sem revisão. Prompt-injection em documento é tratado como conteúdo não confiável; nunca executar instruções de uma fatura. Limitar custo por usuário/lote, retries e tokens. Excluir original temporário após prazo aprovado; preservar hashes, proveniência, versão do parser, itens normalizados e aprovações. **Aceite:** PDF não legível sinalizado sem lançamento; categorias erradas corrigíveis; dados de Bia não enviados à IA sob contexto de Luck sem permissão.

### FIN-10 PWA offline (M-C)

Depois de autenticação online inicial válida, permitir criar despesas locais (sem anexo online obrigatório), com fila IndexedDB, `client_operation_id` UUID, hash canônico, owner id, versão de schema e timestamps. Não permitir selecionar titular de outro usuário sem grant previamente validado e revalidado online. Sincronizar ao evento de reconexão e abertura, além de botão manual de reenvio; tratar 401/403, conflitos, alterações de grant e schema. Exigir autenticação/revalidação quando conexão volta antes do commit. Não garantir execução em segundo plano com app fechado. Logout bloqueia acesso aos rascunhos daquela sessão, limpa dados privados em cache e oferece escolha segura de descartar/exportar pendências; não permitir troca de conta visualizar fila anterior. **Aceite:** repetir 10 retries gera um lançamento; remoção de grant impede envio; falta de rede não mostra “salvo no servidor”.

### FIN-11 Alertas/push (M-E)

Centro de alertas com visto/não visto, preferências, dedupe. Regras: lembrete de vencimento configurable, consumo de 80/90/100% do limite por categoria/cartão, meta atingida, anomalia estatística revisável. Push Web requer PWA instalada na tela inicial e permissão explícita no iPhone compatível; sem garantia de entrega. Servidor envia mensagem curta sem valores sensíveis na tela bloqueada por padrão; abrir link exige sessão e autorização. **Aceite:** mesmo evento não cria dez pushes por retries; usuário revogado não recebe detalhes.

### FIN-12 Exportação (M-E)

Gerar XLSX e PDF a partir de dados filtrados e autorizados; título, período, usuário(s), filtros, data/hora e método de cálculo. Segurança contra CSV/Excel formula injection em células textuais. Logs auditam exportação sem conteúdo financeiro. **Aceite:** export PDF/XLSX reproduz totais da tela; alteração de ID do usuário retorna 403.

## 9. Importação, duplicidade e conciliação

Fluxo obrigatório: **upload → quarantine → extração → normalização → classificação/matching → prévia → aprovação explícita → commit → relatório de importação → expurgo da fonte**.

- Importação nunca grava despesa definitiva na etapa de prévia.
- Hash do arquivo identifica repetição de lote; fingerprint por linha combina fonte/instituição/identificador externo quando disponível e atributos normalizados. Mesmo dia/valor/estabelecimento não é prova suficiente de duplicação.
- Criar estados `new`, `possible_match`, `confirmed_match`, `ignored`, `error`; usuário pode decidir linha a linha e desfazer até o commit.
- O lote inclui data de competência, data de transação, descrição original e padronizada, moeda, valor e conta/cartão alvo.
- Em extrato de cartão, pagamento de fatura identificado como pagamento, não como compra. Evitar que importação de conta e de cartão gerem duplicação econômica.
- Versionar mapeamentos de instituição e parser; testes de regressão com arquivos fictícios e amostras autorizadas. Nunca codificar credenciais bancárias no parser.
- PDF/imagem: texto potencialmente confidencial; processar no servidor com proteção de arquivo, limite de páginas, tamanho, tempo e custo; fallback manual.
- Descarte temporário: política proposta `expires_at` em até 7 dias da conclusão/erro, revisável pelo responsável. Delete também bytes de storage; arquivos de comprovantes mantidos conscientemente pelo usuário seguem retenção distinta, a formalizar no gate LGPD.

## 10. Segurança, privacidade e prontidão com dados reais

### 10.1 Indispensável no gate

1. Auth real, recuperação funcional, MFA Admin, política de senha e bloqueio, rate limiting nas funções sensíveis; nunca depender só da UI.
2. RLS em toda tabela exposta, grants SQL mínimos; negativas testadas como anon, Luck, Bia, Admin, revogado e usuário de outro núcleo.
3. Chaves/segredos fora do bundle, CI, logs e capturas; `service_role` apenas servidor. Revisão de dependências, cabeçalhos de segurança (CSP validada, HSTS quando domínio apropriado, `nosniff`, frame-ancestors, referrer-policy) e CORS.
4. Storage privado, links expirados, validação de MIME/assinatura de arquivo, tamanho e segurança de anexos; nenhuma URL assinada em logs.
5. Backups automáticos diários de **banco e bytes de anexos/documentos retidos**, cópias fora do projeto Supabase e plano de criptografia/acesso; teste de restauração isolada antes de dados reais e recorrente depois. Plano Free não deve ser assumido como backup automático gerenciado.
6. Recuperação de conta, expiração de sessão e revogação comprovadas; impedir Admin AAL1 de administrar.
7. Auditoria de criação, alteração, cancelamento, grants, importações, pagamentos e exportações, sem expor segredos. Retenção e expurgo aprovados.
8. Política de privacidade e acesso de titulares, minimização de geolocalização, autorização de envio a serviço externo de IA e avaliação de provedores/transferências de dados. Definir responsável pela operação e incidente.
9. Monitoring externo mínimo (disponibilidade, erros de backend, jobs, backup atrasado) e canal real de alerta. Sem afirmar suporte 24x7 se não contratado.
10. Homologação dos casos matemáticos e limites, inclusive estorno/transferência/fatura, antes de uso real.

**Política de segurança offline:** offline contém risco residual de exposição/perda local. Se não houver proteção viável satisfatória no iPhone, lançar sem offline com dados reais e manter FIN-10 como bloqueado até homologação, em vez de enfraquecer a proteção do projeto todo.

### 10.2 Separação operacional

Admin não visualiza dados privados por padrão. Operação de suporte não deve aceitar `user_id` enviado pelo navegador como fonte única de autorização. Cada objeto privado tem owner e contexto verificável. Na restauração de backup, revalidar exclusões, grants, auth e storage; ambiente restaurado não envia push/e-mails reais inadvertidamente.

## 11. Contratos de API/operações

A UI pode usar SDK Supabase para consultas simples **somente com RLS validado**. Operações críticas devem ter funções específicas, entradas validadas por schema e retornos estáveis:

| Operação | Responsabilidade | Idempotência |
|---|---|---|
| `provision-user` | Admin cria conta/invite/grants aprovados; `admin_operations` controla retomada segura e resposta de operação | `operation_id` + hash do payload |
| `admin_set_data_grant` (RPC) | Admin altera autorização, revogação e `revision` transacionalmente; não exige Edge Function intermediária | `operation_id` + revisão esperada |
| `create-transaction` | validar owner, categoria, conta, saldo e origem; grava transação/postings atômicos | `client_operation_id` |
| `create-card-purchase` | criar compra, parcelas e associação de ciclos atomicamente | `operation_id` |
| `settle-obligation` | registrar pagamento parcial/total e movimento de caixa | `payment_request_id` |
| `reverse-transaction` | reversão ou estorno ligado à origem | `reversal_request_id` |
| `transfer-funds` | postings de débito e crédito consistentes | `transfer_request_id` |
| `apply-recurring-occurrences` | criar apenas períodos ainda não criados | `(rule_id,period_key)` |
| `preview-import` | extrair dados sem consolidar | `batch_id` |
| `commit-import` | consolidar decisões revisadas sem duplicar | `(batch_id,approved_revision)` |
| `generate-notifications` | localizar eventos pendentes e gravar centro | `dedupe_key` |
| `send-web-push` | tentar notificação autorizada, registrar resultado | `(notification_id,subscription_id)` |
| `export-financial-report` | calcular dados permitidos e gerar arquivo | `request_id` |

Nenhum nome de endpoint é compromisso de rota física: Claude pode definir RPC/Edge Functions com rotas documentadas mantendo a semântica, autorização e idempotência.

## 12. Plano de execução e marcos

| Marco | Entrega | Prova de aceite |
|---|---|---|
| A — Fundação | Repo, ambientes, migrações, Auth, Admin, Luck, Bia, núcleos e grants, RLS, backup/restauração | Nega acesso cruzado e Admin sem grants; backup restaurado; CI verde |
| B — Operação financeira | Contas, saldos, lançamentos, cartão/fatura, parcelas, pagamento, recorrência, reversões e auditoria | Testes matemáticos e ações entre aparelhos; dados reais só após gate |
| C — Mobile | Design Fluvi/Broto, formulário completo rápido, PWA, fila local, sync, conflitos | iPhone real, offline/reconexão sem duplicações, queda de sessão tratada |
| D — Inteligência analítica básica | Categorias, metas, BI e CSV/XLSX/OFX com prévia e aprovação | Seis meses históricos conciliados, dashboards batem com dataset-oráculo |
| E — Evoluções funcionais | PDF/imagens/OCR, IA externa opcional, anomalias, push, Excel/PDF export | Aceites por módulo, custos autorizados, validação de push em aparelho |
| Futuro | Open Finance/integração bancária e app nativo | Novo assessment de provedor, requisitos regulatórios, custo e autorização |

**Gate produção:** deve ser realizado para o escopo liberado *antes* de usar dados reais, não necessariamente após completar A-E. Se A não cobre ainda restauração, monitoramento, recuperação de conta e políticas essenciais, permanecer em ambiente fictício. A separação de ambientes não transforma preview em ambiente de produção.

## 13. Matriz de testes e dataset-oráculo

Ferramentas propostas: Vitest para domínio; pgTAP/Supabase CLI para RLS/SQL; testes de integração com Supabase local e Edge Functions; Playwright para web; Safari em iPhone real para PWA/push; CI com migrações e seeds fictícios. Comandos do workspace devem ser definidos e documentados sem fingir que já executaram.

| Cenário | Entrada | Resultado esperado |
|---|---|---|
| Saldo | Abertura R$1.000 em 01/10; gasto à vista R$70 em 02/10 | Saldo R$930; abertura excluída de receitas |
| Parcelas | R$1.200 em 6x | 6 × R$200, soma R$1.200, uma compra original |
| Centavos | R$100 dividido em 3x | R$33,34 + R$33,33 + R$33,33 (ou distribuição documentada e equivalente) |
| Pagamento de fatura | Fatura R$200, pagamento R$200 | Caixa −R$200; dívida cartão −R$200; sem consumo duplicado |
| Parcial | Obrigação R$500, paga R$200 | Restante R$300; status parcial; overdue independente |
| Estorno | Compra R$300, estorno R$100 | Consumo líquido R$200; estorno não é salário |
| Meta economia | Alvo R$5.000; aportes 500 + 200 | R$700, progresso 14% |
| Limite | R$1.000, consumo líquido R$850 | 85% utilização |
| Transferência interna | R$100 A→B | Saldo A −100, B +100; consolidado não gera receita/despesa |
| Import repetido | Importar mesmo lote duas vezes | Uma operação final por linha aprovada, sem duplicação |
| Offline repetido | Reenviar mesma operação 10 vezes | Um lançamento confirmado |
| Cancelar liquidado | Cancelar pagamento conciliado | Exigir reversão atômica/auditada, não apagar caixa |
| Autorização | Luck sem grant tenta acessar Bia | 403/negação no banco e na função; inclusive exports |
| Admin | Admin sem grant tenta exportar finanças | Negado |
| Regras futuras | Corrigir dia de vencimento de cartão com fatura paga | Fatura paga imutável; só futuros ciclos elegíveis recalculados |
| Recorrência | Executar mesmo job duas vezes | Uma ocorrência por regra/período |
| PWA | Offline, fechar/reabrir, reconectar | Pendência preservada quando storage continua; servidor não recebe duplicata |

Além disso: testes de alteração de autorização com token ainda válido; upload malicioso; anexos de outro usuário; simultaneidade de pagamentos; valores negativos/overflow; datas 28/29/30/31 e ano bissexto; cache privado; estado vazio; overflow em 360px; links deep-link sem autorização; troca de conta com rascunho offline; falha de backup e restauração. Guardar evidências sanitizadas com commit, ambiente, hora, resultado e lacunas.

## 14. Backups, custos e dependências

**Sem habilitar cobrança automática.** Antes de implantar, Claude deve apresentar uma tabela de fornecedores/cotas/custos/risco operacional com dados atuais validados, diferenciando custos estimados de contratados. O Supabase Free não deve ser apresentado como solução de backups gerenciados de produção. Backup próprio precisa de agendamento **confiável**, armazenamento externo, retenção, monitoramento e teste de restauração. A política mínima de projeto é **diário**, retenção e RPO/RTO a serem formalizados como premissas conservadoras no procedimento de produção. Se não houver destino externo ou mecanismo de recuperação comprovado, bloquear uso real.

A IA pode ser desligada por feature flag sem quebrar lançamento, importações estruturadas ou BI. Toda chamada externa mede quantidade/tamanho, limite por lote/mês, erro, consumo estimado, consentimento e tempo de retenção; não registrar payload sensível em telemetria. Não contratar domínio, plano, e-mail ou provedor de IA sem ação autorizada pelo responsável.

## 15. Decisões de implementação delegadas ao Claude (sem alterar escopo)

Claude deve propor e justificar: biblioteca UI, parser OFX/CSV/XLSX, biblioteca de gráficos, esquema de cache/IndexedDB, modelo ledger exato, fórmulas SQL consolidadas, estratégia de job, provider de Web Push, versões compatíveis de ferramentas e organização de componentes. Não pode delegar ao modelo decisões de autorização, duplicação, competência, pagamentos, persistência de backup ou silêncio de erros.

Parâmetros a cadastrar no ambiente, não lacunas de análise: e-mails iniciais, nomes de bancos/cartões, closing/due days reais, contas/saldos/data de abertura, configuração efetiva dos grants Luck/Bia, destino e retenção de backup, uso de IA, chave de domínio e marca final. Nunca semear saldos ou cartões reais fictícios em produção.

## 16. Checklist de aceite da v1.1

- [ ] Documento, DDL, dicionário de métricas, endpoints e matriz RLS revisados antes do frontend.
- [ ] Modelo do dinheiro em centavos e ledger conciliável testado.
- [ ] Permissões isolam titulares, núcleo, Admin e arquivo privados.
- [ ] Regras de faturas, parcelas, estorno, metas e recorrência têm testes-oráculo.
- [ ] Criação, atualização, cancelamento, pagamentos e transferências são transacionais e auditados.
- [ ] App responsivo sem overflow crítico; cadastro completo e rápido em iPhone.
- [ ] Offline sem duplicidade e sem alegar salvar no servidor quando pendente.
- [ ] Importação exige prévia e aprovação, com conciliação e expurgo do arquivo.
- [ ] Dashboards distinguem compra/consumo, compromisso e fluxo de caixa.
- [ ] Backup externo/restauração e recuperação de conta aprovados antes de uso real.
- [ ] Push funciona apenas sob permissão e limitações da plataforma, central persiste independentemente.
- [ ] Critérios por marco comprovados por evidências e documentação; nenhuma etapa marcada pronta apenas por geração de código.

## 17. Prompt de execução para Claude

> Você é responsável por implementar **Fluvi — Gestão Financeira Pessoal e Familiar**, de acordo com a Especificação Técnica e Funcional v1.1 anexada. Essa especificação tem precedência; o documento Portal do Cliente Luis Fronterotta v1.4 é apenas referência de arquitetura, disciplina de segurança, testes, serviços Supabase/Cloudflare e entrega por marcos, não fonte para copiar telas/regras de negócio. Não misture escopos.
>
> Primeiro produza uma análise técnica e inventário do repositório, plano de marcos, decisões arquiteturais (ADRs), modelo lógico/físico, DDL/migrations, RLS e contratos de operações. Apresente o dicionário de métricas com casos de teste. Depois implemente **Marco A**, preserve as RPCs e migrações informadas, valide os ajustes da v1.1, prove isolamento real entre Admin/Luck/Bia e execute teste de backup/restauração em ambiente fictício. Só avance ao marco seguinte com evidências de aceite.
>
> Stack: React/TypeScript/Vite + Cloudflare Pages + Supabase PostgreSQL/Auth/Storage/Edge Functions + pnpm workspaces. Respeite frontend sem segredos e dados privados sem cache indevido. Valores monetários em centavos BIGINT, operações críticas transacionais, RLS em toda tabela exposta e vistas sem bypass. Nunca use `service_role` no browser ou desative RLS para contornar erros.
>
> Construa operação financeira com cartões, ciclos de faturas, parcelas, contas, pagamentos parciais, estornos vinculados, metas e BI, todos com testes de cálculo. Importações sempre exibem prévia e aprovação. PWA instala no iPhone e permite lançar offline de forma idempotente; não prometa sincronização no background quando o navegador estiver fechado. IA é híbrida, opcional e controlada por custo. Push não substitui centro de alertas.
>
> Não aplique alterações irreversíveis, contrate serviços, exponha dados pessoais nem publique produção sem autorização explícita. Para contas/cotação/segredos indisponíveis, documente a dependência e continue com fixtures fictícias isoladas; nunca use simulação como evidência de serviço real. Entregue README iniciante, CI, pgTAP, testes unitários, integração, Playwright, evidências sanitizadas, instruções de deploy, rollback, backup e restauração.
>
> Ao concluir cada marco, informe: o que foi implementado, como testar, resultados efetivamente executados, limitações, decisões pendentes e próximos passos. Não declare produção pronta sem passar todo o gate da seção 10.

## 18. Referências técnicas públicas

- Cloudflare Pages/React: https://developers.cloudflare.com/pages/framework-guides/deploy-a-react-site/
- Supabase RLS: https://supabase.com/docs/guides/database/postgres/row-level-security
- Supabase Auth/MFA: https://supabase.com/docs/guides/auth/auth-mfa
- Supabase database backups: https://supabase.com/docs/guides/platform/backups
- Supabase pricing: https://supabase.com/pricing
- Apple/WebKit Web Push: https://webkit.org/blog/13878/
- Apple Developer Web Push: https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers
- WCAG 2.2: https://www.w3.org/TR/WCAG22/

**Nota de rastreabilidade:** referências técnicas devem ser reconferidas durante implantação; descrições de cotas não são garantia de preços futuros. Esta v1.1 é normativa como especificação de construção, não evidência de execução de testes, custos aprovados, marca registrada ou serviços configurados.


---

## 19. Adendo normativo — revisão da entrega 1 do Marco A (15/10/2026)

**Precedência:** este adendo modifica e detalha as seções 4, 5, 6, 10, 11, 12, 13, 16 e 17. Havendo divergência, vale a regra mais específica da seção 19. Não modifica funcionalidades financeiras, PWA ou BI dos marcos posteriores. **Fonte dos estados de implementação:** relatório textual do responsável, sem leitura do repositório, testes, migrations, configurações hospedadas ou registros de CI nesta revisão.

### 19.1 Registro de decisões A, B e C

| Código | Deliberação | Efeito normativo / evidência pendente |
|---|---|---|
| A1 | **ACEITAR** | pnpm 12.8.1 substitui candidata 10.33.4; verificar instalação, lockfile e CI |
| A2 | **ACEITAR** | Registrar Supabase CLI 2.118.0, PostgreSQL local 17.6, supabase-js 2.117.2, Vitest 5.0.2, pg 8.23.0 só em testes; confirmar versões remotas |
| A3 | **ACEITAR** | `@fluvi/tests`, `tests/integration`, `docs/matriz-rls.md` informados; apps/packages ainda não criados |
| A4 | **ACEITAR** | RPC `admin_set_data_grant` e demais RPCs catalogadas na 19.3; verificar grants/identidade do chamador |
| A5 | **ACEITAR** | `admin_operations`, colunas extras de grants, households/profiles incorporadas ao modelo lógico |
| B1 | **ACEITAR** | Bloqueio de titular impede que qualquer beneficiário continue lendo dados desse titular; testar com sessão pré-existente |
| B2 | **ACEITAR** | UPDATE/CANCEL exigem READ; CREATE sem READ permitido, sem retornar detalhes de contas/lançamentos existentes em payload, erro ou efeito lateral |
| B3 | **ACEITAR** | Suspensão/remoção de membership torna grants dependentes imediatamente ineficazes; revogação registrada atomicamente |
| B4 | **ACEITAR** | Membros ativos veem só `display_name` de outros membros ativos do mesmo núcleo para seletor; nunca e-mail/Admin/outros núcleos |
| B5 | **ACEITAR** | Titular e beneficiário podem consultar apenas grants de que participam, sem editar via consulta |
| B6 | **ACEITAR** | Escopos `all`, `accounts`, `cards`, `transactions`, `goals`, `reports`; novos escopos exigem migração, matriz e teste |
| B7 | **ACEITAR** | Um único grant vigente por núcleo/titular/beneficiário/escopo; todas flags falsas revogam; toda mudança incrementa revision |
| B8 | **AJUSTAR** | Convite enviado **não significa ativação concluída**; `pending` até aceite/credencial validada, `active` após conclusão, `blocked` negado. Ver 19.2 |
| B9 | **ACEITAR** | Bloqueado não acessa próprios dados nem modifica perfil; não confiar somente no fluxo visual de login |
| B10 | **ACEITAR** | Admin não altera próprio status, não é titular de carteiras e nunca recebe grants financeiros |
| B11 | **AJUSTAR** | Auditoria append-only para aplicação/usuários/serviços comuns; não prometer proteção absoluta contra dono/superusuário do banco. Ver 19.4 |
| B12 | **ACEITAR** | Reuso de `operation_id` com hash/carga diferente responde 409, sem efeito parcial ou revelação sensível |
| B13 | **ACEITAR COM GUARDA** | Retry de convite recupera apenas identidade pendente comprovadamente criada **pela mesma operação** e destinatário; e-mail de ativo retorna 409 `already_provisioned` |
| B14 | **AJUSTAR** | Mínimo 12 caracteres, não exigir composição arbitrária como garantia principal; checar senhas fracas/comprometidas quando suportado, rate limit e MFA Admin. Ver 19.5 |
| B15 | **AJUSTAR** | Bootstrap via função privilegiada manual pode permanecer com controles de identidade, concorrência e desativação. Ver 19.6 |
| C | **ACEITAR COM VALIDAÇÃO** | Desabilitar signup global mantendo provedor e-mail funcional; conferir sintaxe da versão local e comportamento remoto. Ver 19.7 |

### 19.2 Estados de identidade e conclusão do convite (B8, B9, B13)

- `pending`: conta Auth/provisionamento criado, mas convite/aceite/definição de credencial ainda não concluídos. Não tem acesso financeiro nem aos membros do núcleo, exceto fluxo mínimo de ativação/recuperação.
- `active`: verificação de e-mail e conclusão do onboarding, credencial definida, `activation_completed_at` gravado por ação server-side autorizada. Somente então autorizações por membership/grants podem operar.
- `blocked`: negar consultas, gravações, Storage, relatórios, leitura de perfil não essencial e grants concedidos pelo titular. Um access token ainda válido não pode contornar o status consultado no banco.
- `status_changed_at` registra toda transição, com evento de auditoria. Não promover `pending` a `active` simplesmente porque o Admin pediu o envio de convite.
- Se implementação existente já marca `active` antecipadamente, **não liberar para dados reais**: migrar o fluxo para `pending` ou impor `activation_completed_at IS NOT NULL` como requisito transversal de RLS/RPC, depois testar caminhos alternativos de Auth, sessão preexistente e recuperação.
- O retry de provisionamento compara `operation_id`, payload hash e identidade Auth previamente criada e vinculada a essa operação em `admin_operations`. Não assumir que um e-mail pendente qualquer pertence à operação; não tomar posse de identidade de terceiro.
- Alteração de status e revogação de grants devem ser atômicas no banco quando possível; chamadas ao Auth Admin API exigem estado recuperável quando não há transação distribuída.

### 19.3 Catálogo de operações RPC e limites de confiança (A4/A5)

| RPC ou família | Finalidade permitida | Proteção exigida |
|---|---|---|
| `admin_create_household` | Criar núcleo, inicializar status/autor | Admin `active` com MFA/AAL2, operação idempotente e auditoria |
| `admin_set_user_status` | Bloquear/reativar identidades | Admin ativo com MFA; proibir autoalteração e bloqueio do único Admin; trilha e invalidação de acesso |
| `admin_set_household_member` | Inserir/suspender/remover vínculo | Admin MFA, membership consistente; suspensão revoga grants dependentes |
| `admin_set_data_grant` | Conceder/revogar flags por escopo | Admin MFA; flags e constraint B2, revisão otimista, unicidade de vigente, auditoria |
| `whoami` | Consultar identidade efetiva/status | Resposta mínima do próprio usuário; jamais retornar claims administrativos de outro usuário |
| `accessible_owners` | Lista dos titulares permitidos ao chamador | Exigir autenticação e estado active; somente IDs/nomes estritamente autorizados, sem saldos ou metadados protegidos |
| `service_*` | Operações internas de Edge Functions | `EXECUTE` só para papel de serviço/rotina explicitamente autorizada, origem e identidade verificadas; nunca expor via `anon` ou usuário comum |
| `private.bootstrap_first_admin(email)` | Configurar primeiro Admin manualmente | Executar apenas em SQL Editor/papel privilegiado, sob pré-condições da 19.6 |

**Contrato comum:** validar identidade pelo contexto do Auth (`auth.uid()`/AAL quando aplicável), estado atual no banco e permissões por ação; não aceitar actor/role enviados pelo frontend. Para `SECURITY DEFINER`: fixar `search_path`, qualificar objetos por schema, evitar SQL dinâmico desnecessário, restringir `EXECUTE`, não deixar funções privilegiadas públicas por default e testar invocação como `anon`, `authenticated` e serviço. Retornar erros estáveis sem vazamento de existência/dados de outro titular. Auditoria e `admin_operations` não recebem senha, token, payload completo ou comprovante.

`admin_operations`: `operation_id` único em contexto definido, ator/ação, hash canônico dos parâmetros relevantes, status (`pending/succeeded/failed` ou nomenclatura documentada) e resultado sanitizado. Concorrência controlada por chave/lock único. Mesmo ID e mesmo payload devolve resultado recuperável; ID igual e payload distinto = HTTP 409. Definir TTL/retenção e não confundir idempotência da operação administrativa com `sync_operations` do financeiro.

### 19.4 Grants e auditoria (B1–B7/B11)

- `data_grants` deve ter índice único parcial para concessão vigente por `(household_id, owner_user_id, grantee_user_id, resource_scope)` usando predicado `revoked_at IS NULL` ou equivalente; `revision` aumenta em cada mudança, revogação incluída. Se a implementação reutiliza a mesma linha, preservar histórico em `audit_events` e não destruir alterações anteriores.
- `CHECK (NOT(can_update OR can_cancel) OR can_read)` ou mecanismo equivalente. **CREATE sem READ** não pode retornar representação do registro financeiro recém-criado a beneficiário sem leitura; retornar apenas referência opaca e estado da operação, se necessário.
- Autorizar leitura pelo conjunto: usuário autenticado ativo + titular ativo + membership ativo do núcleo + grant vigente com escopo e flags, quando origem não pertence ao usuário. Em próprio dado, continuam valendo status e escopo da sessão.
- Auditoria: usuários comuns veem eventos cujo `actor_user_id` seja seu próprio ID, sujeitos à minimização; eventos sobre seu dado realizados por terceiro podem ser mostrados em visão própria sanitizada, a definir por política de produto, sem nome/detalhes privados indevidos. Admin com MFA lê eventos administrativos/segurança; exposição de valores financeiros de terceiros na auditoria é proibida.
- Inserção de auditoria exclusivamente via servidor/função autorizada, sem `UPDATE`/`DELETE` por papéis de aplicação; logs externos append-only/assinados, controle de acesso, retenção e reconciliação reduzem risco de alteração por administradores de infraestrutura. Proprietário/superusuário do banco pode tecnicamente modificar objetos: **não afirmar imutabilidade absoluta**.
- A regra de não remoção na aplicação não elimina obrigação de política de retenção e atendimento a pedidos de titulares; documentar expurgo autorizado e evidência mínima necessária.

### 19.5 Senha, MFA, recuperação e rate limit (B14)

Mínimo de **12 caracteres** para senha escolhida pelo usuário; aceitar colar e gerenciadores de senha, frases longas e Unicode dentro dos limites suportados. Requisitos de maiúscula/minúscula/dígito podem ser removidos em favor de proteção contra senhas comuns/vazadas quando a configuração/provedor efetivamente a suporta; se mantidos provisoriamente, não substituir checagem de comprometimento nem rate limiting. Confirmação de e-mail habilitada. Troca autenticada de senha exige verificação recente ou reautenticação compatível com a versão do SDK, nunca apenas um campo visual não verificado. Recuperação independente deve operar com SMTP real e token expirável, mensagens não enumeráveis e controles de abuso.

Admin deve concluir MFA TOTP e possuir AAL2 antes de operações privilegiadas, verificado em RPC/Edge/RLS pertinentes. Rate limit server-side das tentativas (login, recuperação, convites, operações sensíveis), inclusive tentativas concorrentes; controles do provedor e do proxy também devem ser configurados/testados. Sem rate limit, recuperação funcional ou MFA testado, Marco A não está homologado.

### 19.6 Bootstrap manual de Admin (B15)

A execução manual informada é: convite pelo painel autorizado do Supabase e, depois, `SELECT private.bootstrap_first_admin('<email>');` pelo SQL Editor. Essa sequência pode ser preservada somente mediante os seguintes requisitos:

1. Executar em projeto correto por papel de banco autorizado; não expor `EXECUTE` a `anon`, `authenticated` ou rotas públicas.
2. Resolver o e-mail normalizado a **exatamente um** usuário existente do Auth, conferir o estado/identidade esperados e não confiar apenas na string como prova de posse.
3. Operação transacional e serializada por lock; recusar qualquer outro administrador já provisionado, ativo **ou pendente de ativação**, evitando corrida ou criação de segundo Admin indevido.
4. Reexecutar apenas para o mesmo usuário sem criar duplicatas, redefinir senhas ou relaxar políticas; registrar o evento sem credenciais.
5. Depois do login inicial, validar matrícula MFA e AAL2 antes de gerenciamento administrativo; confirmar impossibilidade de promoção por cliente.
6. Desabilitar/revogar o executor de bootstrap após configuração, ou restringir a procedimento operacional privilegiado e auditado de recuperação do último Admin.

Não documentar senha no SQL, repositório, logs ou evidências. Para recuperação do único Admin, adotar procedimento manual separado e testado.

### 19.7 Configuração do Supabase Auth e cadastro público (C)

**Configuração local proposta, sujeita à validação da versão efetiva do Supabase CLI/GoTrue:**

```toml
[auth]
enable_signup = false
enable_anonymous_sign_ins = false

[auth.email]
enable_signup = true
enable_confirmations = true
```

A chave global `[auth] enable_signup = false` desabilita novas inscrições públicas sem desativar o provedor de e-mail necessário ao login. Não configurar `[auth.email] enable_signup = false` como atalho: isso pode impedir o comportamento pretendido de autenticação por e-mail. **Verificar configuração efetiva e semântica exata da versão usada** no Supabase local e nos projetos hospedados; o arquivo local não atualiza automaticamente os ambientes remotos. Testar que signup público falha, convite administrativo funciona, login e recuperação por e-mail continuam disponíveis.

### 19.8 Pendências declaradas do Marco A (D): não confundir com divergências

| Código | Pendente informado | Obrigatoriedade para concluir M-A | Evidência exigida |
|---|---|---|---|
| D1 | Backup e restauração | Gate real / Marco A | Snapshot fora do projeto, bytes + schema, restore isolado e teste de acesso |
| D2 | Recuperação de senha | Marco A | SMTP real, fluxo completo, casos de token expirado e não enumeração |
| D3 | Rate limiting | Marco A | Contagem no servidor, concorrência, expiração e testes de abuso |
| D4 | Bloqueio também no login | Marco A | Negação no fluxo UI e rejeição de leituras com JWT preexistente; distinguir negação após Auth vs emissão do token |
| D5 | Telas login/admin | Marco A | Fluxos responsivos, convites/ativação, status/núcleos/grants com testes E2E |
| D6 | Primeira execução do CI | Marco A | Commit, ambiente, logs sanitizados, testes executados e resultados, sem afirmar verde antes de executar |
| D7 | Supabase desenvolvimento/produção | Marco A / Gate real | Projetos separados, versões verificadas, migração repetida, secrets e domínios segregados |

**Status da entrega 1:** implementação de schema/RPC/permissões **informada**; homologação **pendente**. Os itens D1–D7 permanecem abertos até testes e evidências. No intervalo, utilizar apenas dados fictícios/autorizados para teste, não dados financeiros reais.

### 19.9 Testes obrigatórios adicionais à seção 13

| Cenário | Resultado esperado |
|---|---|
| Titular bloqueado com grant ativo | Terceiro perde acesso imediatamente, mesmo com token ainda válido |
| Beneficiário com CREATE sem READ | Consegue criar somente no escopo autorizado; não consegue listar, buscar ou inferir dados do titular pelas respostas |
| UPDATE/CANCEL sem READ | Não é possível conceder; banco recusa constraint/operação |
| Membership suspenso | Grants dependentes tornam-se ineficazes; sessão antiga não lê |
| `display_name` cross-household | Não aparece em `accessible_owners` nem em seletores |
| READ grants do próprio participante | Titular/beneficiário veem metadados pertinentes e não alteram permissões |
| Revogação de grant | `revision` aumenta, uma única concessão vigente, auditoria preservada |
| Convite enviado e ainda não aceito | Perfil pendente não acessa dados mesmo com rota ou Auth alternativo |
| Mesmo operation ID com payload diferente | 409, sem alteração parcial |
| Retry de provisionamento interrompido | Reutiliza somente Auth pendente vinculado à mesma operação; conta ativa alheia dá 409 |
| Admin AAL1 | Nenhuma RPC administrativa privilegiada executa |
| Bootstrap repetido/outro e-mail | Mesmo alvo idempotente; outro alvo negado; concorrência não cria dois Admins |
| Chamadas RPC como anon/usuário comum | Operações `admin_*`, `service_*` e bootstrap negadas; `whoami` mínimo |
| Auditoria como usuário | INSERT arbitrário/UPDATE/DELETE negados; Admin com MFA consulta eventos permitidos |
| Auth signup/login | Cadastro público bloqueado; login por e-mail funcional; convite e recuperação testados |
| Usuário bloqueado | Não altera perfil, não consulta próprios dados e não obtém acesso apesar de JWT válido |

### 19.10 Changelog v1.0 → v1.1

- Ratificados A1–A5: versões, layout real informado, RPCs e extensões do modelo de dados.
- Ratificados B1–B7, B9–B10 e B12–B13 com guardas de integridade, idempotência e autorização.
- Ajustados B8, B11, B14 e B15 por motivos de ativação, limites da auditoria, política de credenciais e bootstrap privilegiado.
- Incorporada correção C, com exigência de teste no Supabase local e remoto.
- D1–D7 formalizados como pendências de aceite, sem mudança de escopo dos marcos B–E.
- Catálogo de RPCs, matriz complementar de testes e critérios de evidência incluídos.

**Aviso de versão:** esta v1.1 não certifica que os ajustes foram implementados. O executor deve produzir diff de código/migrações, evidências de teste e nova atualização de estado antes de marcar Marco A concluído.
