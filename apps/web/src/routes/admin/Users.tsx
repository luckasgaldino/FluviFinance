// Admin: usuários, convites e bloqueio. Toda regra é verificada no servidor.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Alert, Field, PageTitle, StatusBadge } from "../../components/ui";
import { provisionUser, redirectTo, rpc, statusLabel, type AdminUser, type Household } from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { useSession } from "../../lib/session";
import { supabase } from "../../lib/supabase";

export function useAdminUsers() {
  return useQuery({ queryKey: ["admin", "users"], queryFn: () => rpc<AdminUser[]>("admin_list_users") });
}

export function useHouseholds() {
  return useQuery({
    queryKey: ["admin", "households"],
    queryFn: async () => {
      const { data, error } = await supabase.from("households").select("id, name, active").order("name");
      if (error) throw error;
      return data as Household[];
    },
  });
}

function InviteForm() {
  const queryClient = useQueryClient();
  const households = useHouseholds();
  // mesmo operation_id enquanto o formulário não muda: repetir não duplica convite
  const [operationId, setOperationId] = useState(() => crypto.randomUUID());
  const [result, setResult] = useState<{ kind: "success" | "error"; text: string } | null>(null);

  const invite = useMutation({
    mutationFn: provisionUser,
    onSuccess: () => {
      setResult({ kind: "success", text: "Convite enviado. A conta fica pendente até a pessoa definir a senha." });
      setOperationId(crypto.randomUUID());
      void queryClient.invalidateQueries({ queryKey: ["admin"] });
    },
    onError: (e) => setResult({ kind: "error", text: errorMessage(e) }),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    setResult(null);
    invite.mutate({
      operation_id: operationId,
      email: String(form.get("email")).trim(),
      display_name: String(form.get("display_name")).trim(),
      household_id: String(form.get("household_id") || "") || null,
      redirect_to: redirectTo("/definir-senha"),
    }, { onSuccess: () => (e.target as HTMLFormElement).reset() });
  }

  return (
    <section className="card stack" aria-labelledby="convidar">
      <h2 id="convidar">Convidar pessoa</h2>
      <form className="stack" onSubmit={onSubmit} onChange={() => setOperationId(crypto.randomUUID())}>
        <div className="row">
          <Field label="Nome" name="display_name" required maxLength={80} />
          <Field label="E-mail" name="email" type="email" required />
          <div className="field">
            <label htmlFor="invite-household">Núcleo</label>
            <select id="invite-household" name="household_id" defaultValue="">
              <option value="">Sem núcleo por enquanto</option>
              {households.data?.filter((h) => h.active).map((h) => <option key={h.id} value={h.id}>{h.name}</option>)}
            </select>
          </div>
        </div>
        {result && <Alert kind={result.kind}>{result.text}</Alert>}
        <div><button className="btn" type="submit" disabled={invite.isPending}>Enviar convite</button></div>
      </form>
    </section>
  );
}

export function Users() {
  const { me } = useSession();
  const users = useAdminUsers();
  const queryClient = useQueryClient();
  const [feedback, setFeedback] = useState<{ kind: "success" | "error"; text: string } | null>(null);

  const setStatus = useMutation({
    mutationFn: (v: { user: AdminUser; status: "active" | "blocked" }) =>
      rpc("admin_set_user_status", { p_request_id: crypto.randomUUID(), p_user_id: v.user.user_id, p_status: v.status }),
    onSuccess: (_d, v) => {
      setFeedback({ kind: "success", text: `${v.user.display_name}: ${v.status === "blocked" ? "bloqueado(a)" : "reativado(a)"}.` });
      void queryClient.invalidateQueries({ queryKey: ["admin"] });
    },
    onError: (e) => setFeedback({ kind: "error", text: errorMessage(e) }),
  });

  return (
    <>
      <PageTitle>Usuários</PageTitle>
      <InviteForm />
      <section className="card stack" aria-labelledby="lista">
        <h2 id="lista">Pessoas</h2>
        {feedback && <Alert kind={feedback.kind}>{feedback.text}</Alert>}
        {users.isError && <Alert kind="error">{errorMessage(users.error)}</Alert>}
        {users.isLoading ? <p role="status">Carregando…</p> : (
          <ul className="list" aria-label="Pessoas cadastradas">
            {users.data?.map((u) => (
              <li key={u.user_id} className="list-item" aria-label={u.display_name}>
                <div className="meta">
                  <strong>{u.display_name}{u.is_admin && " · Admin"}</strong>
                  <span className="muted">{u.email}</span>
                  <span className="muted">
                    MFA: {u.has_mfa ? "ativo" : "não"} · Último acesso:{" "}
                    {u.last_sign_in_at ? new Date(u.last_sign_in_at).toLocaleString("pt-BR") : "nunca"}
                  </span>
                </div>
                <div className="actions">
                  <StatusBadge status={u.status} label={statusLabel[u.status]} />
                  {u.user_id !== me?.user_id && u.status === "active" && (
                    <button className="btn danger" type="button" disabled={setStatus.isPending}
                      onClick={() => window.confirm(`Bloquear ${u.display_name}? A pessoa perde o acesso imediatamente.`)
                        && setStatus.mutate({ user: u, status: "blocked" })}>
                      Bloquear
                    </button>
                  )}
                  {u.status === "blocked" && u.activation_completed_at && (
                    <button className="btn secondary" type="button" disabled={setStatus.isPending}
                      onClick={() => setStatus.mutate({ user: u, status: "active" })}>
                      Reativar
                    </button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </>
  );
}
