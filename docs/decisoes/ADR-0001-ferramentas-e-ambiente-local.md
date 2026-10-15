# ADR-0001 — Ferramentas, versões e ambiente local

- **Status:** aceita (Marco A, entrega 1); ratificada pela Especificação v1.1 (§4.2, §19.1 A1–A2) · **Data:** 14/10/2026
- **Emenda (15/10/2026):** o projeto hospedado `fluvi-dev` roda **PostgreSQL 17.11**, e o local roda 17.6
  (imagem do CLI 2.118.0). Mesma major. A compatibilidade foi verificada rodando a suíte pgTAP
  completa no hospedado (137/137) e restaurando um backup dele na imagem 17.6 (fotografia idêntica +
  pgTAP 137/137). Reavaliar ao subir o CLI. CI: ver `docs/evidencias/2026-10-15-marco-a-d6-d7.md`.

## Contexto

A especificação (§4) indica Node 24.19.0 e pnpm 10.33.4 como candidatos, fixados
só depois de confirmar o build e proíbe `latest` e múltiplos lockfiles. A máquina
de desenvolvimento já roda outra stack Supabase local (`lf-portal`) nas portas
padrão 543xx.

## Decisão

| Item | Versão fixada | Observação |
|---|---|---|
| Node | 24.19.0 | `.nvmrc` e `engines` (com `engine-strict`) |
| pnpm | 12.8.1 | **diverge** do candidato 10.33.4. É a versão instalada, publicada em 28/09/2026, e o workspace e o lockfile funcionam com ela. Voltar para a 10.x exigiria rebaixar a ferramenta global sem nenhum ganho. |
| Supabase CLI | 2.118.0 | devDependency (versão estável mais recente com mais de 2 semanas) |
| PostgreSQL local | 17.6 (imagem do CLI) | precisa ser igual à versão dos projetos remotos, a confirmar quando eles forem criados |
| @supabase/supabase-js | 2.117.2 | igual nos testes e na Edge Function |
| Vitest | 5.0.2 | |
| pg | 8.23.0 | só nos testes, para fixtures privilegiadas locais |

- `project_id = "fluvi"` e portas **553xx** (API 55321, DB 55322, Mailpit 55324),
  para conviver com o `lf-portal` sem interferência.
- Studio, Storage, Realtime e Analytics ficam **desligados** localmente até algum
  marco precisar deles, porque a VM do Docker tem 4 GB. O Storage volta no Marco B (anexos).

## Consequências

- O CI usa a versão do pnpm declarada em `packageManager`.
- Atualizar qualquer versão exige uma nova ADR ou uma emenda a esta.
