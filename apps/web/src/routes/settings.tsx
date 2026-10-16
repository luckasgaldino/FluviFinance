// Configurações (tela 11): família ativa, privacidade e segurança. Não é área protegida:
// nada aqui mostra dados financeiros.
import { Link } from "react-router";
import { PageTitle } from "../components/ui";
import { useFamily } from "../lib/family";
import { useFinanceLock } from "../lib/finance-lock";
import { useSession } from "../lib/session";
import { NoFamily } from "./privacy";

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
