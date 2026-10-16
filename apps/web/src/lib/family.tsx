// Família ativa (v2.2 §2): os dados financeiros são da família; o usuário escolhe uma família
// por vez e nada é misturado. Trocar de família limpa o cache; o desbloqueio (finance-lock)
// é encerrado no servidor e precisa ser refeito para a nova família.
// Guarda-se só o id da família escolhida (não sensível); o banco revalida o vínculo sempre.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";
import { rpc } from "./api";
import { useSession } from "./session";

export type Family = { family_id: string; name: string };

type FamilyValue = {
  families: Family[];
  active: Family | null;
  loading: boolean;
  select: (familyId: string) => void;
};

const STORAGE_KEY = "fluvi.family";
const FamilyContext = createContext<FamilyValue | null>(null);

function readChoice(): string | null {
  try {
    return localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

export function FamilyProvider({ children }: { children: ReactNode }) {
  const { session, me } = useSession();
  const queryClient = useQueryClient();
  const [choice, setChoice] = useState<string | null>(readChoice);
  const list = useQuery({
    queryKey: ["family", "list", session?.user.id],
    enabled: !!me?.is_financial_user,
    staleTime: 60_000,
    queryFn: () => rpc<Family[]>("my_families"),
  });
  const families = useMemo(() => list.data ?? [], [list.data]);
  const active = families.find((f) => f.family_id === choice) ?? families[0] ?? null;

  const select = useCallback((familyId: string) => {
    if (familyId === active?.family_id) return;
    try {
      localStorage.setItem(STORAGE_KEY, familyId);
    } catch {
      // sem armazenamento: a escolha vale até recarregar
    }
    setChoice(familyId);
    queryClient.removeQueries({ queryKey: ["quick"] });
    queryClient.removeQueries({ queryKey: ["fin"] });
  }, [active, queryClient]);

  const value = useMemo(() => ({ families, active, loading: list.isLoading, select }),
    [families, active, list.isLoading, select]);
  return <FamilyContext.Provider value={value}>{children}</FamilyContext.Provider>;
}

export function useFamily(): FamilyValue {
  const ctx = useContext(FamilyContext);
  if (!ctx) throw new Error("useFamily fora do FamilyProvider");
  return ctx;
}

/** Id da família ativa para consultas e RPCs (string vazia enquanto carrega). */
export const useFamilyId = () => useFamily().active?.family_id ?? "";
