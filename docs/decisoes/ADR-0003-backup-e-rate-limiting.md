# ADR-0003 — Backup cifrado, exercício de restauração e rate limiting

- **Status:** aceita (Marco A, D1/D2/D3) · **Data:** 15/10/2026
- **Referências:** Especificação v1.1 §10.1 (itens 1, 5), §14, §19.5, §19.6, §19.8

## Decisões

1. **Backup lógico (`pg_dump -Fc`) dos schemas `auth`, `public`, `private` e
   `supabase_migrations`**, gerado pela mesma imagem do banco e cifrado com
   AES-256-GCM antes de tocar o disco. A chave fica fora do repositório
   (`FLUVI_BACKUP_KEY`). Os scripts usam só Node e Docker, sem dependências.
   - *Por quê:* o backup do plano Free não deve ser considerado gerenciado
     (§14), e o formato lógico restaura em qualquer PostgreSQL 17 compatível.

2. **Manifesto com fotografia verificável** (contagens, digests de linhas,
   migrations, políticas, funções, gatilhos). A restauração só é aceita se a
   fotografia for idêntica.
   - Comprovado por teste negativo: uma linha apagada no restaurado foi
     detectada, e um byte adulterado no backup foi rejeitado pela tag GCM.

3. **Exercício de restauração isolado e reproduzível** (`pnpm backup:drill`).
   O container não tem Auth, e-mail nem push. No restaurado rodam testes de
   acesso com JWT simulado e a suíte pgTAP completa.

4. **Rate limiting em duas camadas.** A do Auth do provedor (login, recuperação,
   e-mails) é obrigatória, mas não se comprova localmente: a stack local não a
   aplica. A camada do Fluvi fica no banco, com janela fixa e upsert atômico, e
   responde `PT429` (HTTP 429). Não há proxy de login, porque o endpoint do Auth
   continua público.

5. **Recuperação do único Admin** por duas funções privilegiadas sem `EXECUTE`
   para a aplicação (reset de MFA e substituição). Ambas exigem motivo, usam
   trava, encerram sessões e geram auditoria.

6. **`data_grants.created_by`/`revoked_by` sem FK.** Com FK, excluir uma
   identidade (inclusive por pedido do titular) violava a integridade, conforme
   a ordem das cascatas. A autoria fica preservada em `audit_events`.

7. **Regra de senha:** mantida a exigência padrão de composição (maiúscula,
   minúscula, dígito) com mínimo de 12 caracteres, por decisão do responsável
   em 15/10/2026. A checagem de senhas vazadas não será contratada agora.

## Consequências

- O D1 só fica completo para uso real quando houver agendamento diário,
  destino externo, monitoramento e o exercício repetido contra um backup do
  projeto remoto (D7).
- O D3 só fica completo quando os limites do Auth forem verificados no projeto hospedado.
- Os testes de integração mudam políticas de rate limit temporariamente e as restauram ao final.
