// Cliente Supabase do navegador: só a URL pública e a chave anon.
// Autorização real acontece no banco (RLS/RPC); a UI apenas reflete.
import "./initial-url";
import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
if (!url || !anonKey) {
  throw new Error("Configuração ausente: VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY (rode `pnpm web:env`).");
}

export const supabase = createClient(url, anonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    // links de convite e recuperação chegam com a sessão no fragmento da URL
    detectSessionInUrl: true,
    storageKey: "fluvi.auth",
  },
});

export type Gate =
  | "loading" | "anon" | "pending" | "blocked"
  | "mfa-enroll" | "mfa-verify" | "admin" | "user";

export type WhoAmI = {
  user_id: string;
  status: "pending" | "active" | "blocked";
  aal: "aal1" | "aal2";
  is_admin_identity: boolean;
  can_administer: boolean;
  is_financial_user: boolean;
};
