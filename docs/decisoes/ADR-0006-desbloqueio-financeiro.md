# ADR-0006 — Desbloqueio financeiro exigido pelo banco

**Data:** 15/10/2026 · **Estado:** aceita (remodelagem v2.2, fase R3)

## Contexto

A v2.2 (§3.2, §6.11) exige duas barreiras para ler dados financeiros: a sessão de login e uma segunda confirmação com a mesma senha. Ambas precisam ser verificadas **no servidor**; não basta estado de interface. O Supabase Auth não oferece uma API para "conferir a senha sem trocar de sessão", e a RLS só enxerga o JWT.

Na Etapa 0 foi aprovado:
- o desbloqueio vale no servidor para todos os clientes;
- no desktop, o próprio login desbloqueia;
- a reautenticação é feita por `signInWithPassword` + claims do JWT;
- a alternativa B (Edge Function) fica como plano de reserva.

## Verificação prévia

Teste feito no Auth local (CLI 2.118):
- o JWT do login traz `session_id` e `amr: [{method: "password", timestamp}]`;
- **renovar o token mantém o `timestamp` original**;
- um novo login com senha cria **nova sessão** com `timestamp` novo.

Por isso, a prova "senha digitada agora" não pode ser forjada renovando um token antigo. A alternativa B não foi necessária.

## Decisão

1. **`private.financial_unlocks`:** uma linha por sessão de login, com usuário, família, momento do desbloqueio e última atividade. Fica no schema privado, sem acesso para `authenticated`.
2. **`public.unlock_finance(família)`:** desbloqueia só se, ao mesmo tempo:
   - quem chama é membro ativo da família;
   - a sessão existe e não venceu;
   - o JWT tem `amr` de senha com menos de **2 minutos**.

   Desbloquear outra família substitui o desbloqueio anterior (PRIV-08).
3. **`private.can_access_family`:** leitura, alteração e cancelamento exigem `finance_unlocked(família)`. Criar não exige, porque é o lançamento rápido. Como todas as políticas, views (`security_invoker`) e RPCs passam por essa regra, um acesso direto ao PostgREST sem desbloqueio não lê nada (PRIV-09).
4. **Inatividade:** 15 min. `touch_finance()` renova a janela e é chamado pelo cliente em interação humana, no máximo a cada 30 s. Leituras e `finance_status()` não renovam (PRIV-06).
5. **Invalidação:** gatilhos em troca de senha, perfil não ativo, vínculo suspenso ou removido e família inativa. Logout e sessão vencida são cobertos pela junção com `auth.sessions` (PRIV-07).
6. **Lançamento rápido:** `quick_entry_options(família)` devolve só id e apelido de contas, cartões e categorias. As RPCs de criação devolvem só `{id, status}`. Compra no cartão passa a exigir "criar", e não mais "ler", no cartão.
7. **Cliente:** espelha o estado do servidor (`finance_status`) e não guarda nada no navegador. Desbloquear é um novo login com a senha seguido de `unlock_finance`. Trocar de família chama `lock_finance`.

## Consequências e limites

- O banco não tem como saber se a atividade foi humana. `touch_finance` é declarado pelo cliente, então um cliente adulterado consegue estender a janela, **mas só se já estiver desbloqueado**. Polling legítimo do app não renova.
- Desbloquear cria uma nova sessão de login, e a anterior expira pelo ciclo normal do Auth.
  - Um usuário comum com TOTP opcional cairia na verificação MFA ao reautenticar. Hoje nenhum usuário financeiro é obrigado a ter MFA, e esse caso fica para a homologação.
- Recarregar a página mantém o desbloqueio, porque o estado está no servidor.
  - No desktop, a prova de senha do login vale por 60 s no cliente; um reload logo após o login pode pedir a senha.
- O bloqueio de captura de tela e da prévia do alternador de apps continua só no melhor esforço (véu de privacidade).
