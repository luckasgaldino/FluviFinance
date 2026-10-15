// Admin: núcleos e vínculos. Suspender um vínculo revoga as permissões dele (no banco).
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
    onSuccess: () => done("Núcleo criado."),
    onError: fail,
  });
  const setMember = useMutation({
    mutationFn: (v: { household: string; user: string; status: Member["status"] }) =>
      rpc("admin_set_household_member", {
        p_request_id: crypto.randomUUID(), p_household_id: v.household, p_user_id: v.user, p_status: v.status,
      }),
    onSuccess: (_d, v) => done(`Vínculo de ${nameOf(v.user)}: ${statusLabel[v.status].toLowerCase()}.`),
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
      <PageTitle>Núcleos e vínculos</PageTitle>
      <section className="card stack" aria-labelledby="novo">
        <h2 id="novo">Novo núcleo</h2>
        <form className="row" onSubmit={onCreate}>
          <Field label="Nome do núcleo" name="name" required maxLength={80} />
          <div><button className="btn" type="submit" disabled={create.isPending}>Criar</button></div>
        </form>
      </section>
      {feedback && <Alert kind={feedback.kind}>{feedback.text}</Alert>}
      {households.data?.length === 0 && <p className="empty">Nenhum núcleo cadastrado.</p>}
      {households.data?.map((h) => {
        const hm = members.data?.filter((m) => m.household_id === h.id) ?? [];
        const candidates = eligible.filter((u) => !hm.some((m) => m.user_id === u.user_id && m.status === "active"));
        return (
          <section key={h.id} className="card stack" aria-label={`Núcleo ${h.name}`}>
            <h2>{h.name}</h2>
            <ul className="list" aria-label={`Membros de ${h.name}`}>
              {hm.length === 0 && <li className="empty">Sem membros.</li>}
              {hm.map((m) => (
                <li key={m.user_id} className="list-item">
                  <span>{nameOf(m.user_id)}</span>
                  <div className="actions">
                    <StatusBadge status={m.status} label={statusLabel[m.status]} />
                    {m.status === "active" ? (
                      <button className="btn secondary" type="button" disabled={setMember.isPending}
                        onClick={() => window.confirm(`Suspender o vínculo de ${nameOf(m.user_id)}? As permissões dependentes serão revogadas.`)
                          && setMember.mutate({ household: h.id, user: m.user_id, status: "suspended" })}>
                        Suspender
                      </button>
                    ) : (
                      <button className="btn secondary" type="button" disabled={setMember.isPending}
                        onClick={() => setMember.mutate({ household: h.id, user: m.user_id, status: "active" })}>
                        Reativar vínculo
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
                  <label htmlFor={`add-${h.id}`}>Adicionar pessoa</label>
                  <select id={`add-${h.id}`} name="user" defaultValue="">
                    <option value="" disabled>Escolha…</option>
                    {candidates.map((u) => <option key={u.user_id} value={u.user_id}>{u.display_name}</option>)}
                  </select>
                </div>
                <div><button className="btn" type="submit">Adicionar</button></div>
              </form>
            )}
          </section>
        );
      })}
    </>
  );
}
