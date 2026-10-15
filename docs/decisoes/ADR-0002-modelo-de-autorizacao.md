# ADR-0002 — Modelo de autorização (titular, núcleo, grants, Admin)

- **Status:** aceita; revisada para a Especificação v1.1 · **Datas:** 14/10/2026 (entrega 1), 15/10/2026 (revisão v1.1)
- **Referências:** Especificação v1.1 §5, §10.1 (itens 1, 2, 6, 7), §10.2, §19.1–§19.6

## Decisão

1. **Negar por padrão em duas camadas.** Os privilégios SQL começam zerados para
   `anon` e `authenticated` (inclusive para objetos futuros, via
   `alter default privileges`), e toda tabela exposta tem RLS. Uma tabela nova sem
   `grant` explícito fica inacessível, mesmo que alguém esqueça a política.

2. **Um único ponto de decisão financeira:** `private.can_access_owner(owner, scope, op)`.
   Toda tabela financeira dos próximos marcos usa esse padrão de política:

   ```sql
   using      (private.can_access_owner(owner_user_id, '<escopo>', 'read'))
   with check (private.can_access_owner(owner_user_id, '<escopo>', 'create'))
   ```

   A função retorna verdadeiro quando:
   - o chamador é o **titular** e é um usuário financeiro ativo; ou
   - existe um **grant vigente** (não revogado) do titular para o chamador, no
     escopo pedido ou em `all`, com o flag da operação, e: o núcleo está ativo,
     ambos são membros ativos dele e ambos têm perfil ativo (B1).

   "Perfil ativo" (`private.is_active_profile`) exige `status = 'active'` **e**
   `activation_completed_at` preenchido. É a guarda transversal da §19.2.

3. **Estado persistido, avaliado a cada consulta.** Bloqueio de perfil, suspensão
   de vínculo e revogação de grant valem imediatamente, mesmo com um JWT ainda
   válido. Nada vem de `user_metadata` nem de `app_metadata`.

4. **Admin sem acesso financeiro.** Identidades administrativas não podem ser
   membros de núcleo (trigger) e são excluídas de `can_access_owner`, inclusive
   como titulares (B10). Administrar exige perfil ativo, papel ativo **e sessão
   `aal2`** (MFA). Nenhuma operação pode deixar o sistema sem Admin ativo, e o
   Admin não altera o próprio status.

5. **Escritas de identidade só por RPC.** `data_grants`, `household_members`,
   `administrators`, o status de perfil e os campos de provisionamento não têm
   privilégio de escrita para `authenticated`. As RPCs `admin_*` são
   `security definer` com `search_path` vazio, chamam `private.assert_admin()`,
   são idempotentes por `request_id` e geram auditoria. `admin_set_data_grant`
   aceita `p_expected_revision` para controle otimista: divergência gera `40001`.

6. **Ativação (B8, §19.2).** Estados: `pending`, `active` e `blocked`.
   - Todo usuário Auth nasce `pending`.
   - O provisionamento (convite do Admin ou bootstrap) grava `provisioned_at`,
     mas **não ativa**.
   - A promoção para `active` é feita só pelo gatilho
     `on_auth_user_credentials_changed` (em `auth.users`), quando três condições
     valem ao mesmo tempo: provisionamento autorizado, e-mail comprovado
     (`email_confirmed_at`) e senha definida. Isso grava `activation_completed_at`.
   - Um constraint impede `active` sem `activation_completed_at`. Portanto o
     Admin não ativa ninguém manualmente, mas pode reativar um bloqueado que já
     tinha sido ativado.
   - Uma sessão obtida por caminho alternativo (ex.: magic link) sem senha
     definida continua `pending` e sem acesso.

7. **Provisionamento em duas fases (B13, §19.2).**
   - `service_provision_begin` reserva o `operation_id` como `pending` em
     `admin_operations` **antes** do e-mail de convite.
   - O usuário Auth nasce com `fluvi_provision_operation_id` no metadata, e o
     gatilho copia esse valor para `profiles.provision_operation_id`. A coluna é
     gravada só na criação e não é editável pelo usuário.
   - Na retomada, só se reaproveita a identidade `pending` vinculada à **mesma**
     operação. Identidade pendente de outra origem gera 409 `identity_conflict`,
     e e-mail de usuário ativo gera 409 `already_provisioned`.

8. **Escolhas ratificadas na v1.1 (B1–B7, B9, B10, B12):**
   - Se o titular estiver bloqueado, os grants dele param de valer.
   - `can_update` e `can_cancel` exigem `can_read` (constraint).
   - `can_create` sem `can_read` é permitido, mas o registro criado não volta ao
     beneficiário: `INSERT … RETURNING` é negado pela RLS. As RPCs financeiras do
     Marco B devolverão só uma referência opaca nesse caso.
   - Suspender ou remover um vínculo revoga os grants que dependiam dele.
   - O usuário vê o `display_name` só de membros ativos, com perfil ativo, dos
     próprios núcleos. Pendentes, bloqueados, outros núcleos e o Admin não aparecem.
   - O usuário vê os grants em que é dono ou beneficiário, sem poder alterá-los.

9. **Auditoria (B11, §19.4).**
   - Os eventos são inseridos só por gatilhos `security definer` e guardam apenas
     digests do estado antes e depois.
   - Papéis de aplicação não têm `INSERT`, `UPDATE` nem `DELETE`, e um gatilho
     recusa `UPDATE`/`DELETE` pelos caminhos normais.
   - **Não é garantia absoluta**: o dono ou superusuário do banco pode alterar o
     próprio gatilho. A proteção contra administradores de infraestrutura
     depende de cópia externa append-only, ainda a definir junto com o backup (D1).
   - O usuário vê os eventos dos quais é ator. O Admin com MFA vê todos. A
     exibição sanitizada de eventos de terceiros sobre os dados do usuário ainda
     é política de produto a definir.

## Consequências

- Uma consulta consolidada nunca agrega linhas não autorizadas, porque a RLS
  filtra antes da agregação. As views de BI (Marco D) precisam ser
  `security_invoker`.
- Recuperação excepcional com acesso a dados financeiros não passa pelo painel:
  é uma operação de banco documentada e auditada, a definir no gate de produção.
- **Retenção de `admin_operations`:** a proposta é de 400 dias. O expurgo entra
  junto com os jobs agendados e ainda não foi implementado.
- **Concorrência na mesma operação:** dois `provision-user` simultâneos com o
  mesmo `operation_id` podem reenviar o convite, mas nunca criam dois usuários
  nem dois vínculos. O efeito é aceitável e está documentado.
