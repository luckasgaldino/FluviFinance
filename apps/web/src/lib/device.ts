// Desktop × celular (v2.2 §3): só decide a experiência (tela de chegada, sidebar ou gaveta).
// Não é fronteira de segurança — o desbloqueio financeiro vale para todos os clientes.
import { useSyncExternalStore } from "react";

const QUERY = "(min-width: 900px)";

export const isDesktop = () => typeof window !== "undefined" && window.matchMedia(QUERY).matches;

function subscribe(onChange: () => void) {
  const mq = window.matchMedia(QUERY);
  mq.addEventListener("change", onChange);
  return () => mq.removeEventListener("change", onChange);
}

export const useIsDesktop = () => useSyncExternalStore(subscribe, isDesktop, () => false);

/** Tela de chegada do usuário financeiro: dashboard no desktop, inicial discreta no celular. */
export const userHome = () => (isDesktop() ? "/painel" : "/inicio");
