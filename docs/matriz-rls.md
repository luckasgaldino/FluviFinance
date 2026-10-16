# Matriz RLS e de privilégios

Referência: Especificação v1.1 (§5.2, §19.3, §19.9) e v2.2 (§2: a família é a única titular; remodelagem R2).

Legenda: **S** = select · **I/U/D** = insert/update/delete diretos · **RPC** = só por função.
`aal2` = sessão com MFA verificado. "Ativo" = `status = 'active'` com `activation_completed_at` preenchido.

| Tabela | anon | Usuário financeiro ativo | Pendente / bloqueado | Admin aal1 | Admin aal2 | Escrita |
|---|---|---|---|---|---|---|
| `profiles` | — | S: próprio + membros **ativos** dos seus núcleos; U: só `display_name` do próprio | S: só o próprio; sem U | S: próprio | S: todos | status e provisionamento só por RPC ou gatilho |
| `administrators` | — | S: própria linha (vazia) | idem | S: própria | S: todas | bootstrap manual |
| `households` (famílias) | — | S: famílias em que é membro ativo | — | — | S: todos | RPC |
| `household_members` | — | S: membros das suas famílias | — | — | S: todos | RPC |
| `data_grants` | — | S: grants em que é dono ou beneficiário (histórico; desde a v2.2 não concede acesso) | — | — | S: todos | nenhuma (RPC revogada na R2) |
| `admin_operations` | — | — | — | — | S | RPC/serviço |
| `audit_events` | — | S: eventos dos quais é ator | S: idem | S: idem | S: todos | só gatilhos; sem I/U/D para papéis de aplicação |
| financeiras (`family_id`) | — | S: via `can_access_family` — membro ativo de família ativa **e** desbloqueio financeiro vigente da sessão para a família (R3) | — | — | — | RPC/transação; criar não exige desbloqueio |
| `private.financial_unlocks` | — | — (schema privado) | — | — | — | só `unlock_finance`/`touch_finance`/`lock_finance` e gatilhos de invalidação |
| `private.rate_limit_*` | — | — | — | — | — | só funções internas (schema não exposto) |

## RPCs (catálogo da §19.3)

| Função | EXECUTE | Verificação interna |
|---|---|---|
| `whoami()` | authenticated | resposta fixa e mínima sobre o próprio usuário |
| `unlock_finance(família)` | authenticated | membro ativo; sessão válida; `amr` de senha com menos de 2 min; um desbloqueio por sessão |
| `touch_finance()` / `lock_finance()` / `finance_status()` | authenticated | só a própria sessão; status não renova |
| `quick_entry_options(família)` | authenticated | membro ativo; só id e apelido (sem valores) |
| `my_families()` | authenticated | famílias em que o chamador ativo é membro ativo (substitui `accessible_owners`, removida na R2) |
| `admin_create_household` | authenticated | `assert_admin` (aal2) |
| `admin_set_user_status` | authenticated | `assert_admin`; não altera a si mesmo; não deixa o sistema sem Admin ativo; `active` só para quem já concluiu a ativação |
| `admin_set_household_member` | authenticated | `assert_admin`; gatilho impede Admin em família; suspensão corta o acesso à família na hora |
| `admin_set_data_grant` | nenhum (revogado na R2) | permissões individuais descontinuadas pela v2.2 |
| `service_provision_begin` / `_identity` / `_profile` | service_role | ator Admin ativo verificado; a Edge Function verifica aal2 antes |
| `private.bootstrap_first_admin` | nenhum (só dono do banco) | trava, alvo único, recusa outro Admin, idempotente |
| `private.admin_recovery_reset_mfa` / `_replace` | nenhum (só dono do banco) | motivo obrigatório, trava, encerra sessões, auditoria ([procedimento](operacao/recuperacao-admin.md)) |

Toda RPC `admin_*` consome o limite `admin_rpc`. `service_provision_begin`
consome `invite_actor` e `invite_email`. Acima do limite, a resposta é HTTP 429
([rate limiting](operacao/rate-limiting.md)).

## Cobertura por teste (§19.9)

| Cenário §19.9 | pgTAP | Integração |
|---|---|---|
| Titular bloqueado com grant ativo | ✔ | ✔ |
| CREATE sem READ (inclusive `RETURNING`) | ✔ | — |
| UPDATE/CANCEL sem READ | ✔ | — |
| Membership suspenso, sessão antiga não lê | ✔ | — |
| `display_name` de outro núcleo ou pendente invisível | ✔ | ✔ |
| Participante lê o grant e não altera | ✔ | ✔ |
| Revogação: `revision` sobe, nenhum vigente, auditoria preservada | ✔ | ✔ |
| Convite não aceito / sessão por magic link continua sem acesso | ✔ | ✔ |
| Mesmo `operation_id` com payload diferente: 409, sem efeito parcial | ✔ | ✔ |
| Retomada só de identidade vinculada; ativo alheio dá 409 | — | ✔ |
| Admin aal1 sem RPC administrativa | ✔ | ✔ |
| Bootstrap repetido, outro alvo, concorrência | ✔ (repetido, outro alvo) | ✔ (concorrência) |
| `admin_*`, `service_*` e bootstrap como anon ou usuário comum | ✔ | ✔ (`service_*`) |
| Auditoria: INSERT/UPDATE/DELETE negados; Admin MFA lê | ✔ | ✔ |
| Signup bloqueado, login por e-mail ok, convite ok | — | ✔ |
| Recuperação de senha (fluxo, uso único, expiração, sem enumeração) | — | ✔ |
| Rate limit: limite, concorrência, expiração, 429 | ✔ | ✔ |
| Exclusão de identidade com grants | ✔ | — |
| Isolamento e pgTAP no banco **restaurado** | — | ✔ (`pnpm backup:drill`) |
| Bloqueado não altera perfil nem lê os próprios dados | ✔ | ✔ |

Teste de mutação: as regressões de política aberta, de bootstrap sem trava, de
ativação sem senha e de nomes de pendentes visíveis foram todas detectadas.
Detalhes em `docs/evidencias/`.
