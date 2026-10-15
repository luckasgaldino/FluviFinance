# Bootstrap do primeiro Admin

Referência normativa: Especificação v1.1, §5.3 e §19.6.

O cadastro público é desativado. O primeiro Admin é a única identidade cujo
papel é atribuído fora da interface, numa operação privilegiada feita uma única
vez por ambiente. Os demais usuários são convidados pelo Admin (Edge Function
`provision-user`).

## Pré-requisitos

- Projeto Supabase **correto** (desenvolvimento ou produção), com as migrations aplicadas.
- Acesso ao painel do projeto e ao SQL Editor (papel `postgres`).
- Um aplicativo autenticador (TOTP) no celular do responsável.

## Passos

1. **Convidar a conta Auth.** Painel → Authentication → Users → *Invite user*,
   com o e-mail do Admin. Não use *Create user* com senha digitada por
   terceiros. O gatilho `on_auth_user_created` cria o perfil com status `pending`.

2. **Atribuir o papel.** No SQL Editor:

   ```sql
   select private.bootstrap_first_admin('email-do-admin@dominio');
   ```

   A função:
   - serializa execuções concorrentes (`pg_advisory_xact_lock`);
   - exige que o e-mail normalizado corresponda a **exatamente um** usuário Auth;
   - **recusa** executar se já existir qualquer outro Admin, ativo ou pendente;
   - é idempotente para o mesmo alvo: reexecutar não duplica nada nem muda senha ou política;
   - recusa alvo bloqueado ou membro de núcleo financeiro;
   - registra auditoria (`administrators`/`profiles`), sem credenciais.

   O perfil **continua `pending`**: atribuir o papel não ativa a conta.

3. **Aceitar o convite.** O Admin abre o link do e-mail e define a senha. O
   gatilho `on_auth_user_credentials_changed` só ativa o perfil quando há
   provisionamento autorizado, e-mail comprovado e senha definida (B8, §19.2).

4. **Ativar MFA.** O Admin entra no app e cadastra o fator TOTP. Até lá, a
   sessão é `aal1` e **nenhuma** operação ou leitura administrativa funciona
   (`whoami.can_administer = false`).

5. **Registrar a evidência** em `docs/evidencias/`: data, ambiente, quem
   executou e resultado. Nada de senha, e-mail completo ou print com token.

## Depois do bootstrap (item 6 da §19.6)

A função fica inerte assim que existe um registro em `administrators`: ela
recusa qualquer outro alvo. Como o dono do banco não consegue revogar
`EXECUTE` de si mesmo, a restrição é procedimental. A função só pode ser usada
com este documento, e cada execução gera auditoria.

**Pendente:** o procedimento de recuperação do único Admin (perda de MFA ou de
acesso) ainda será escrito e testado, separado deste bootstrap.

## Garantias verificadas por teste

| Garantia | Onde |
|---|---|
| Mesmo alvo é idempotente; e-mail normalizado | pgTAP |
| Outro alvo é negado mesmo com o Admin ainda pendente | pgTAP |
| E-mail inexistente é negado | pgTAP |
| Admin atribuído continua `pending` até aceitar o convite | pgTAP |
| Duas execuções concorrentes: a segunda espera a trava e é negada; só um Admin | integração (`bootstrap-concurrency.test.ts`) |
| `anon` e `authenticated` não executam o bootstrap | pgTAP |
| Admin `aal1` não administra | pgTAP e integração |
