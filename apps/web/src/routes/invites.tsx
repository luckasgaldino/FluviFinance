// Convites de família (v2.2 §2, FAM-03): só a própria pessoa aceita, ciente de que passa a ver
// todo o histórico financeiro da família. Sem aceite, nada da família é liberado.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Alert } from "../components/ui";
import { rpc } from "../lib/api";
import { errorMessage } from "../lib/errors";
import { useFamily } from "../lib/family";
import { useSession } from "../lib/session";

type Invite = { family_id: string; name: string; invited_at: string | null };

export function useFamilyInvites() {
  const { session, me } = useSession();
  return useQuery({
    queryKey: ["family", "invites", session?.user.id],
    enabled: !!me?.is_financial_user,
    queryFn: () => rpc<Invite[]>("my_family_invites"),
  });
}

export function FamilyInvites() {
  const invites = useFamilyInvites();
  const queryClient = useQueryClient();
  const { select } = useFamily();
  const [feedback, setFeedback] = useState("");
  const [error, setError] = useState("");
  const answer = useMutation({
    mutationFn: (v: { family: string; accept: boolean }) =>
      rpc(v.accept ? "accept_family_invite" : "decline_family_invite", { p_family: v.family }),
    onSuccess: async (_d, v) => {
      setError("");
      setFeedback(v.accept ? "Convite aceito. A família já está disponível." : "Convite recusado.");
      await queryClient.invalidateQueries({ queryKey: ["family"] });
      if (v.accept) select(v.family);
    },
    onError: (e) => setError(errorMessage(e)),
  });

  if (!invites.data?.length) return feedback ? <Alert kind="success">{feedback}</Alert> : null;
  return (
    <section className="card stack" aria-labelledby="convites">
      <h2 id="convites">Convites de família</h2>
      <Alert kind="warn">
        Ao aceitar, você passa a ver <strong>todo o histórico financeiro</strong> da família — contas, cartões e
        lançamentos, inclusive os registrados antes da sua entrada — e o que você lançar ficará visível para todos os
        membros.
      </Alert>
      <ul className="list" aria-label="Convites pendentes">
        {invites.data.map((i) => (
          <li key={i.family_id} className="list-item" aria-label={i.name}>
            <strong>{i.name}</strong>
            <div className="actions">
              <button className="btn" type="button" disabled={answer.isPending}
                onClick={() => answer.mutate({ family: i.family_id, accept: true })}>Aceitar</button>
              <button className="btn secondary" type="button" disabled={answer.isPending}
                onClick={() => answer.mutate({ family: i.family_id, accept: false })}>Recusar</button>
            </div>
          </li>
        ))}
      </ul>
      <Alert kind="error">{error}</Alert>
    </section>
  );
}

export function NoFamily() {
  const invites = useFamilyInvites();
  return (
    <>
      {!invites.data?.length && (
        <Alert kind="info">
          Você ainda não faz parte de uma família. Peça ao administrador para enviar um convite.
        </Alert>
      )}
      <FamilyInvites />
    </>
  );
}
