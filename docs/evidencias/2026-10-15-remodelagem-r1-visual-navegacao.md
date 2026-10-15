# Evidência — Remodelagem v2.2, fase R1 (visual e navegação)

**Data:** 15/10/2026 · **Branch:** `remodelagem/r1-visual-navegacao`
**Estado:** testado localmente. CI ao enviar a branch. **Não publicado** no fluvi-dev (o merge na `main` dispara o deploy e depende de autorização).

## O que entrou

- **Design system v2.2** (`apps/web/src/styles/app.css`):
  - fundo `#071422`, superfícies `#102437`/`#173247`, gradiente azul → turquesa → verde, âmbar para despesas;
  - contraste AA verificado (o azul fica só como decoração);
  - nova marca "FluviFiance" e novo favicon.
- **Shell** (`routes/shell.tsx`):
  - desktop: sidebar expandida com família ativa, "+ Novo lançamento", Visão geral, Lançamentos, Contas e saldos, Cartões e faturas, Parcelas, Relatórios, Configurações, Bloquear e Sair;
  - celular: cabeçalho com hambúrguer e gaveta `<dialog>` (Esc e toque fora fecham, foco preso), sem barra inferior;
  - itens protegidos marcados com cadeado enquanto bloqueados;
  - véu de privacidade ao ir para segundo plano.
- **Privacidade** (`routes/privacy.tsx`, `lib/finance-lock.tsx`):
  - tela inicial discreta (só o CTA);
  - tela "Área financeira protegida" com a mesma senha do login;
  - lançamento rápido (`/novo`) sem desbloqueio: despesa, receita, compra no cartão (1–36×, prévia de centavos) e transferência. Usa só apelidos e não mostra saldo, limite nem final do cartão;
  - janela de 15 min renovada apenas por atividade humana em área protegida; bloqueio manual; cache `fin` apagado ao bloquear; `refetchOnWindowFocus` desligado.
- **Desktop:** o login abre o dashboard já liberado; após 15 min ocioso, pede a senha sem deslogar.
- **Telas novas com dados fictícios** (`routes/finance/Insights.tsx`, `lib/demo.ts`): Visão geral, Parcelas e Relatórios (CSV), todas com selo "Demonstração". Configurações em `routes/settings.tsx`.
- As telas reais de Contas, Lançamentos, Cartões e Compras continuam ligadas ao banco, agora atrás do desbloqueio.

## Limite conhecido desta fase

O estado do desbloqueio ainda vive no cliente: memória + `sessionStorage` para sobreviver a recarregar a página. A senha é conferida pelo Auth (`signInWithPassword`), mas **o banco ainda não exige o desbloqueio**: uma chamada direta à API com a sessão de login lê dados. Isso é o escopo da **R3** (PRIV-09) e não deve ser tratado como proteção real antes dela.

Outro ponto para a R3: um usuário comum com TOTP opcional cadastrado, ao reautenticar, recebe sessão aal1 e cai na verificação de MFA.

## Testes executados (local)

| Suíte | Resultado |
|---|---|
| Unitários (`pnpm test:unit`) | 33/33 |
| Build web (`pnpm web:build`) | ok |
| E2E (`pnpm test:e2e`) | **36/36** (desktop 23, mobile-360 13) |

**E2E novos:**

- `privacy-mobile.spec.ts`:
  - PRIV-01: tela discreta sem "R$", com um único link;
  - menu sem senha e senha errada não libera (PRIV-03);
  - PRIV-04: navegação Visão geral → Cartões → Relatórios → Contas → Início → Visão geral sem nova senha;
  - PRIV-02: bloqueado, grava despesa; a resposta da RPC tem só `id` e `status`; FIN-01 (2.000 − 150 = 1.850) conferido após desbloqueio;
  - PRIV-05: relógio simulado, com atividade renovando e 15 min parado bloqueando, mantendo login e lançamento rápido;
  - PRIV-07: sair e entrar exige novo desbloqueio.
- `privacy-desktop.spec.ts`: dashboard com sidebar no login, recarregar mantém, inatividade pede senha sem deslogar, axe em Parcelas, Relatórios e Configurações.
- `responsive.spec.ts`: 360 px + axe na tela discreta, `/novo`, Configurações, gaveta, tela de senha e todas as telas financeiras.

**E2E ajustados:**

- navegação "Contas e saldos" e "Cartões e faturas";
- chegada em `/painel` no desktop;
- `admin-flow` deixa de verificar a antiga tela "Quem você acompanha" (permissões individuais, descontinuadas na R2). A revogação continua coberta no pgTAP 01;
- a limpeza do `responsive` apaga só as próprias identidades.

**Observado:** em uma rodada, o convite via Edge Function `provision-user` ficou lento, e o usuário foi criado depois da limpeza (resíduo fictício removido). Rodadas seguintes passaram. Registrado junto ao G4 (intermitência E2E em observação).

Banco: **nenhuma migration nesta fase**. pgTAP e integração não foram afetados.
