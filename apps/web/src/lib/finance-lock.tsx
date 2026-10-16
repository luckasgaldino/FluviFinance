// Desbloqueio financeiro (v2.2 §3.2): segunda confirmação com a MESMA senha do login para ler
// dados financeiros; vale para todas as telas até 15 min sem atividade humana, bloqueio manual,
// saída, troca de senha, revogação ou troca de família. A expiração não encerra o login.
//
// O banco é a fonte de verdade (R3): o desbloqueio fica registrado por sessão e família e é
// exigido pela RLS e pelas RPCs. Este módulo só espelha o estado para decidir o que mostrar:
// - desbloquear = login de novo com a senha (prova recente no JWT) + unlock_finance(família);
// - atividade humana chama touch_finance (no máximo a cada 30 s); leituras e polling não renovam;
// - ao voltar ao app, o estado é relido no servidor antes de mostrar dados.
// Nada é guardado no navegador: nem senha, nem estado do desbloqueio.
import { useQueryClient } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { isDesktop } from "./device";
import { useFamily } from "./family";
import { useSession } from "./session";
import { supabase } from "./supabase";

export const IDLE_LIMIT_MS = 15 * 60_000;
const TOUCH_EVERY_MS = 30_000;
const LOGIN_PROOF_MS = 60_000;

// Senha digitada no login agora há pouco: no desktop, o próprio login abre a área financeira.
let loginProofAt = 0;
const PROOF_EVENT = "fluvi:password-proof";
export const noteLoginPassword = () => {
  loginProofAt = Date.now();
  window.dispatchEvent(new Event(PROOF_EVENT));
};

type ServerState = { unlocked: boolean; family?: string; expiresAt: number };
const LOCKED: ServerState = { unlocked: false, expiresAt: 0 };

type FinanceLockValue = {
  unlocked: boolean;
  /** confere a senha com o provedor de identidade e desbloqueia a família ativa no servidor */
  unlock: (password: string) => Promise<"ok" | "wrong" | "limited" | "error">;
  /** família ativa carregada: só então dá para desbloquear */
  ready: boolean;
  lock: () => void;
  /** atividade humana em área protegida (toque, tecla, rolagem) */
  touch: () => void;
};

const FinanceLockContext = createContext<FinanceLockValue | null>(null);

type StatusResponse = { unlocked: boolean; family_id?: string; expires_in_seconds?: number };
const fromStatus = (s: StatusResponse | null): ServerState =>
  s?.unlocked ? { unlocked: true, family: s.family_id, expiresAt: Date.now() + (s.expires_in_seconds ?? 0) * 1000 } : LOCKED;

export function FinanceLockProvider({ children }: { children: ReactNode }) {
  const { session } = useSession();
  const { active } = useFamily();
  const queryClient = useQueryClient();
  const uid = session?.user.id ?? null;
  const family = active?.family_id ?? null;
  const [state, setState] = useState<ServerState>(LOCKED);
  const [now, setNow] = useState(() => Date.now());
  const lastTouch = useRef(0);
  const previousFamily = useRef<string | null>(null);
  // cada mudança de estado local incrementa a época: respostas de consultas antigas são ignoradas
  const epoch = useRef(0);

  const forget = useCallback(() => {
    epoch.current += 1;
    setState(LOCKED);
    // nada lido na área protegida sobrevive ao bloqueio
    queryClient.removeQueries({ queryKey: ["fin"] });
  }, [queryClient]);

  const refresh = useCallback(async () => {
    const started = epoch.current;
    const { data, error } = await supabase.rpc("finance_status");
    if (started !== epoch.current) return;  // um desbloqueio ou bloqueio aconteceu nesse meio-tempo
    if (error) return forget();
    const next = fromStatus(data as StatusResponse);
    if (!next.unlocked) forget();
    else setState(next);
  }, [forget]);

  const serverUnlock = useCallback(async (target: string) => {
    const { data, error } = await supabase.rpc("unlock_finance", { p_family: target });
    if (error) return false;
    const idle = (data as { idle_seconds: number }).idle_seconds;
    epoch.current += 1;
    lastTouch.current = Date.now();
    setState({ unlocked: true, family: target, expiresAt: Date.now() + idle * 1000 });
    return true;
  }, []);

  const lock = useCallback(() => {
    forget();
    void supabase.rpc("lock_finance");
  }, [forget]);

  // Usuário mudou ou saiu: começa bloqueado e consulta o servidor (recarregar a página mantém).
  useEffect(() => {
    forget();
    if (uid) void refresh();
  }, [uid, refresh, forget]);

  // Troca de família: o desbloqueio anterior é encerrado no servidor (voltar exige senha).
  useEffect(() => {
    if (previousFamily.current && family && previousFamily.current !== family) lock();
    previousFamily.current = family;
  }, [family, lock]);

  // Desktop: a senha do login (ou recém-definida) abre a área financeira da família ativa.
  useEffect(() => {
    const tryProof = () => {
      if (uid && family && isDesktop() && Date.now() - loginProofAt < LOGIN_PROOF_MS) {
        loginProofAt = 0;
        void serverUnlock(family);
      }
    };
    tryProof();
    window.addEventListener(PROOF_EVENT, tryProof);
    return () => window.removeEventListener(PROOF_EVENT, tryProof);
  }, [uid, family, serverUnlock]);

  // Expiração vista pelo cliente (o banco já recusa sozinho) e releitura ao voltar ao app.
  useEffect(() => {
    if (!state.unlocked) return;
    const tick = () => {
      setNow(Date.now());
      if (Date.now() >= state.expiresAt) forget();
    };
    const onVisible = () => {
      tick();
      if (document.visibilityState === "visible") void refresh();
    };
    const id = window.setInterval(tick, 5_000);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.clearInterval(id);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [state, forget, refresh]);

  const touch = useCallback(() => {
    if (!state.unlocked) return;
    const t = Date.now();
    if (t >= state.expiresAt) return forget();
    if (t - lastTouch.current < TOUCH_EVERY_MS) return;
    lastTouch.current = t;
    void supabase.rpc("touch_finance").then(({ data, error }) => {
      if (error || data !== true) forget();
      else setState((s) => (s.unlocked ? { ...s, expiresAt: t + IDLE_LIMIT_MS } : s));
    });
  }, [state, forget]);

  const unlock = useCallback(async (password: string) => {
    const email = session?.user.email;
    if (!email || !uid || !family) return "error";
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) return error.status === 400 ? "wrong" : error.status === 429 ? "limited" : "error";
    if (data.user?.id !== uid) return "error";
    return (await serverUnlock(family)) ? "ok" : "error";
  }, [session, uid, family, serverUnlock]);

  const unlocked = state.unlocked && state.family === family && now < state.expiresAt;
  const ready = !!uid && !!family;
  const value = useMemo(() => ({ unlocked, unlock, lock, touch, ready }), [unlocked, unlock, lock, touch, ready]);
  return <FinanceLockContext.Provider value={value}>{children}</FinanceLockContext.Provider>;
}

export function useFinanceLock(): FinanceLockValue {
  const ctx = useContext(FinanceLockContext);
  if (!ctx) throw new Error("useFinanceLock fora do FinanceLockProvider");
  return ctx;
}
