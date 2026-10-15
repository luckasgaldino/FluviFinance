# FluviFiance — Especificação Técnica e Funcional v2.2

**Data:** 15/10/2026  
**Estado:** diretriz de produto aprovada para remodelagem; implementação condicionada a inventário e plano de migração.  
**Substitui:** diretrizes de produto da v2.1 e a complexidade funcional das versões Fluvi v1.x. **Não autoriza reset, deploy, alteração destrutiva ou dados reais.**

## 1. Visão de produto

O **FluviFiance** é um controle financeiro simples, moderno e privado para famílias: registrar receitas, despesas e compras no cartão; acompanhar saldos, faturas, parcelas futuras e relatórios. A experiência deve ser simples para o usuário, mesmo quando mecanismos internos de segurança e consistência sejam mais elaborados.

**Princípios:** (1) poucos cliques para registrar; (2) uma visão financeira por família, nunca por pessoa; (3) valores confiáveis e explicáveis; (4) privacidade reforçada na PWA móvel; (5) reaproveitar com critério o que já foi testado; (6) não construir funcionalidades futuras prematuramente.

**Nome de produto:** FluviFiance (grafia deliberadamente adotada nesta especificação).  
**Identidade:** azul/turquesa/verde, fundo escuro tecnológico, acessibilidade WCAG AA. Tokens sugeridos: fundo `#071422`, superfícies `#102437` / `#173247`, azul `#3C82F6`, turquesa `#27D5C0`, verde `#55D99A`, âmbar `#F6BE64`, texto `#EAF5FA`, secundário `#8FA8BA`.

## 2. Usuários, famílias e isolamento

**A família é a única proprietária de dados financeiros.** Não existe saldo individual nem visão financeira individual no MVP. Todos os membros ativos de uma família veem os mesmos lançamentos, contas, cartões, faturas, parcelas e dashboards; `created_by` é apenas auditoria/filtro de autoria.

| Família | Membros | Visão |
|---|---|---|
| Família Galdino | Luck e Bia | Compartilhada integralmente |
| Família Silva | João | Somente Silva |
| Família Barbosa | Júlia | Somente Barbosa |
| Família Tavares | Pedro e Joana | Compartilhada integralmente |

Um usuário pode pertencer a mais de uma família e escolhe **uma família ativa por vez**; nenhum dado ou total é misturado. Admin pode criar famílias, convidar, bloquear, vincular, desvincular e realocar membros, sem ver informações financeiras. Adicionar membro a uma família requer convite/aceite e aviso claro de que terá acesso ao histórico completo da família. Revogação deve cortar acesso imediatamente no backend. Nenhum lançamento é transferido ao mudar um vínculo.

**Perfis:** `admin` (identidade e vínculos; sem acesso financeiro, MFA obrigatório), `member` (acesso financeiro somente às famílias aceitas e ativas), `invited/pending/blocked` como estados. Não implementar permissões financeiras granulares por pessoa nesta fase. A autenticação é por e-mail e senha, com recuperação e logout.

## 3. Comportamento obrigatório da interface

### 3.1 Web / desktop

Após login, abre o **dashboard financeiro** da família selecionada. Sidebar lateral expandida com Visão geral, Lançamentos, Contas e saldos, Cartões e faturas, Parcelas, Relatórios e Configurações. Botão **+ Novo lançamento** sempre destacado. Se houver mais de uma família, seletor visível na sidebar. Layout responsivo e acessível.

### 3.2 PWA / celular: privacidade em duas etapas

**Esta é uma regra central do produto, não apenas uma preferência estética.**

1. Ao abrir a PWA sem sessão de login, apresentar login por e-mail/senha. Se já houver sessão autenticada válida, pular o login inicial.
2. **Após login, sempre abrir a Tela Inicial Discreta**, com cabeçalho enxuto (menu lateral, identidade do app) e **uma única ação principal no conteúdo: `+ Novo lançamento`**. Não mostrar saldo, fatura, gráfico, extrato, valores, alertas com quantias, nome de transação ou qualquer dado financeiro nessa tela.
3. `+ Novo lançamento` é acessível sem o segundo desbloqueio. Formulário rápido de receita/despesa/compra, com campos necessários; não exibir saldos, últimas transações, totais, limites ou históricos no formulário enquanto a área financeira estiver bloqueada. Listas de contas/cartões podem mostrar **somente apelidos não sensíveis** para seleção; nunca números, saldo ou limite. Gravar requer sessão principal válida e autorização da família.
4. Ao escolher **pela primeira vez** uma área protegida no menu lateral (Visão geral, Lançamentos, Contas, Cartões, Faturas, Parcelas, Relatórios), pedir **a mesma senha do login novamente**, para autorizar acesso às informações financeiras. O menu pode ser aberto sem senha, mas o conteúdo protegido não.
5. Depois da confirmação, liberar **todas** as áreas financeiras daquela sessão de desbloqueio. **Trocar de tela, navegar pelo menu, voltar à tela inicial discreta ou trocar de rota não pede senha novamente e não encerra o desbloqueio.**
6. Requerer a segunda confirmação novamente somente após: logout, bloqueio manual, revogação de acesso, expiração do desbloqueio por **15 minutos de inatividade** ou invalidação de sessão. A expiração do desbloqueio **não** encerra a sessão principal de login: o usuário continua podendo usar a tela discreta e registrar lançamentos.
7. Enquanto desbloqueado, atividade real do usuário em área protegida renova o tempo de inatividade; **não** renovar por polling, requisições automáticas ou simples permanência de página aberta. Em retorno de segundo plano, reavaliar expiração antes de renderizar dados. Proteger, quando tecnicamente possível, a prévia do alternador de aplicativos; não prometer controle absoluto da captura de tela pelo sistema operacional.
8. Em caso de troca de família, o acesso é sempre revalidado no backend; por simplicidade e privacidade, **exigir novo desbloqueio financeiro para a nova família**, mesmo se a anterior ainda estava desbloqueada. Ao voltar para a família anterior, exigir novo desbloqueio. A sessão de login permanece.
9. Se a senha for alterada, usuário bloqueado ou vínculo revogado, invalidar desbloqueios correspondentes. O desbloqueio é **server-side**: não basta flag em `localStorage` ou esconder elementos com CSS. Consultas protegidas e RPCs de leitura sensível precisam verificar login, vínculo e desbloqueio recente. Não colocar dados protegidos no HTML inicial, caches PWA, notificações, logs ou pré-carregamento antes do desbloqueio.
10. A verificação de senha deve usar fluxo de reautenticação suportado pelo provedor de identidade; **nunca** armazenar senha, hash próprio ou credenciais no cliente. Definir contrato de token de desbloqueio de curta duração vinculado ao usuário, sessão e família, com expiração por inatividade controlada no servidor. Não implementar uma segunda conta ou senha.

**Nota de segurança:** o cadastro rápido sem segundo desbloqueio é uma exceção intencional de *escrita*, não de leitura. Toda operação continua sujeita a RLS/autorização; evitar que respostas, erros ou autocomplete revelem valores. Operações que exigirem dados sensíveis para serem concluídas devem solicitar desbloqueio ou ocultar tais dados.

### 3.3 Menu e navegação móvel

Sem barra inferior fixa. Cabeçalho discreto e botão de menu hambúrguer; gaveta lateral acessível por toque e teclado, fecha ao selecionar item ou tocar fora. Tela inicial não é um dashboard reduzido: é uma **tela de privacidade**, com somente o CTA principal. Nas telas protegidas, o conteúdo é responsivo, sem exposição anterior à autenticação adicional.

## 4. Funcionalidades do MVP

**FF-01 Login e famílias.** Login, recuperação, convites, aceite, vínculos, seleção de família, administração separada sem finanças; auditoria administrativa.

**FF-02 Novo lançamento.** Receita, despesa, compra no cartão e transferência entre contas da mesma família. Campos mínimos: tipo, valor, data, descrição, categoria e conta/cartão. Parcelamento opcional em compras de cartão. Edição/cancelamento com histórico adequado. Cadastro rápido móvel sem mostrar valores já cadastrados quando bloqueado.

**FF-03 Contas e saldos.** Conta bancária, poupança e dinheiro; instituição opcional, nome/apelido, saldo inicial com data de corte. Saldo = abertura + entradas − saídas após corte. Ajustes de saldo são lançamentos identificados. Transferência entre contas não é receita nem despesa.

**FF-04 Cartões e faturas.** Cartão com apelido, banco, limite opcional, dia de fechamento e vencimento. Compras atribuídas a faturas mensais; pagamento integral ou parcial de fatura a partir de conta. Compra não reduz caixa bancário; pagamento reduz caixa e dívida, sem duplicar gasto. Possibilidade de corrigir ciclo quando informação do banco divergir, preservando faturas pagas/confirmadas.

**FF-05 Parcelamentos.** Compras em 1–36 parcelas, distribuição exata de centavos, previsão por mês, parcelas futuras em relatórios. Não gerar nova despesa quando a parcela vence; gasto por competência e fluxo de caixa são visões diferentes.

**FF-06 Dashboard.** Saldo disponível consolidado, receitas, despesas, categorias, gastos por cartão, fatura atual, próximas faturas, parcelas futuras e evolução mensal. Filtros de mês e família ativa; definições simples e sem dupla contagem.

**FF-07 Relatórios.** Por período, categoria, conta, cartão, autoria de lançamento; gráficos de receitas × despesas, categorias, evolução de saldos, compromissos futuros até 12 meses. CSV inicial; PDF/XLSX posteriormente. Separar consumo, dívida/compromisso e caixa.

**FF-08 Categorias.** Categorias padrão e personalização por família; arquivamento sem apagar histórico.

**FF-09 Administração.** Famílias, usuários, convites, status, vínculos e trilha administrativa. Admin não consulta, exporta, calcula nem visualiza saldos e gastos, inclusive por API.

**FF-10 Extratos e dados bancários.** Extrato interno dos lançamentos por conta/cartão, com filtros; dados do banco apenas rótulos manuais. **Importação** CSV/OFX e faturas de banco na fase 2, com revisão e deduplicação. Não pedir credenciais bancárias.

## 5. Fora do MVP e roadmap

- **Fase 2:** importação CSV/OFX/faturas, revisão de duplicatas, implantação de saldos/dívidas anteriores na data de corte sem fabricar consumo do mês, exportações avançadas.
- **Fase 3:** investimentos por família (aportes, resgates, patrimônio, rendimento nominal/% e atualização inicialmente manual). Valorização não realizada não entra como receita de caixa.
- **Posterior:** Open Finance, IA, notificações, OCR, metas, PWA offline com sincronização, múltiplas moedas. **A PWA instalável e responsiva, com login e proteção financeira, faz parte do MVP; o modo offline não.**

## 6. Regras financeiras e segurança essenciais

1. Dinheiro em centavos inteiros (`bigint`), moeda BRL no MVP.
2. Toda linha financeira pertence a uma família; checagem server-side por família e usuário ativo em todas as RPCs e consultas.
3. A mesma família tem uma única visão financeira compartilhada; `created_by` não cria propriedade individual.
4. Compra no cartão aumenta dívida e gasto por competência; não diminui saldo bancário até pagamento.
5. Pagamento de fatura reduz dívida e caixa; não soma novo gasto.
6. Soma das parcelas deve ser exatamente o valor da compra.
7. Transferência entre contas da mesma família é neutra no saldo consolidado.
8. Não alterar silenciosamente histórico financeiro liquidado; compensações e auditoria quando necessário.
9. Operações compostas são atômicas, idempotentes e testadas contra concorrência.
10. Relatórios não somam a mesma movimentação em métricas incompatíveis.
11. **Duas barreiras móveis:** sessão de login e desbloqueio financeiro por senha; ambas verificadas no backend para leituras sensíveis. O desbloqueio expira após 15 minutos sem atividade humana, não ao navegar entre telas.
12. Admin não pode burlar a separação de dados via RPC, view, exportação ou funções privilegiadas.
13. Não registrar valores sensíveis em logs operacionais; backup cifrado e restauração testada antes de dados reais.

## 7. Arquitetura e modelo lógico

**Manter preferencialmente:** React + TypeScript + Vite, Supabase Auth/PostgreSQL/RLS, CI e ambientes separados, Cloudflare Pages. PWA com manifest e service worker **sem cache de respostas financeiras protegidas**. Consultas via views `security_invoker` e RPCs seguras; sem microserviços desnecessários.

**Conceitos lógicos:** `profiles`, `families`, `family_members`, `financial_accounts`, `cards`, `billing_cycles/invoices`, `transactions`, `installments`, `invoice_payments`, `categories`, `ledger_entries` (se mantido), `audit_events`, `financial_unlock_sessions` (ou equivalente server-side). Todas as entidades financeiras devem possuir `family_id` diretamente ou por relacionamento inequívoco e protegido.

**Compatibilidade:** no código existente há, segundo os relatórios de implementação, `households`, `household_members`, `data_grants`, `owner_user_id`, `financial_accounts`, `ledger_entries` e RPCs de Marco B. Não duplicar entidades só por nomes diferentes. Elaborar mapeamento físico real e rever **todas** as políticas RLS, views, RPCs, funções `SECURITY DEFINER`, grants e testes. O desbloqueio financeiro exige desenho específico de autorização: não presumir que RLS do Supabase por si só distingue sessão normal de sessão reautenticada; desenhar enforcement server-side com proteção contra chamadas diretas ao PostgREST.

**Atenção:** a especificação é normativa sobre o produto, mas não certifica a implementação atual. Nenhuma migração destrutiva, reset de ambiente ou substituição integral do banco sem inventário, evidência, plano reversível e autorização.

## 8. Telas

1. Login / recuperação.
2. **Mobile: Inicial discreta** (CTA único + menu).
3. **Mobile: Confirmação de senha para acesso financeiro** (sem encerrar login).
4. Dashboard familiar.
5. Novo lançamento rápido.
6. Lançamentos / extratos.
7. Contas / saldos.
8. Cartões / faturas / pagamento.
9. Parcelas futuras.
10. Relatórios.
11. Configurações / família ativa.
12. Admin (usuários/famílias/vínculos, sem finanças).

## 9. Cenários de aceite obrigatórios

**PRIV-01** Login na PWA → tela discreta sem valores, inclusive antes de carregar a aplicação.  
**PRIV-02** Novo lançamento na tela discreta → grava despesa com sucesso sem mostrar saldo ou histórico e sem segundo desbloqueio.  
**PRIV-03** Abrir menu → escolher Dashboard → pedir senha; senha incorreta não libera dados.  
**PRIV-04** Senha correta → navegar Dashboard → Cartões → Relatórios → Contas → Inicial → Dashboard sem nova senha, se dentro da janela de atividade.  
**PRIV-05** Após 15 minutos sem interação humana → bloquear leituras; login continua ativo e novo lançamento permanece disponível.  
**PRIV-06** Polling/reload em background não prolonga desbloqueio; ao retornar, não exibir conteúdo protegido se expirado.  
**PRIV-07** Logout, troca de senha, bloqueio de usuário e revogação de vínculo invalidam desbloqueio.  
**PRIV-08** Trocar de família requer novo desbloqueio e nunca mistura dados.  
**PRIV-09** Requisição direta à API protegida sem desbloqueio válido falha, mesmo que o usuário esteja logado; sem dados sensíveis em cache.  
**PRIV-10** Admin não lê dados financeiros em nenhuma rota, view, exportação ou RPC.  
**FAM-01** Bia e Luck veem os mesmos lançamentos da Família Galdino.  
**FAM-02** João não vê dados de Galdino; Julia não vê dados de Tavares.  
**FAM-03** Realocar membro não move histórico nem concede acesso antes de aceite.  
**FIN-01** Abertura R$ 2.000 e débito R$ 150 → saldo R$ 1.850.  
**FIN-02** Compra R$ 600 em 6× R$ 100 → 6 parcelas e dívida R$ 600, sem saída de caixa.  
**FIN-03** Pagar R$ 100 da fatura → caixa -R$ 100 e dívida -R$ 100, sem duplicar consumo.  
**FIN-04** R$ 100,01 em 3 parcelas → soma exata R$ 100,01.  
**FIN-05** Transferência entre contas não altera saldo total da família.  
**OPS-01** RLS e testes de isolamento verdes, CI verde, restauração verificada, SMTP e homologação mobile/acessibilidade antes de dados reais.

## 10. Plano de remodelagem do legado

**Etapa 0 — Diagnóstico (sem alterar código):** inventariar repositório, migrations, tabelas, RPCs, RLS, CI, testes e telas; apresentar mapa manter/adaptar/aposentar, riscos e plano de reversão. Confirmar ausência de dados reais antes de qualquer limpeza.

**Etapa 1 — Contratos e segurança:** converter propriedade de usuário para família de forma consistente; especificar e testar segunda autenticação móvel no backend; proteger leituras e evitar vazamento via APIs e caches. Apresentar migrations mínimas e plano de execução; aguardar autorização para mudanças destrutivas.

**Etapa 2 — UI:** criar novo design system FluviFiance, sidebar desktop, menu lateral móvel, inicial discreta, confirmação de senha e formulário rápido. Dados fictícios primeiro.

**Etapa 3 — Fluxos:** contas, saldo, lançamentos, cartões, faturas, parcelas, relatórios; integrar backend com testes de fluxo e acessibilidade.

**Etapa 4 — Famílias e admin:** convites, aceite, múltiplos vínculos, troca de família, revogação imediata, isolamento e testes negativos.

**Etapa 5 — Homologação:** publicar em `fluvi-dev` somente após autorização; SMTP, PWA no iPhone/Safari, teclado/leitor de tela/texto ampliado, testes de API, backup e restauração. Dados reais somente após gate formal.

## 11. Situação herdada e limites

Conforme informado pelo desenvolvimento: Marco A tem infraestrutura e Auth com pendências de SMTP/homologação; Marco B possui banco implementado e testado localmente/CI com dados fictícios, **ainda não aplicado ao `fluvi-dev`**, sem telas. A v2.2 não atesta o código, e o Claude deve verificar o repositório antes de afirmar compatibilidade.

## 12. Changelog v2.1 → v2.2

- **PRIV-01–10:** nova regra de tela inicial discreta obrigatória na PWA e segundo desbloqueio por mesma senha, sem solicitar a cada troca de tela.
- **Sessões:** login principal separado do desbloqueio financeiro; 15 minutos de inatividade; retorno à tela discreta não encerra desbloqueio.
- **Mobile:** tela inicial exclusivamente para novo lançamento; áreas financeiras acessíveis pelo menu após desbloqueio.
- **Famílias:** mantém propriedade e visão unificadas por família, sem dados individuais.
- **Remodelagem:** exige autorização server-side de leituras protegidas e testes negativos contra chamadas diretas, sem descarte precipitado do legado.
