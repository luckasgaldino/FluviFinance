# Remodelagem v2.2 — Etapa 0 (diagnóstico e plano aprovados)

**Data:** 15/10/2026 · **Base:** `docs/FluviFinance_Especificacao_Tecnica_Funcional_v2.2.md` e `docs/FluviFinance_Prompt_Claude_Remodelagem_v2.2.md`
**Aprovação:** usuário, 15/10/2026 ("Vamos na sua recomendação"; confirmou que o fluvi-dev não tem dados reais).

## Inventário de partida

- 14 migrations (Marco A 7, Marco B 7), 29 tabelas, ~95 funções/procedures, 5 views `security_invoker`, 28 políticas RLS.
- Testes: 312 pgTAP, 52 de integração, 29 E2E, 33 unitários.
- Ambientes: local (portas 553xx), CI e fluvi-dev (Supabase Free, Cloudflare Pages, backups diários no R2).
- Correção à §11 da v2.2: o banco do Marco B já está aplicado no fluvi-dev, com telas de Contas, Lançamentos, Cartões e Compras publicadas. Todos os dados são fictícios.

## Matriz

| Ação | Itens |
|---|---|
| Manter | Auth, ativação, bloqueio no login, rate limit, MFA do admin, auditoria, razão somente-acréscimo, anulação e reversão, parcelas (`split_cents`), ciclos e conciliação EQ-1, transferências, idempotência, jobs pg_cron, backup/restauração, CI, deploy-dev, pacote `domain` |
| Adaptar | `households`/`household_members` passam a ser a família (nome físico mantido, `invited` + aceite); `owner_user_id` → `family_id` via RENAME (FKs compostas acompanham); `can_access_owner` → `can_access_family`; categorias por família com arquivamento; pagamento de fatura via `pay_invoice`; parcelas limitadas a 1–36; telas atuais com visual novo |
| Descontinuar (sem DROP) | `data_grants` e a tela de Permissões (EXECUTE revogado); contas a pagar e recorrências saem da UI, mas o backend permanece |
| Criar | Desbloqueio financeiro no servidor, `quick_entry_options`, `edit_transaction`, dashboard e relatórios com CSV, parcelas futuras, design system escuro, shell desktop/mobile, PWA sem cache de API |

## Decisões aprovadas

1. **Desbloqueio no servidor para todos os clientes.** No desktop, o próprio login (senha recém-digitada) abre a área financeira. Depois de 15 min ocioso, pede a senha de novo sem encerrar o login. O celular segue a v2.2: tela discreta e segunda confirmação.
2. **Reautenticação** por `signInWithPassword` com a mesma senha. O banco aceita o desbloqueio se a claim `amr` (password) tiver menos de 2 min e o vincula a `session_id` + família. Plano B: Edge Function.
3. **Leitura** exige membro ativo + desbloqueio válido (RLS e RPCs). **Escrita rápida** (receita, despesa, compra no cartão, transferência) exige só membro ativo e devolve apenas `{id, status}`.
4. Atividade humana renova a janela via `touch_finance()`; polling não renova. Troca de senha, bloqueio, mudança de vínculo, logout e troca de família invalidam o desbloqueio.
5. Convite aceito dentro do app, sem depender de SMTP.
6. Testes usam famílias fictícias, sem nomes reais.
7. Nome "FluviFiance" na interface; repositório e pacotes continuam "FluviFinance".

## Roadmap

| Fase | Entrega | Aceite |
|---|---|---|
| R1 | Visual e navegação; telas novas com dados fictícios | E2E de navegação, axe, 360 px, tela discreta sem valores |
| R2 | Contratos de família no banco | FAM-01/02 e FIN-01..05 em pgTAP e integração; suítes adaptadas |
| R3 | Desbloqueio no servidor | PRIV-03/05/06/07/08/09/10 por API real |
| R4 | Fluxos integrados (lançamentos com edição, faturas e pagamento, parcelas, dashboard, relatórios com CSV) | E2E ponta a ponta; nada protegido trafega antes do desbloqueio |
| R5 | Famílias e admin (convites, vários vínculos, troca de família, revogação) | FAM-03 e testes negativos |
| R6 | PWA e homologação; deploy no fluvi-dev somente com autorização | Cache limpo, iPhone/Safari, VoiceOver, OPS-01 |

## Rollback

- Migrations aditivas. O RENAME tem migração inversa enquanto cada família tiver 1 membro; depois disso, restaura-se o backup cifrado feito antes (drill testado).
- Nenhum DROP de dados.
- No fluvi-dev, nada é aplicado sem backup prévio e sem autorização.
