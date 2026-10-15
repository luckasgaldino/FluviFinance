# ADR-0004 — Frontend do Marco A (login, MFA, painel administrativo)

- **Status:** aceita (Marco A, D4/D5) · **Data:** 15/10/2026
- **Referências:** Especificação v1.1 §3, §4, §5.3, §10.1 (item 3), §15, §19.8 (D4, D5)

## Decisões

1. **Bibliotecas.** As versões ficam fixas no lockfile e todas foram publicadas
   há mais de duas semanas.

   | Pacote | Versão | Por quê |
   |---|---|---|
   | React / React DOM | 19.3.0 | stack normativa |
   | Vite | 8.3.1 | stack normativa |
   | TypeScript | **6.0.3** | maduro; o 7.x (compilador nativo) é recente demais para fixar agora |
   | React Router | **7.18.4** | API estável; o 8.x saiu há pouco |
   | TanStack Query | 5.104.0 | cache em memória com chave por usuário, limpo ao sair |
   | supabase-js | 2.117.2 | igual ao dos testes e da Edge Function |

   **Sem biblioteca de UI:** CSS próprio com os tokens da §3.1. Uma biblioteca
   só entra se a reutilização justificar (§4.1, `packages/ui`).

2. **Autorização continua no banco.** A UI calcula um "portão" (anônimo,
   pendente, bloqueado, MFA obrigatório, Admin, usuário) a partir de `whoami` e
   do nível de autenticação, só para decidir a navegação. Tentar rotas
   proibidas leva de volta ao portão certo. Mesmo assim, toda operação é
   verificada pela RLS e pelas RPCs.

3. **MFA.** O Admin sem fator TOTP é levado ao cadastro e não consegue
   contornar a etapa. O Admin com fator e sessão `aal1` é levado à verificação.
   Para usuários financeiros o MFA é opcional; se tiverem fator, a verificação é exigida.

4. **Links de e-mail** (convite e recuperação) usam o fluxo *implicit*, com a
   sessão no fragmento da URL e destino em `/definir-senha`. Erros do link
   (expirado, usado, conta bloqueada) são lidos do fragmento antes de o SDK
   consumi-lo. O PKCE não serve para convites, que são gerados no servidor.

5. **Sessão no navegador (threat model resumido).** O SDK guarda a sessão em
   `localStorage` (`fluvi.auth`).
   - **Risco:** um XSS conseguiria ler o token.
   - **Mitigações:**
     - CSP restritiva, sem scripts de terceiros e sem `inline` (`public/_headers`);
     - access token de 1 h;
     - refresh invalidado ao bloquear;
     - nenhum dado financeiro ou administrativo persistido: o cache é só em
       memória e é limpo ao sair ou trocar de usuário.
   - A escolha será reavaliada no Marco C (PWA/offline).

6. **Cabeçalhos de segurança** (Cloudflare Pages, `public/_headers`): CSP, HSTS,
   nosniff, `frame-ancestors 'none'`, Referrer-Policy, Permissions-Policy e
   `no-store` no `index.html`. **Precisam ser validados no ambiente publicado (D7).**

7. **Anti-enumeração na interface.** "Esqueci minha senha" sempre mostra a mesma
   mensagem, inclusive quando o Auth limita o envio, que só ocorre para e-mails
   existentes e por isso revelaria a conta.

8. **Acessibilidade e responsividade.**
   - Rótulos explícitos, `role="alert"` e `role="status"`.
   - O foco vai para o título a cada página.
   - Alvos de toque de 44 px, foco visível, `prefers-reduced-motion`.
   - Estados sempre com texto, nunca só com cor.
   - Listas viram cartões no celular, sem tabelas com rolagem horizontal.
   - Verificado por axe (WCAG 2.x A/AA, sem violações graves ou críticas) e por
     teste de overflow a 360 px.

9. **D4: bloqueio em três camadas.**
   - O *Custom Access Token Hook* recusa a emissão de token (login, refresh, magic link, recuperação).
   - Bloquear encerra as sessões, invalidando o refresh.
   - A RLS nega o access token que já tinha sido emitido.

## Consequências

- O bundle tem cerca de 560 kB minificados (aviso do Vite). A divisão por rota
  entra quando houver telas financeiras.
- **Pendente (D7):** confirmar que o Custom Access Token Hook está disponível e
  habilitado no plano do projeto hospedado; validar CSP, HSTS e CORS com o
  domínio real.
