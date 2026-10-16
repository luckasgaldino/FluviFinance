# Evidência — Remodelagem v2.2, fase R5 (convite e aceite de família)

**Data:** 16/10/2026 · **Branch:** `remodelagem/r5-convites`

## O que entrou

- **`20261017000400_member_invited.sql`:** novo estado `invited` no vínculo. Fica em migração própria porque um valor novo de enum não pode ser usado na mesma transação em que é criado.
- **`20261017000500_family_invites.sql`:**
  - `household_members` ganha `invited_at`, `invited_by` e `accepted_at`; os vínculos ativos existentes contam como aceitos.
  - **O admin convida:** vincular alguém, ou reativar um vínculo suspenso ou removido, grava `invited`. Nada é liberado antes do aceite. Identidade administrativa não pode ser convidada.
  - **Provisionar usuário novo indicando a família também gera convite.**
  - `my_family_invites()`, `accept_family_invite(família)` e `decline_family_invite(família)`: só a própria pessoa aceita ou recusa; ninguém aceita convite alheio.
- **Web:**
  - Na área financeira, quem ainda não tem família vê os convites. O mesmo aparece em Configurações.
  - O aviso diz claramente que, ao aceitar, a pessoa verá **todo o histórico** da família e que o que ela lançar será visível a todos.
  - Botões Aceitar e Recusar. Ao aceitar, a família vira a ativa.
  - Admin: "Famílias e membros" (antes "Núcleos e vínculos"), com Convidar, Cancelar convite, Suspender e Convidar de novo. O estado "Convite pendente" aparece como selo.

## Cenários

| Cenário | Onde | Resultado |
|---|---|---|
| FAM-03: vincular gera convite, sem acesso antes do aceite | pgTAP 01, integração | ok |
| Aceite libera; realocação não leva histórico | pgTAP 01 | ok |
| Voltar após suspensão exige novo aceite | pgTAP 01, integração | ok |
| Ninguém aceita convite alheio; recusar não libera | pgTAP 01 | ok |
| Usuário convidado por e-mail com família: ativa a conta, vê o convite com o aviso e aceita; o dashboard libera | E2E `admin-flow` (com axe) | ok |
| Admin não pode ser convidado | pgTAP 01 | ok |

## Testes (local)

| Suíte | Resultado |
|---|---|
| pgTAP | **392/392** |
| Integração | **58/58** |
| E2E | **42/42** |
| Unitários | 33/33 |
| Build e `db lint` | ok |
| Exercício de restauração | **PASS** (392 pgTAP no restaurado) |

**Observação:** o convite por Edge Function no E2E passou de 10 s uma vez (G4, ver evidência da PWA). A espera desse passo foi para 30 s, com o motivo registrado; o G4 continua aberto, agora mitigado.
