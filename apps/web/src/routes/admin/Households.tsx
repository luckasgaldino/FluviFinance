// Admin: famílias e membros (v2.2 §2). Vincular alguém gera um CONVITE — a pessoa aceita no app,
// ciente de que verá todo o histórico da família. Suspender corta o acesso na hora (no banco).
// O Admin não vê nem calcula nada financeiro.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Alert, Field, PageTitle, StatusBadge } from "../../components/ui";
import { rpc, statusLabel, type Member } from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { supabase } from "../../lib/supabase";
import { useAdminUsers, useHouseholds } from "./Users";

export function useMembers() {
  return useQuery({
    queryKey: ["admin", "members"],
    queryFn: async () => {
      const { data, error } = await supabase.from("household_members").select("household_id, user_id, status");
      if (error) throw error;
      return data as Member[];
    },
  });
}

const badge = (s: Member["status"]) => (s === "invited" ? "pending" : s);

export function Households() {
  const queryClient = useQueryClient();
  const households = useHouseholds();
  const members = useMembers();
  const users = useAdminUsers();
  const [feedback, setFeedback] = useState<{ kind: "success" | "error"; text: string } | null>(null);
  const nameOf = (id: string) => users.data?.find((u) => u.user_id === id)?.display_name ?? "—";
  const done = (text: string) => {
    setFeedback({ kind: "success", text });
    void queryClient.invalidateQueries({ queryKey: ["admin"] });
  };
  const fail = (e: unknown) => setFeedback({ kind: "error", text: errorMessage(e) });

  const create = useMutation({
    mutationFn: (name: string) => rpc("admin_create_household", { p_request_id: crypto.randomUUID(), p_name: name }),
    onSuccess: () => done("Família criada."),
    onError: fail,
  });
  const setMember = useMutation({
    mutationFn: (v: { household: string; user: string; status: Member["status"] }) =>
      rpc<{ status: Member["status"] }>("admin_set_household_member", {
        p_request_id: crypto.randomUUID(), p_household_id: v.household, p_user_id: v.user, p_status: v.status,
      }),
    onSuccess: (r, v) => done(r.status === "invited"
      ? `Convite de família enviado a ${nameOf(v.user)}. O acesso começa quando a pessoa aceitar.`
      : `Vínculo de ${nameOf(v.user)}: ${statusLabel[r.status].toLowerCase()}.`),
    onError: fail,
  });

  function onCreate(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const name = String(new FormData(e.currentTarget).get("name")).trim();
    if (name) create.mutate(name, { onSuccess: () => (e.target as HTMLFormElement).reset() });
  }

  const eligible = users.data?.filter((u) => !u.is_admin && u.status !== "blocked") ?? [];

  return (
    <>
      <PageTitle>Famílias e membros</PageTitle>
      <section className="card stack" aria-labelledby="novo">
        <h2 id="novo">Nova família</h2>
        <form className="row" onSubmit={onCreate}>
          <Field label="Nome da família" name="name" required maxLength={80} />
          <div><button className="btn" type="submit" disabled={create.isPending}>Criar</button></div>
        </form>
      </section>
      {feedback && <Alert kind={feedback.kind}>{feedback.text}</Alert>}
      {households.data?.length === 0 && <p className="empty">Nenhuma família cadastrada.</p>}
      {households.data?.map((h) => {
        const hm = members.data?.filter((m) => m.household_id === h.id) ?? [];
        const candidates = eligible.filter((u) => !hm.some((m) => m.user_id === u.user_id && (m.status === "active" || m.status === "invited")));
        return (
          <section key={h.id} className="card stack" aria-label={`Família ${h.name}`}>
            <h2>{h.name}</h2>
            <ul className="list" aria-label={`Membros de ${h.name}`}>
              {hm.length === 0 && <li className="empty">Sem membros.</li>}
              {hm.map((m) => (
                <li key={m.user_id} className="list-item" aria-label={nameOf(m.user_id)}>
                  <span>{nameOf(m.user_id)}</span>
                  <div className="actions">
                    <StatusBadge status={badge(m.status)} label={statusLabel[m.status]} />
                    {m.status === "active" && (
                      <button className="btn secondary" type="button" disabled={setMember.isPending}
                        onClick={() => window.confirm(`Suspender ${nameOf(m.user_id)} desta família? O acesso aos dados dela acaba na hora.`)
                          && setMember.mutate({ household: h.id, user: m.user_id, status: "suspended" })}>
                        Suspender
                      </button>
                    )}
                    {m.status === "invited" && (
                      <button className="btn secondary" type="button" disabled={setMember.isPending}
                        onClick={() => setMember.mutate({ household: h.id, user: m.user_id, status: "removed" })}>
                        Cancelar convite
                      </button>
                    )}
                    {(m.status === "suspended" || m.status === "removed") && (
                      <button className="btn secondary" type="button" disabled={setMember.isPending}
                        onClick={() => setMember.mutate({ household: h.id, user: m.user_id, status: "active" })}>
                        Convidar de novo
                      </button>
                    )}
                  </div>
                </li>
              ))}
            </ul>
            {candidates.length > 0 && (
              <form className="row" onSubmit={(e) => {
                e.preventDefault();
                const user = String(new FormData(e.currentTarget).get("user"));
                if (user) setMember.mutate({ household: h.id, user, status: "active" });
              }}>
                <div className="field">
                  <label htmlFor={`add-${h.id}`}>Convidar pessoa</label>
                  <select id={`add-${h.id}`} name="user" defaultValue="">
                    <option value="" disabled>Escolha…</option>
                    {candidates.map((u) => <option key={u.user_id} value={u.user_id}>{u.display_name}</option>)}
                  </select>
                  <span className="hint">Ao aceitar, a pessoa passa a ver todo o histórico financeiro da família.</span>
                </div>
                <div><button className="btn" type="submit">Convidar</button></div>
              </form>
            )}
          </section>
        );
      })}
    </>
  );
}
