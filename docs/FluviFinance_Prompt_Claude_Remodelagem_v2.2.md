# Prompt para Claude — Remodelagem FluviFiance v2.2

Você é o engenheiro responsável pelo repositório do Fluvi. O produto foi deliberadamente simplificado e passa a seguir **integralmente** o documento anexo `FluviFiance_Especificacao_Tecnica_Funcional_v2.2.md`, que substitui as antigas diretrizes de produto do Fluvi v1.x/v2.1. **Leia o documento inteiro antes de agir.**

## Objetivo

Transformar o sistema atual em **FluviFiance**: finanças por família, lançamentos rápidos, contas/saldos, cartões/faturas, parcelas futuras e relatórios simples. Preservar segurança e correção financeira, mas retirar da interface e do escopo MVP a complexidade desnecessária.

### Regras inegociáveis

1. **Família é o único titular financeiro**: Família Galdino = Bia e Luck com uma visão unificada; Silva = João; Barbosa = Júlia; Tavares = Pedro e Joana. Um usuário pode ter vínculo em várias famílias, com seleção explícita e isolamento absoluto. Admin controla usuários/famílias/vínculos e não vê dados financeiros.
2. **PWA móvel:** após login válido, sempre abrir **tela inicial discreta** sem qualquer dado financeiro, com menu lateral e `+ Novo lançamento`. Cadastro rápido permitido sem segundo desbloqueio, sem retornar saldos ou históricos.
3. **Menu financeiro móvel:** ao tentar entrar pela primeira vez em área com dados financeiros, solicitar novamente **a mesma senha do login**. Após sucesso, navegar entre TODAS as telas, inclusive voltar à tela inicial e depois ao dashboard, **sem nova senha**. Só bloquear após 15 minutos de inatividade, bloqueio manual, logout, revogação, troca de senha ou mudança de família. Expiração da área protegida **não** encerra login.
4. **Segurança real:** a segunda autenticação deve ser validada no backend e vinculada à sessão e família; não usar apenas estado React/localStorage/CSS. Leituras sensíveis por API/RPC/view devem ser negadas antes do desbloqueio, inclusive chamadas diretas. Não armazenar senha no frontend nem em tabela própria; não colocar dados financeiros em cache offline ou pré-carregamento antes de desbloquear.
5. **Desktop:** após login, abrir dashboard com sidebar expandida; não impor o segundo desbloqueio móvel ao desktop nesta versão.
6. **MVP enxuto:** contas e saldos, lançamentos, cartão/fatura, parcelas, relatórios e admin. Importação e dívida anterior são fase 2; investimentos fase 3. Não implementar IA, Open Finance, notificações, offline-sync ou contabilidade avançada de interface agora.
7. **Não destruir o legado:** antes de mudanças, verificar migrations, `households`, `household_members`, `data_grants`, `owner_user_id`, `ledger_entries`, RPCs, RLS, testes e CI. Reutilizar o que serve; substituir/adaptar apenas o que for necessário. **Nenhum DROP, reset, exclusão de dados, migração destrutiva, deploy em `fluvi-dev` ou uso de dados reais sem aprovação expressa.**

## Execução em etapas

**Etapa 0 — Faça agora, sem modificar código:**
- Leia o repositório e compare com a v2.2.
- Gere inventário de tabelas, migrations, RPCs, views, políticas RLS, testes, interfaces e ambientes.
- Monte matriz **manter / adaptar / descontinuar / criar**, justificando esforço e riscos.
- Proponha arquitetura mínima para autorização por família e para o desbloqueio financeiro móvel, inclusive proteção contra acesso direto via Supabase/PostgREST e cache.
- Apresente plano de migração reversível e fases de entrega, com testes e critérios de aceite.
- Liste **somente decisões realmente bloqueantes** para aprovação; para detalhes triviais, proponha defaults.

**Depois da minha aprovação da Etapa 0:**
- Implemente em fases pequenas, cada uma com migrações versionadas, testes e evidências.
- Comece pelo layout e navegação com dados fictícios; depois contratos seguros e integrações conforme dependências reais.
- Reuse a paleta azul/turquesa/verde da especificação; priorize UI moderna e limpa.
- Teste os cenários `PRIV-*`, `FAM-*`, `FIN-*` e `OPS-*` da v2.2; acrescente testes de concorrência, isolamento e privacidade de rede/cache.
- Não declare funcionalidades prontas sem teste real; diferencie local, CI, dev e homologado.

## Formato da primeira resposta

1. Resumo executivo da remodelagem em linguagem simples.
2. Inventário e matriz de reaproveitamento do código atual.
3. Desenho de autorização por família e segundo desbloqueio móvel (incluindo limitações reais do Supabase Auth e alternativas seguras).
4. Lista de alterações previstas no banco e frontend, com impacto e rollback.
5. Roadmap de entregas com critério de aceite de cada fase.
6. Riscos e, no máximo, perguntas essenciais que bloqueiem a execução.

**Importante:** o objetivo não é refazer tudo do zero por princípio. É entregar um produto simples, bonito e seguro usando o máximo possível do trabalho confiável já realizado. Aguarde minha aprovação do plano antes de modificar o repositório.
