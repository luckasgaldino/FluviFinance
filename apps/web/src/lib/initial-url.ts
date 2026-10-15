// Captura o fragmento da URL ANTES de o supabase-js consumi-lo: links de convite
// e recuperação inválidos, expirados ou de conta bloqueada chegam como
// #error=...&error_code=...&error_description=...
// Este módulo precisa ser o primeiro import de main.tsx e de supabase.ts.
const hash = new URLSearchParams(window.location.hash.slice(1));

export const initialLink = {
  type: hash.get("type"),
  errorCode: hash.get("error_code"),
  errorDescription: hash.get("error_description"),
};
