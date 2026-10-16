# Evidência — Remodelagem v2.2, fase R3 (desbloqueio financeiro no servidor)

**Data:** 15/10/2026 · **Branch:** `remodelagem/r3-desbloqueio`
**Decisão:** [ADR-0006](../decisoes/ADR-0006-desbloqueio-financeiro.md)

## O que entrou

- **Migration `20261017000200_financial_unlock.sql`:**
  - tabela privada `financial_unlocks` e funções `finance_unlocked` e `jwt_session`;
  - `can_access_family` passa a exigir desbloqueio para ler, alterar e cancelar;
  - `unlock_finance`, `touch_finance`, `lock_finance`, `finance_status`;
  - `quick_entry_options` (só apelidos);
  - `create_card_purchase` exige "criar" no cartão;
  - gatilhos de invalidação (senha, perfil, vínculo, família);
  - privilégios fechados de novo.
- **Web:**
  - `lib/finance-lock.tsx` espelha o servidor; não há mais `sessionStorage`;
  - desbloqueio = novo login com a senha + `unlock_finance`;
  - desktop desbloqueia no login; definir a senha (convite ou recuperação) também;
  - `touch_finance` em interação humana, no máximo a cada 30 s;
  - estado relido ao voltar ao app;
  - trocar de família chama `lock_finance`;
  - lançamento rápido via `quick_entry_options`;
  - botão "Desbloquear" só habilitado com a família carregada;
  - correção de corrida entre status antigo e desbloqueio;
  - mensagem própria para HTTP 429.
- **Testes:**
  - pgTAP 10 (39 asserções de desbloqueio);
  - integração `unlock-api` (5 cenários com Auth e PostgREST reais);
  - E2E de privacidade de rede;
  - login simulado das suítes antigas com sessão e desbloqueio;
  - exercício de restauração checa que ler exige desbloqueio.
- **Docs:** ADR-0006 e matriz RLS.

## Verificação prévia (Auth local)

- O JWT do login traz `session_id` e `amr` de senha com `timestamp`.
- **Renovar o token mantém o `timestamp`**; um novo login com senha cria nova sessão com horário novo.
- A opção A aprovada funciona sem Edge Function.

## Cobertura dos cenários PRIV

| Cenário | Onde | Resultado |
|---|---|---|
| PRIV-01 tela discreta sem valores | E2E mobile | ok |
| PRIV-02 lançamento sem desbloqueio, sem saldo na resposta | pgTAP 10, integração, E2E | ok |
| PRIV-03 senha errada não libera; senha antiga (token renovado) não desbloqueia | E2E, pgTAP 10 | ok |
| PRIV-04 navegação livre após desbloqueio; reload mantém | E2E mobile e desktop, integração | ok |
| PRIV-05 15 min sem atividade bloqueiam; login e lançamento rápido continuam | pgTAP 10 (servidor), E2E (relógio simulado) | ok |
| PRIV-06 leitura e polling não renovam; atividade renova só dentro da janela | pgTAP 10, E2E | ok |
| PRIV-07 logout (token antigo), troca de senha, bloqueio, suspensão e sessão vencida invalidam | pgTAP 10, integração | ok |
| PRIV-08 desbloquear outra família fecha a anterior; voltar exige senha | pgTAP 10; cliente chama `lock_finance` | ok |
| PRIV-09 acesso direto ao PostgREST sem desbloqueio não lê; nada financeiro trafega antes do desbloqueio | pgTAP 10, integração, E2E de rede | ok |
| PRIV-10 Admin não desbloqueia nem vê apelidos | pgTAP 10, integração | ok |

**Mutação:** com `can_access_family` sem a exigência de desbloqueio, 12 asserções da suíte 10 falham. Com a regra restaurada, tudo volta a passar.

## Testes (local)

| Suíte | Resultado |
|---|---|
| pgTAP | **358/358** (10 arquivos) |
| Integração | **57/57** (8 arquivos) |
| E2E | **37/37** (inclui privacidade de rede) |
| Unitários | 33/33 |
| Build web | ok |
| Exercício de restauração | **PASS**: isolamento e "ler exige desbloqueio" no restaurado; 358 pgTAP |

**Falhas intermitentes investigadas durante a fase:**
- **Teste de inatividade:** o teste avançava o relógio antes da resposta do `touch_finance`. Agora espera a resposta.
- **`goto` logo após o login no desktop:** a prova de senha é perdida no reload. O helper agora espera o painel liberado.
- **Falha isolada no desbloqueio:** não se repetiu. Descartei limite de login (o Auth local não limita nem logins corretos; 35 seguidos devolveram 200) e corrigi as duas corridas reais que podiam causá-la.
