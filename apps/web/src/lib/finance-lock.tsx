// Desbloqueio financeiro (v2.2 §3.2): segunda confirmação com a MESMA senha do login para
// ler dados financeiros; vale para todas as telas até 15 min sem atividade humana, bloqueio
// manual, saída ou troca de usuário. A expiração não encerra o login.
//
// Fase R1: a senha é conferida pelo provedor de identidade (signInWithPassword), mas o estado
// do desbloqueio ainda vive no cliente. Na fase R3 o desbloqueio passa a ser registrado e
// exigido pelo banco (RLS/RPC por sessão e família); este módulo vira só o espelho desse estado.
import { useQueryClient } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { isDesktop } from "./device";
import { useSession } from "./session";
import { supabase } from "./supabase";

export const IDLE_LIMIT_MS = 15 * 60_000;
const STORAGE_KEY = "fluvi.unlock";
const LOGIN_PROOF_MS = 60_000;

// Senha digitada no login agora há pouco: no desktop, o próprio login abre a área financeira.
// Vale também quando a sessão já existia (definir senha pelo link de convite ou recuperação).
let loginProofAt = 0;
const PROOF_EVENT = "fluvi:password-proof";
export const noteLoginPassword = () => {
  loginProofAt = Date.now();
  window.dispatchEvent(new Event(PROOF_EVENT));
};

type Stored = { uid: string; last: number };

function readStored(): Stored | null {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    return raw ? (JSON.parse(raw) as Stored) : null;
  } catch {
    return null;
  }
}

function writeStored(value: Stored | null) {
  try {
    if (value) sessionStorage.setItem(STORAGE_KEY, JSON.stringify(value));
    else sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    // armazenamento indisponível: o desbloqueio só não sobrevive a recarregar a página
  }
}

type FinanceLockValue = {
  unlocked: boolean;
  /** confere a senha com o provedor de identidade; nunca guarda a senha */
  unlock: (password: string) => Promise<"ok" | "wrong" | "error">;
  lock: () => void;
  /** atividade humana em área protegida (toque, tecla, rolagem) */
  touch: () => void;
};

const FinanceLockContext = createContext<FinanceLockValue | null>(null);

export function FinanceLockProvider({ children }: { children: ReactNode }) {
  const { session } = useSession();
  const queryClient = useQueryClient();
  const uid = session?.user.id ?? null;
  const ready = session !== undefined;
  const [unlocked, setUnlocked] = useState(false);
  const lastActivity = useRef(0);
  const lastWrite = useRef(0);

  const lock = useCallback(() => {
    setUnlocked(false);
    lastActivity.current = 0;
    writeStored(null);
    // nada lido na área protegida sobrevive ao bloqueio
    queryClient.removeQueries({ queryKey: ["fin"] });
  }, [queryClient]);

  const open = useCallback((user: string) => {
    lastActivity.current = Date.now();
    lastWrite.current = lastActivity.current;
    writeStored({ uid: user, last: lastActivity.current });
    setUnlocked(true);
  }, []);

  // Usuário mudou ou saiu: bloqueia. Mesmo usuário: retoma o desbloqueio só se ainda válido.
  useEffect(() => {
    if (!ready) return;
    if (!uid) return lock();
    const stored = readStored();
    if (stored?.uid === uid && Date.now() - stored.last < IDLE_LIMIT_MS) {
      lastActivity.current = stored.last;
      setUnlocked(true);
    } else if (isDesktop() && Date.now() - loginProofAt < LOGIN_PROOF_MS) {
      loginProofAt = 0;
      open(uid);
    } else {
      lock();
    }
  }, [uid, ready, lock, open]);  // renovação do token não reavalia o desbloqueio

  useEffect(() => {
    const onProof = () => {
      if (uid && isDesktop()) {
        loginProofAt = 0;
        open(uid);
      }
    };
    window.addEventListener(PROOF_EVENT, onProof);
    return () => window.removeEventListener(PROOF_EVENT, onProof);
  }, [uid, open]);

  // Expiração por inatividade. Verificar não renova: só atividade humana renova (touch).
  useEffect(() => {
    if (!unlocked) return;
    const check = () => {
      if (Date.now() - lastActivity.current >= IDLE_LIMIT_MS) lock();
    };
    const id = window.setInterval(check, 5_000);
    document.addEventListener("visibilitychange", check);
    return () => {
      window.clearInterval(id);
      document.removeEventListener("visibilitychange", check);
    };
  }, [unlocked, lock]);

  const touch = useCallback(() => {
    if (!unlocked || !uid) return;
    const now = Date.now();
    if (now - lastActivity.current >= IDLE_LIMIT_MS) return lock();
    lastActivity.current = now;
    if (now - lastWrite.current > 10_000) {
      lastWrite.current = now;
      writeStored({ uid, last: now });
    }
  }, [unlocked, uid, lock]);

  const unlock = useCallback(async (password: string) => {
    const email = session?.user.email;
    if (!email || !uid) return "error";
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) return error.status === 400 ? "wrong" : "error";
    if (data.user?.id !== uid) return "error";
    open(uid);
    return "ok";
  }, [session, uid, open]);

  const value = useMemo(() => ({ unlocked, unlock, lock, touch }), [unlocked, unlock, lock, touch]);
  return <FinanceLockContext.Provider value={value}>{children}</FinanceLockContext.Provider>;
}

export function useFinanceLock(): FinanceLockValue {
  const ctx = useContext(FinanceLockContext);
  if (!ctx) throw new Error("useFinanceLock fora do FinanceLockProvider");
  return ctx;
}
