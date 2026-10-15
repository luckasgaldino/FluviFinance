// Estado da sessão e "portão" de navegação.
// A fonte de verdade é o banco (whoami) + nível de autenticação (aal); nada vem
// de user_metadata. A UI só decide para onde levar — o banco decide o que pode.
import type { Factor, Session } from "@supabase/supabase-js";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { supabase, type Gate, type WhoAmI } from "./supabase";

type SessionState = {
  me: WhoAmI;
  currentLevel: string | null;
  nextLevel: string | null;
  totp: Factor[];
};

type SessionContextValue = {
  session: Session | null | undefined;
  gate: Gate;
  me: WhoAmI | undefined;
  totp: Factor[];
  refresh: () => Promise<void>;
  signOut: () => Promise<void>;
};

const SessionContext = createContext<SessionContextValue | null>(null);

// Lê só a claim "aal" do JWT para compor a chave do cache (não é usada para autorizar).
function aalOf(token: string | undefined): string | null {
  if (!token) return null;
  try {
    const payload = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return (JSON.parse(atob(payload)) as { aal?: string }).aal ?? null;
  } catch {
    return null;
  }
}

function computeGate(session: Session | null | undefined, state: SessionState | undefined, failed: boolean): Gate {
  if (session === undefined) return "loading";
  if (session === null) return "anon";
  if (failed) return "anon";
  if (!state) return "loading";
  const { me, currentLevel, nextLevel, totp } = state;
  if (me.status === "blocked") return "blocked";
  if (me.status === "pending") return "pending";
  if (me.is_admin_identity) {
    // MFA obrigatório para Admin (§5.3): sem fator verificado → cadastrar; com fator → verificar
    if (totp.length === 0) return "mfa-enroll";
    return currentLevel === "aal2" ? "admin" : "mfa-verify";
  }
  if (nextLevel === "aal2" && currentLevel !== "aal2") return "mfa-verify";
  return "user";
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  const lastUser = useRef<string | null | undefined>(undefined);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    // Não chamar o supabase dentro do callback (evita deadlock do SDK): só guarda o estado.
    const { data } = supabase.auth.onAuthStateChange((_event, next) => setSession(next));
    return () => data.subscription.unsubscribe();
  }, []);

  // Troca de usuário ou saída: nenhum dado do usuário anterior fica em cache.
  useEffect(() => {
    if (session === undefined) return;
    const uid = session?.user.id ?? null;
    if (lastUser.current !== undefined && lastUser.current !== uid) queryClient.clear();
    lastUser.current = uid;
  }, [session, queryClient]);

  const state = useQuery({
    // Chave por usuário + nível de autenticação: a renovação periódica do token não
    // muda a chave (a página não desmonta nem perde formulários); a elevação por MFA muda.
    queryKey: ["session-state", session?.user.id, aalOf(session?.access_token)],
    enabled: !!session,
    staleTime: 30_000,
    retry: false,
    queryFn: async (): Promise<SessionState> => {
      const [who, aal, factors] = await Promise.all([
        supabase.rpc("whoami"),
        supabase.auth.mfa.getAuthenticatorAssuranceLevel(),
        supabase.auth.mfa.listFactors(),
      ]);
      if (who.error) throw who.error;
      return {
        me: who.data as WhoAmI,
        currentLevel: aal.data?.currentLevel ?? null,
        nextLevel: aal.data?.nextLevel ?? null,
        totp: (factors.data?.totp ?? []).filter((f) => f.status === "verified"),
      };
    },
  });

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
    queryClient.clear();
  }, [queryClient]);

  const refresh = useCallback(async () => {
    await queryClient.invalidateQueries({ queryKey: ["session-state"] });
  }, [queryClient]);

  const gate = computeGate(session, state.data, state.isError);

  // Perfil bloqueado com token ainda válido: encerra a sessão local.
  useEffect(() => {
    if (gate === "blocked") void supabase.auth.signOut({ scope: "local" });
  }, [gate]);

  const value = useMemo<SessionContextValue>(() => ({
    session, gate, me: state.data?.me, totp: state.data?.totp ?? [], refresh, signOut,
  }), [session, gate, state.data, refresh, signOut]);

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionContextValue {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error("useSession fora do SessionProvider");
  return ctx;
}

export const gatePath: Record<Gate, string> = {
  loading: "/",
  anon: "/entrar",
  pending: "/pendente",
  blocked: "/bloqueada",
  "mfa-enroll": "/seguranca/mfa",
  "mfa-verify": "/verificar",
  admin: "/admin/usuarios",
  user: "/inicio",
};
