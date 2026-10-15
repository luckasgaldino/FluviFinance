# Backup e restauração

Referência: Especificação v1.1, §10.1 item 5, §14 e §19.8 (D1). Decisões técnicas em [ADR-0003](../decisoes/ADR-0003-backup-e-rate-limiting.md).

## O que é copiado

| Item | Incluído | Observação |
|---|---|---|
| Schemas `auth`, `public`, `private`, `supabase_migrations` | sim | usuários, fatores MFA, perfis, núcleos, grants, auditoria, histórico de migrations |
| Bytes de arquivos (Storage) | **não se aplica ainda** | o Storage está desligado no Marco A. Entra junto com os anexos no Marco B |
| Extensões exigidas (`btree_gist`) | recriadas na restauração | listadas no manifesto (`required_extensions`) |
| Agendamentos (`cron`) | não | reagendar após restaurar (checklist abaixo) |
| Papéis do banco | não | o Fluvi não cria papéis próprios; a plataforma Supabase fornece os papéis |
| Segredos (Vault), chaves de API | não | os segredos ficam no provedor e no gerenciador de segredos, nunca no backup |

O formato é um `pg_dump -Fc` cifrado com **AES-256-GCM**, com chave de 32 bytes
em `FLUVI_BACKUP_KEY`. Ao lado de cada backup fica um `*.manifest.json` com
sha256 do conteúdo, versão do PostgreSQL, lista de migrations, contagem de linhas,
digest das tabelas `public`, número de políticas e digest das funções. O
manifesto não contém e-mail, URL de banco nem credencial.

## Comandos

```bash
node scripts/backup.mjs --new-key        # gera uma chave: guarde no gerenciador de senhas, nunca no repositório
FLUVI_BACKUP_KEY=... pnpm backup         # backup do banco LOCAL em backups/ (retém os 14 mais recentes)
FLUVI_BACKUP_KEY=... FLUVI_BACKUP_DB_URL=... node scripts/backup.mjs --remote
                                         # backup de projeto remoto; a URL só entra por variável de ambiente
pnpm backup:drill                        # exercício completo com dados fictícios (abaixo)
FLUVI_BACKUP_KEY=... pnpm backup:drill --backup backups/<arquivo>.dump.enc
                                         # restaura e verifica um backup existente
```

## Exercício de restauração (`pnpm backup:drill`)

1. Recusa rodar se o banco local já tiver Admin gravado (rode `pnpm db:reset` antes).
2. Semeia identidades **fictícias**: Admin, Luck e Bia, um núcleo e um grant Bia→Luck.
3. Gera o backup cifrado.
4. Confere a integridade: sha256 do arquivo cifrado, tag GCM e sha256 do dump.
5. Sobe um **container isolado** (`fluvi_restore_drill`, porta 127.0.0.1:55433),
   com a mesma imagem do banco. Ele não tem Auth, Edge Functions nem SMTP, então
   **não envia e-mail nem push**.
6. Restaura com `pg_restore --clean --if-exists --exit-on-error`.
7. Compara a fotografia do restaurado com o manifesto: linhas, digests,
   migrations, RLS, políticas, funções e gatilhos de `auth.users`.
8. Testa o acesso no restaurado com JWT simulado:
   - Luck lê Bia só em `transactions`;
   - Bia não lê Luck;
   - o Admin não tem acesso financeiro;
   - o Admin `aal1` não administra;
   - `anon` é negado.
9. Roda a suíte pgTAP inteira contra o restaurado.
10. Remove as fixtures da origem e o container, e grava um relatório JSON em `backups/`.

A pasta `backups/` está no `.gitignore` e nunca é versionada.

## Ao restaurar um ambiente real (checklist da §10.2)

- [ ] Restaurar primeiro num ambiente isolado e rodar `pnpm backup:drill --backup <arquivo>`.
- [ ] Revalidar exclusões feitas depois do backup (pedidos de titulares): reaplicar antes de liberar o acesso.
- [ ] Revalidar grants, administradores e status de perfis contra o registro de incidentes.
- [ ] Confirmar que o ambiente restaurado não envia e-mail nem push antes da troca de DNS ou chaves.
- [ ] Reagendar os jobs (o schema `cron` não está no backup): `select cron.schedule(...)` conforme a migration `20261016000500_fin_rpcs_settlement.sql`. Só depois de confirmar que o ambiente restaurado é o oficial.
- [ ] Registrar a evidência em `docs/evidencias/` (sem dados pessoais).

## Pendências (não cumpridas por este documento)

| Pendência | Depende de |
|---|---|
| Agendamento **diário automático** do backup de produção | projeto remoto (D7) e escolha do executor (ex.: GitHub Actions agendado) |
| **Destino externo** ao projeto Supabase, com retenção e criptografia | sua escolha de provedor e aprovação de custo (§14) |
| Monitoramento de backup atrasado ou falho, com alerta real | destino e canal de alerta |
| RPO/RTO formais | proposta conservadora: RPO 24 h; RTO 4 h (restauração local medida em ~30 s com volume fictício, ainda sem valor real) |
| Bytes de Storage | Marco B (anexos) |

Enquanto essas pendências estiverem abertas, **não há uso com dados reais** (§14).
