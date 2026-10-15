// Admin: trilha de auditoria (somente leitura; o banco não permite alterar eventos).
import { useQuery } from "@tanstack/react-query";
import { Alert, PageTitle } from "../../components/ui";
import { errorMessage } from "../../lib/errors";
import { supabase } from "../../lib/supabase";
import { useAdminUsers } from "./Users";

type AuditEvent = {
  id: string; actor_id: string | null; action: string; entity_type: string;
  entity_id: string; request_id: string | null; created_at: string;
};

const entityLabel: Record<string, string> = {
  profiles: "Perfil", administrators: "Papel de Admin", households: "Núcleo",
  household_members: "Vínculo", data_grants: "Permissão",
};

export function Audit() {
  const users = useAdminUsers();
  const events = useQuery({
    queryKey: ["admin", "audit"],
    queryFn: async () => {
      const { data, error } = await supabase.from("audit_events")
        .select("id, actor_id, action, entity_type, entity_id, request_id, created_at")
        .order("created_at", { ascending: false }).limit(100);
      if (error) throw error;
      return data as AuditEvent[];
    },
  });
  const nameOf = (id: string | null) =>
    id ? users.data?.find((u) => u.user_id === id)?.display_name ?? id.slice(0, 8) : "sistema/operador";

  return (
    <>
      <PageTitle>Auditoria</PageTitle>
      <p className="muted">Últimos 100 eventos. Os eventos guardam só identificadores e digests, nunca valores.</p>
      {events.isError && <Alert kind="error">{errorMessage(events.error)}</Alert>}
      <ul className="list" aria-label="Eventos de auditoria">
        {events.data?.map((e) => (
          <li key={e.id} className="list-item">
            <div className="meta">
              <strong>{entityLabel[e.entity_type] ?? e.entity_type} · {e.action}</strong>
              <span className="muted">
                {new Date(e.created_at).toLocaleString("pt-BR")} · por {nameOf(e.actor_id)}
                {e.request_id && ` · req ${e.request_id.slice(0, 8)}`}
              </span>
            </div>
          </li>
        ))}
      </ul>
    </>
  );
}
