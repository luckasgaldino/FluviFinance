// Configurações (tela 11): família ativa, privacidade e segurança. Não é área protegida:
// nada aqui mostra dados financeiros.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Link } from "react-router";
import { Alert, Field, PageTitle } from "../components/ui";
import { rpc } from "../lib/api";
import { errorMessage } from "../lib/errors";
import { useFamily } from "../lib/family";
import { useFinanceLock } from "../lib/finance-lock";
import { useSession } from "../lib/session";
import { FamilyInvites, NoFamily } from "./invites";

export function Settings() {
  const { session, signOut } = useSession();
  const { unlocked, lock } = useFinanceLock();
  const { families, active, loading, select } = useFamily();
  return (
    <>
      <PageTitle>Configurações</PageTitle>
      <section className="card stack" aria-labelledby="cfg-familia">
        <h2 id="cfg-familia">Família ativa</h2>
        {!loading && !active && <NoFamily />}
        {families.length > 1 ? (
          <div className="field">
            <label htmlFor="cfg-family">Família</label>
            <select id="cfg-family" value={active?.family_id ?? ""} onChange={(e) => select(e.target.value)}>
              {families.map((f) => <option key={f.family_id} value={f.family_id}>{f.name}</option>)}
            </select>
            <span className="hint">Ao trocar de família, a área financeira pede a senha de novo.</span>
          </div>
        ) : active && <p><strong>{active.name}</strong></p>}
        <p className="muted">
          Todos os membros da família veem as mesmas contas, cartões e lançamentos. Se você participar de mais de
          uma família, escolha aqui qual está ativa — os dados nunca se misturam.
        </p>
      </section>
      {active && <FamilyInvites />}
      {active && <FamilyCategories family={active.family_id} />}
      <section className="card stack" aria-labelledby="cfg-priv">
        <h2 id="cfg-priv">Privacidade</h2>
        <p className="muted">
          As áreas financeiras pedem a sua senha novamente e ficam liberadas até 15 minutos sem uso. Bloquear não
          encerra o seu login.
        </p>
        <p>Área financeira: <strong>{unlocked ? "liberada" : "bloqueada"}</strong></p>
        {unlocked && <button className="btn secondary" type="button" onClick={lock}>Bloquear agora</button>}
      </section>
      <section className="card stack" aria-labelledby="cfg-conta">
        <h2 id="cfg-conta">Conta</h2>
        <p className="muted">{session?.user.email}</p>
        <Link to="/seguranca/mfa">Verificação em duas etapas</Link>
        <button className="btn secondary" type="button" onClick={signOut} style={{ alignSelf: "flex-start" }}>Sair</button>
      </section>
    </>
  );
}

// Categorias da família (FF-08): só nomes, sem valores; arquivar não apaga o histórico.
type FamilyCategory = { id: string; name: string; kind: "expense" | "income"; active: boolean };

function FamilyCategories({ family }: { family: string }) {
  const queryClient = useQueryClient();
  const [error, setError] = useState("");
  const list = useQuery({
    queryKey: ["settings", "categories", family],
    queryFn: () => rpc<FamilyCategory[]>("family_categories", { p_family: family }),
  });
  const refresh = () => {
    setError("");
    void queryClient.invalidateQueries({ queryKey: ["settings", "categories"] });
    void queryClient.invalidateQueries({ queryKey: ["quick"] });
    void queryClient.invalidateQueries({ queryKey: ["fin", "categories"] });
  };
  const create = useMutation({
    mutationFn: (v: { name: string; kind: string }) => rpc("create_category", { p_family: family, p_name: v.name, p_kind: v.kind }),
    onSuccess: refresh,
    onError: (e) => setError(errorMessage(e)),
  });
  const toggle = useMutation({
    mutationFn: (v: { id: string; active: boolean }) => rpc("set_category_active", { p_category: v.id, p_active: v.active }),
    onSuccess: refresh,
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const f = new FormData(form);
    const name = String(f.get("name")).trim();
    if (!name) return setError("Informe o nome da categoria.");
    create.mutate({ name, kind: String(f.get("kind")) }, { onSuccess: () => form.reset() });
  }

  return (
    <section className="card stack" aria-labelledby="cfg-cat">
      <h2 id="cfg-cat">Categorias da família</h2>
      <p className="muted">Além das categorias padrão, crie as da sua família. Arquivar tira a categoria dos novos lançamentos sem mudar o histórico.</p>
      {list.data && list.data.length > 0 && (
        <ul className="list" aria-label="Categorias da família">
          {list.data.map((c) => (
            <li key={c.id} className={c.active ? "list-item" : "list-item inactive"} aria-label={c.name}>
              <div className="meta"><strong>{c.name}</strong><span className="muted">{c.kind === "income" ? "Receita" : "Despesa"}{c.active ? "" : " · arquivada"}</span></div>
              <button className="btn secondary" type="button" disabled={toggle.isPending}
                onClick={() => toggle.mutate({ id: c.id, active: !c.active })}>{c.active ? "Arquivar" : "Reativar"}</button>
            </li>
          ))}
        </ul>
      )}
      <form className="row" onSubmit={onSubmit} noValidate aria-label="Nova categoria">
        <Field label="Nova categoria" name="name" maxLength={60} />
        <div className="field">
          <label htmlFor="cat-kind">Tipo</label>
          <select id="cat-kind" name="kind" defaultValue="expense">
            <option value="expense">Despesa</option>
            <option value="income">Receita</option>
          </select>
        </div>
        <div><button className="btn" type="submit" disabled={create.isPending}>Adicionar</button></div>
      </form>
      <Alert kind="error">{error}</Alert>
    </section>
  );
}
