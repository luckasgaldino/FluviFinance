# Rate limiting

Referência: Especificação v1.1, §19.5 e §19.8 (D3).

## Duas camadas

| Camada | Cobre | Onde se configura | Comprovação |
|---|---|---|---|
| **Supabase Auth** | login por senha, recuperação de senha, envio de e-mails, verificação de tokens, refresh | `[auth.rate_limit]` e `[auth.email]` no `config.toml` (local); painel Auth → Rate Limits (hospedado) | intervalo mínimo entre e-mails ao mesmo destinatário **testado localmente**; limite de login **só verificável no hospedado** |
| **Fluvi (banco)** | RPCs administrativas, convites por Admin, convites para o mesmo e-mail | tabela `private.rate_limit_policies` | **testado localmente**: contagem, concorrência, expiração e HTTP 429 |

### Limitação encontrada na stack local

A stack local (Supabase CLI 2.118.0) **não aplica** limite às tentativas de
login por senha. Em 94 tentativas seguidas, todas devolveram 400 e nenhuma 429.
O limite de e-mails também vem praticamente desligado (`GOTRUE_RATE_LIMIT_EMAIL_SENT=360000`).

Por isso:

- o limite de login **não está comprovado** e precisa ser configurado e testado
  no projeto hospedado (D7) antes de qualquer uso real;
- o Fluvi não tenta "reimplementar" o limite de login com um proxy, porque o
  endpoint do Auth continua público e um proxy seria contornável.

A camada de banco não substitui a do provedor (§19.5). As duas são necessárias.

## Limites do Fluvi (padrão)

| `bucket_kind` | Limite | Janela | Chave |
|---|---|---|---|
| `admin_rpc` | 120 | 10 min | Admin (`auth.uid()`) |
| `invite_actor` | 20 | 1 h | Admin que convida |
| `invite_email` | 3 | 1 h | e-mail de destino (normalizado) |

- Ao exceder, a resposta é `PT429`, que o PostgREST e a Edge Function devolvem como **HTTP 429**.
- A janela é fixa: na virada dela podem passar até 2× o limite em sequência.
  É aceitável para estes volumes.
- O contador participa da transação. Se a operação falha e é revertida, a
  tentativa também é. Tentativas negadas não inflam o contador.
- Repetir o mesmo `operation_id` (idempotente) não consome o limite de convite.
- As janelas anteriores de cada chave são removidas no próximo uso. A varredura
  geral entra com os jobs agendados.

Para ajustar um limite (operação privilegiada, registrar em evidência):

```sql
update private.rate_limit_policies set max_hits = 60 where bucket_kind = 'admin_rpc';
```

## A verificar no projeto hospedado (D7)

- [ ] Rate limits do Auth: sign-in/sign-up, token verifications, e-mails enviados (com SMTP próprio).
- [ ] Repetir o teste de abuso de login: N tentativas erradas → 429.
- [ ] Proteção de senhas vazadas: depende de plano. Fica mantida a exigência de composição, por decisão de 15/10/2026.
