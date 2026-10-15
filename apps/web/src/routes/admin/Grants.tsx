// Admin: permissões (grants) por núcleo, titular, beneficiário e escopo.
// Salvar envia a revisão vista (controle otimista): se alguém alterou antes, o banco recusa.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Alert, PageTitle } from "../../components/ui";
import { rpc, scopeLabel, type Grant, type Scope } from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { supabase } from "../../lib/supabase";
import { useMembers } from "./Households";
import { useAdminUsers, useHouseholds } from "./Users";

type Flags = { can_read: boolean; can_create: boolean; can_update: boolean; can_cancel: boolean };
const flagLabels: [keyof Flags, string][] = [
  ["can_read", "Ler"], ["can_create", "Criar"], ["can_update", "Editar"], ["can_cancel", "Cancelar"],
];

// editar/cancelar exigem ler (B2): a interface acompanha a regra do banco
function normalize(flags: Flags, changed: keyof Flags): Flags {
  const next = { ...flags };
  if ((changed === "can_update" || changed === "can_cancel") && next[changed]) next.can_read = true;
  if (changed === "can_read" && !next.can_read) { next.can_update = false; next.can_cancel = false; }
  return next;
}

function FlagEditor({ value, onChange, idPrefix }: { value: Flags; onChange: (f: Flags) => void; idPrefix: string }) {
  return (
    <fieldset style={{ border: 0, padding: 0, margin: 0 }}>
      <legend className="visually-hidden">Operações permitidas</legend>
      <div className="row" style={{ alignItems: "center" }}>
        {flagLabels.map(([key, label]) => (
          <label key={key} className="check" htmlFor={`${idPrefix}-${key}`}>
            <input id={`${idPrefix}-${key}`} type="checkbox" checked={value[key]}
              onChange={(e) => onChange(normalize({ ...value, [key]: e.target.checked }, key))} />
            {label}
          </label>
        ))}
      </div>
    </fieldset>
  );
}

function GrantRow({ grant, nameOf, onSave, busy }: {
  grant: Grant; nameOf: (id: string) => string; busy: boolean;
  onSave: (g: Grant, flags: Flags) => void;
}) {
  const [flags, setFlags] = useState<Flags>(grant);
  const dirty = flagLabels.some(([k]) => flags[k] !== grant[k]);
  return (
    <li className="list-item" aria-label={`${nameOf(grant.owner_user_id)} para ${nameOf(grant.grantee_user_id)}`}>
      <div className="meta">
        <strong>{nameOf(grant.owner_user_id)} → {nameOf(grant.grantee_user_id)}</strong>
        <span className="muted">Escopo: {scopeLabel[grant.resource_scope]} · revisão {grant.revision}</span>
      </div>
      <FlagEditor value={flags} onChange={setFlags} idPrefix={grant.id} />
      <div className="actions">
        <button className="btn" type="button" disabled={!dirty || busy} onClick={() => onSave(grant, flags)}>Salvar</button>
        <button className="btn danger" type="button" disabled={busy}
          onClick={() => window.confirm("Revogar esta permissão? O acesso termina imediatamente.")
            && onSave(grant, { can_read: false, can_create: false, can_update: false, can_cancel: false })}>
          Revogar
        </button>
      </div>
    </li>
  );
}

export function Grants() {
  const queryClient = useQueryClient();
  const households = useHouseholds();
  const members = useMembers();
  const users = useAdminUsers();
  const [householdId, setHouseholdId] = useState("");
  const [feedback, setFeedback] = useState<{ kind: "success" | "error"; text: string } | null>(null);
  const [newFlags, setNewFlags] = useState<Flags>({ can_read: true, can_create: false, can_update: false, can_cancel: false });

  const selected = householdId || households.data?.[0]?.id || "";
  const grants = useQuery({
    queryKey: ["admin", "grants", selected],
    enabled: !!selected,
    queryFn: async () => {
      const { data, error } = await supabase.from("data_grants")
        .select("id, household_id, owner_user_id, grantee_user_id, resource_scope, can_read, can_create, can_update, can_cancel, revision")
        .eq("household_id", selected).is("revoked_at", null).order("created_at");
      if (error) throw error;
      return data as Grant[];
    },
  });
  const nameOf = (id: string) => users.data?.find((u) => u.user_id === id)?.display_name ?? "—";
  const activeMembers = members.data?.filter((m) => m.household_id === selected && m.status === "active") ?? [];

  const save = useMutation({
    mutationFn: (v: { owner: string; grantee: string; scope: Scope; flags: Flags; expected: number }) =>
      rpc("admin_set_data_grant", {
        p_request_id: crypto.randomUUID(), p_household_id: selected, p_owner: v.owner, p_grantee: v.grantee,
        p_scope: v.scope, p_can_read: v.flags.can_read, p_can_create: v.flags.can_create,
        p_can_update: v.flags.can_update, p_can_cancel: v.flags.can_cancel, p_expected_revision: v.expected,
      }),
    onSuccess: () => {
      setFeedback({ kind: "success", text: "Permissão salva." });
      void queryClient.invalidateQueries({ queryKey: ["admin", "grants"] });
    },
    onError: (e) => {
      setFeedback({ kind: "error", text: errorMessage(e) });
      void queryClient.invalidateQueries({ queryKey: ["admin", "grants"] });
    },
  });

  function onCreate(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const owner = String(form.get("owner"));
    const grantee = String(form.get("grantee"));
    const scope = String(form.get("scope")) as Scope;
    if (owner === grantee) return setFeedback({ kind: "error", text: "Titular e beneficiário devem ser pessoas diferentes." });
    const existing = grants.data?.find((g) => g.owner_user_id === owner && g.grantee_user_id === grantee && g.resource_scope === scope);
    save.mutate({ owner, grantee, scope, flags: newFlags, expected: existing?.revision ?? 0 });
  }

  return (
    <>
      <PageTitle>Permissões</PageTitle>
      <p className="muted">
        Cada permissão vale num núcleo, de um titular para um beneficiário, num escopo.
        Editar e cancelar exigem leitura. Revogar tem efeito imediato.
      </p>
      <div className="field" style={{ maxWidth: 360, marginBottom: 16 }}>
        <label htmlFor="grant-household">Núcleo</label>
        <select id="grant-household" value={selected} onChange={(e) => setHouseholdId(e.target.value)}>
          {households.data?.map((h) => <option key={h.id} value={h.id}>{h.name}</option>)}
        </select>
      </div>
      {feedback && <Alert kind={feedback.kind}>{feedback.text}</Alert>}
      {selected && (
        <section className="card stack" aria-labelledby="nova-permissao">
          <h2 id="nova-permissao">Nova permissão</h2>
          {activeMembers.length < 2 ? <p className="empty">O núcleo precisa de pelo menos dois membros ativos.</p> : (
            <form className="stack" onSubmit={onCreate}>
              <div className="row">
                <div className="field">
                  <label htmlFor="g-owner">Titular dos dados</label>
                  <select id="g-owner" name="owner">
                    {activeMembers.map((m) => <option key={m.user_id} value={m.user_id}>{nameOf(m.user_id)}</option>)}
                  </select>
                </div>
                <div className="field">
                  <label htmlFor="g-grantee">Quem recebe a permissão</label>
                  <select id="g-grantee" name="grantee" defaultValue={activeMembers[1]?.user_id}>
                    {activeMembers.map((m) => <option key={m.user_id} value={m.user_id}>{nameOf(m.user_id)}</option>)}
                  </select>
                </div>
                <div className="field">
                  <label htmlFor="g-scope">Escopo</label>
                  <select id="g-scope" name="scope" defaultValue="transactions">
                    {Object.entries(scopeLabel).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                  </select>
                </div>
              </div>
              <FlagEditor value={newFlags} onChange={setNewFlags} idPrefix="new" />
              <div><button className="btn" type="submit" disabled={save.isPending}>Conceder</button></div>
            </form>
          )}
        </section>
      )}
      <section className="card stack" aria-labelledby="vigentes">
        <h2 id="vigentes">Permissões vigentes</h2>
        {grants.data?.length === 0 && <p className="empty">Nenhuma permissão vigente neste núcleo.</p>}
        <ul className="list">
          {grants.data?.map((g) => (
            <GrantRow key={`${g.id}-${g.revision}`} grant={g} nameOf={nameOf} busy={save.isPending}
              onSave={(grant, flags) => save.mutate({
                owner: grant.owner_user_id, grantee: grant.grantee_user_id, scope: grant.resource_scope,
                flags, expected: grant.revision,
              })} />
          ))}
        </ul>
      </section>
    </>
  );
}
