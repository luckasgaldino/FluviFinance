# Recuperação do único Admin

Referência: Especificação v1.1, §19.6 (último parágrafo). Procedimento manual,
separado do bootstrap, feito por quem tem acesso privilegiado ao projeto
(SQL Editor, papel `postgres`). As funções não têm `EXECUTE` para nenhum papel da
aplicação.

## Antes de qualquer passo

1. **Abra um registro de incidente**, fora do sistema, com data, quem solicitou,
   quem executa e o motivo.
2. **Confirme a identidade do solicitante por um canal independente** (presencial
   ou telefone já conhecido), nunca só pelo e-mail da conta afetada.
3. Se houver suspeita de comprometimento, troque a senha da conta pelo painel
   **antes** de reabilitar o MFA. Caso contrário, quem tiver a senha cadastra o próprio TOTP.

## Caso 1 — Admin perdeu o dispositivo TOTP

```sql
select private.admin_recovery_reset_mfa('email-do-admin@dominio', 'motivo + nº do incidente');
```

O que a função faz:

- remove os fatores MFA do Admin;
- encerra todas as sessões dele;
- registra `recovery_reset_mfa` na auditoria (o motivo vai como digest).

Em seguida, o Admin entra com a senha. A sessão é `aal1`, ainda **sem poderes**.
O Admin cadastra um novo TOTP e passa a `aal2`.

## Caso 2 — Admin perdeu a conta ou o e-mail, ou a conta foi comprometida

1. Convide pelo painel a nova identidade que será Admin (*Invite user*).
2. Execute:

   ```sql
   select private.admin_recovery_replace('email-antigo@dominio', 'email-novo@dominio', 'motivo + nº do incidente');
   ```

   A função:
   - **desativa** o papel do Admin antigo e **bloqueia** o perfil dele;
   - encerra as sessões do Admin antigo;
   - atribui o papel à nova identidade, com as mesmas guardas do bootstrap:
     alvo único, não membro de núcleo, não bloqueado, ainda sem papel;
   - recusa executar se existir outro Admin ativo (nesse caso, use a interface);
   - registra `recovery_replace_admin` na auditoria.

3. O novo Admin aceita o convite e define a senha. O perfil é ativado
   automaticamente, e o Admin cadastra o TOTP.

## Depois

- Registre a evidência em `docs/evidencias/`, sem e-mails completos nem tokens.
- Revise a auditoria do período suspeito.
- Para remover de vez a conta antiga, faça a exclusão no Auth. Os vínculos e
  grants caem em cascata e a auditoria permanece.

## Garantias verificadas por teste (pgTAP, `02_rate_limit_admin_recovery.test.sql`)

- Usuários da aplicação não executam nenhuma das duas funções.
- As duas exigem motivo com no mínimo 10 caracteres.
- O reset só vale para Admin ativo, remove os fatores e encerra as sessões.
- A substituição desativa e bloqueia o antigo e ativa o sucessor.
- As duas operações ficam registradas na auditoria.
