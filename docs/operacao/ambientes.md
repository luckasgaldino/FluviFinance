# Ambientes hospedados

Referência: Especificação v1.1, §4 (ambientes), §14 (custos) e §19.8 (D7).

## Situação (15/10/2026)

| Ambiente | Supabase | Frontend | Dados | Estado |
|---|---|---|---|---|
| Local | stack do CLI (portas 553xx) | Vite 127.0.0.1:5173 | fictícios | em uso |
| **Desenvolvimento** | `fluvi-dev` (ref `wovocbnnpvsxndwjghco`, sa-east-1, Free, Postgres 17.11) | **https://fluvi-dev.pages.dev** (Cloudflare Pages, deploy pelo workflow `deploy-dev.yml`) | **somente fictícios** | Marco A completo + **banco do Marco B** (deploy controlado em 15/10/2026); jobs `pg_cron` ativos; frontend do Marco A |
| Produção | **não criado**, por decisão de 15/10/2026 | — | reais, só após o gate §10 | criar perto do gate |

O projeto de desenvolvimento **não recebe dados reais**. A separação de
ambientes não transforma o dev em produção (§12).

## Fornecedores, cotas e custos (§14)

Valores consultados em 15/10/2026 nas páginas oficiais. São estimativas, não
contratos; reconferir antes de cada decisão de custo.

| Fornecedor / recurso | Plano | Custo atual | Limites relevantes | Risco operacional |
|---|---|---|---|---|
| Supabase `fluvi-dev` | Free | US$ 0 | 2 projetos ativos por organização (o PortalLF ocupa 1); 500 MB de banco; 50 mil MAU; **pausa após 7 dias sem uso**; **sem backup automático**; sem proteção contra senhas vazadas | pausa: reativar pelo painel. Backup: coberto pelo backup próprio (abaixo) |
| Supabase produção (futuro) | Pro (proposta) | ~US$ 25/mês + compute (Micro ~US$ 10, coberto pelo crédito do Pro) | backup diário de 7 dias, sem pausa, proteção contra senhas vazadas; PITR é adicional (~US$ 100/mês) | **exige aprovação de custo** |
| Cloudflare Pages | Free | US$ 0 | limites de builds e implantações a confirmar no painel | baixo |
| Cloudflare R2 (destino dos backups) | Free | US$ 0 até 10 GB-mês | 1 mi de operações classe A e 10 mi classe B por mês; sem custo de saída | baixo. Backup de ~0,2 MB/dia |
| GitHub Actions | repositório público | US$ 0 | — | o CI roda em push |
| SMTP próprio (e-mails de Auth) | **não contratado** | — | o SMTP padrão do Supabase só entrega para membros da equipe do projeto, com cota mínima | **convites e recuperação no hospedado não chegam a usuários reais** até haver SMTP |

Fontes: [Supabase Pricing](https://supabase.com/pricing),
[Supabase — Project Pausing](https://supabase.com/docs/guides/platform/free-project-pausing),
[Cloudflare R2 Pricing](https://developers.cloudflare.com/r2/pricing/).

## Como o `fluvi-dev` foi configurado (reprodutível)

Credenciais fora do repositório, em `%USERPROFILE%\.fluvi\` (senha do banco e
chave de backup). Guarde cópias no seu gerenciador de senhas.

```bash
pnpm exec supabase link --project-ref wovocbnnpvsxndwjghco    # SUPABASE_DB_PASSWORD no ambiente
pnpm exec supabase db push                                     # migrations
pnpm exec supabase config diff && pnpm exec supabase config push   # Auth endurecido (signup off, senha ≥ 12, hook, MFA)
pnpm exec supabase secrets set FLUVI_ALLOWED_ORIGINS="<origens do frontend>"
pnpm exec supabase functions deploy provision-user --use-api
pnpm exec supabase test db --linked                            # pgTAP no hospedado (transação revertida)
pnpm --filter @fluvi/tests test:remote                         # Auth hospedado (FLUVI_REMOTE_* do dev)
```

## Ações manuais pendentes no painel do Supabase

- [x] **Provedor de telefone desligado** (15/10/2026). Verificado em `/auth/v1/settings` (`external.phone = false`) e por tentativa de OTP recusada. O `config diff` continua mostrando `sms.twilio.enabled = true`, mas isso indica só o provedor de SMS selecionado, não o login por telefone ligado.
- [ ] Configurar **SMTP próprio**, que exige escolher um provedor e um domínio
  remetente. Sem isso, convites e recuperação não chegam a e-mails reais.
- [x] `site_url` e redirects do dev apontam para https://fluvi-dev.pages.dev (`[remotes.fluvi-dev]` no config.toml).
- [x] CORS da Edge Function: só https://fluvi-dev.pages.dev e o Vite local. Origem estranha não recebe `Access-Control-Allow-Origin` (verificado).
- [x] Cabeçalhos no domínio publicado: CSP, HSTS, X-Frame-Options DENY, Referrer-Policy (verificado com curl).
- [x] Bucket R2 privado `fluvi-backups-dev` criado pelo deploy, com regra `expira-35-dias` (verificado no log de 15/10/2026). R2 ativado pelo responsável com cartão cadastrado; uso esperado dentro da faixa gratuita.
- [x] **Localização do backup (decisão do responsável, 15/10/2026):** manter o R2 na América do Norte (WNAM). Alternativas em São Paulo (AWS S3, Magalu Cloud, Oracle) foram apresentadas e recusadas. Salvaguarda: cifragem AES-256-GCM antes do envio, com a chave fora do Cloudflare. **Para o gate (§10.1 item 8):** registrar a transferência internacional e a base do art. 33 da LGPD.
- [x] **Backup diário operando:** a primeira execução em 15/10/2026 enviou e confirmou `fluvi-dev/2026-10-15T15-34-48-405Z.dump.enc`. **O agendamento diário só passa a valer quando o workflow estiver na branch `main`.**
