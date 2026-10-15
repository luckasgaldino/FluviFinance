// Configurações (tela 11): família ativa, privacidade e segurança. Não é área protegida:
// nada aqui mostra dados financeiros.
import { Link } from "react-router";
import { PageTitle } from "../components/ui";
import { DEMO_FAMILY } from "../lib/demo";
import { useFinanceLock } from "../lib/finance-lock";
import { useSession } from "../lib/session";

export function Settings() {
  const { session, signOut } = useSession();
  const { unlocked, lock } = useFinanceLock();
  return (
    <>
      <PageTitle>Configurações</PageTitle>
      <section className="card stack" aria-labelledby="cfg-familia">
        <h2 id="cfg-familia">Família ativa</h2>
        <p><strong>{DEMO_FAMILY}</strong></p>
        <p className="muted">
          Todos os membros da família veem as mesmas contas, cartões e lançamentos. Se você participar de mais de
          uma família, poderá escolher aqui qual está ativa — os dados nunca se misturam.
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
