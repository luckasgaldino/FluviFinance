# Evidência — Remodelagem v2.2, fase R6 (parte 1: PWA instalável sem cache)

**Data:** 16/10/2026 · **Branch:** `remodelagem/r6-pwa`

## O que entrou

- `manifest.webmanifest`:
  - nome FluviFiance, `display: standalone`, `start_url: /`, cores da marca;
  - ícones PNG 192 e 512, maskable 512, gerados do SVG da marca;
  - `apple-touch-icon` de 180.
- `index.html`: metadados de iOS (`apple-mobile-web-app-capable`, barra de status translúcida, título) e `viewport-fit=cover`. O CSS respeita as áreas seguras do iPhone (`env(safe-area-inset-*)`).
- `sw.js`: service worker **sem cache**:
  - não tem handler de `fetch`, então não intercepta nenhuma requisição;
  - ao ativar, apaga qualquer cache existente;
  - é registrado só no build de produção.

  Atende ao §3.2 item 9 e ao §7: nada financeiro em cache da PWA. O modo offline continua fora do MVP.
- `_headers`: `sw.js` e manifest com `no-cache`; o `index.html` já ia com `no-store`.

## Intermitência G4 (convite no E2E): causa encontrada e corrigida

- **Sintoma:** de vez em quando, "Convite enviado" não aparecia no E2E do admin.
- **Causa:** o edge runtime local, com a política `per_worker`, reaproveita o isolate entre requisições. Ao atingir o limite de tempo total, ele é encerrado no meio de uma requisição. O log mostrava "wall clock duration warning" seguido de "early termination", exatamente nos convites que falharam.
- **Correção:** `policy = "oneshot"` no `config.toml`, um worker por requisição. Vale só para local e CI; o hospedado tem ciclo de vida próprio.
- **Verificação:** fluxo admin 3 vezes seguidas sem falha; suíte completa verde.
- **Atualização (R5):** a lentidão voltou uma vez com `oneshot`, sem encerramento: a requisição só passou de 10 s. Em uso normal o convite leva de 0,6 a 1,3 s (medido na integração). A espera desse passo no E2E foi para 30 s, com o motivo registrado. A causa exata da latência ocasional do edge runtime local (worker novo + envio do e-mail) segue em observação; o G4 continua aberto, agora mitigado.

## Testes (local)

| Suíte | Resultado |
|---|---|
| E2E | **42/42**; novo `pwa.spec`: manifest válido e ícones servidos, metadados de iOS, service worker sem handler de `fetch`, Cache Storage vazio depois de navegar desbloqueado, nenhuma chave inesperada no `localStorage` |

## Pendente da R6 (precisa do aparelho, com o responsável)

- Instalar no iPhone (Safari → Compartilhar → Adicionar à Tela de Início).
- Validar: tela discreta, senha, 15 min, véu ao trocar de app, VoiceOver e texto ampliado.
- SMTP próprio continua pendente (decisão adiada).

## Publicação no fluvi-dev (16/10/2026, ~00:30 BRT)

Só frontend, sem migration. CI da branch verde (`67d55d1`, 38845415877). Merge na `main`: `deploy-dev` e CI verdes. No ambiente publicado, `manifest.webmanifest` (application/manifest+json), `sw.js` (`Cache-Control: no-cache`), `icon-192.png` e `apple-touch-icon.png` respondem 200.
