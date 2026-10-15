// Layouts autenticados e a tela inicial do usuário financeiro (Marco A).
import { useQuery } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { Link, NavLink, Outlet } from "react-router";
import { Alert, Brand, PageTitle } from "../components/ui";
import { rpc } from "../lib/api";
import { useSession } from "../lib/session";

function Shell({ nav, children }: { nav: { to: string; label: string }[]; children: ReactNode }) {
  const { session, signOut } = useSession();
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <Brand />
        <nav aria-label="Navegação principal">
          {nav.map((n) => <NavLink key={n.to} to={n.to} className="nav-link">{n.label}</NavLink>)}
        </nav>
      </aside>
      <div className="main">
        <header className="topbar">
          <span className="who">{session?.user.email}</span>
          <button className="btn secondary" type="button" onClick={signOut}>Sair</button>
        </header>
        <main>{children}</main>
      </div>
    </div>
  );
}

export function AdminLayout() {
  return (
    <Shell nav={[
      { to: "/admin/usuarios", label: "Usuários" },
      { to: "/admin/nucleos", label: "Núcleos e vínculos" },
      { to: "/admin/permissoes", label: "Permissões" },
      { to: "/admin/auditoria", label: "Auditoria" },
    ]}>
      <Outlet />
    </Shell>
  );
}

export function UserLayout() {
  return (
    <Shell nav={[{ to: "/inicio", label: "Início" }, { to: "/seguranca/mfa", label: "Segurança" }]}>
      <Outlet />
    </Shell>
  );
}

type Owner = { owner_user_id: string; display_name: string; is_self: boolean };

export function Home() {
  const { me, session } = useSession();
  const owners = useQuery({
    queryKey: ["accessible-owners", session?.user.id],
    queryFn: () => rpc<Owner[]>("accessible_owners", { p_scope: "transactions", p_operation: "read" }),
  });
  const self = owners.data?.find((o) => o.is_self);
  const others = owners.data?.filter((o) => !o.is_self) ?? [];

  return (
    <>
      <PageTitle>Olá{self ? `, ${self.display_name}` : ""}</PageTitle>
      <section className="card stack" aria-labelledby="acesso">
        <h2 id="acesso">Quem você acompanha</h2>
        <p className="muted">
          Você sempre vê os seus próprios dados. Dados de outras pessoas do núcleo só
          aparecem quando o administrador concede permissão.
        </p>
        {owners.isLoading ? <p role="status">Carregando…</p> : others.length === 0 ? (
          <p className="empty">Nenhuma permissão de leitura de outras pessoas no momento.</p>
        ) : (
          <ul className="list" aria-label="Pessoas com leitura de lançamentos permitida">
            {others.map((o) => <li key={o.owner_user_id} className="list-item">{o.display_name}</li>)}
          </ul>
        )}
      </section>
      <section className="card stack" aria-labelledby="proximos">
        <h2 id="proximos">Em breve</h2>
        <Alert kind="info">Contas, cartões e lançamentos chegam na próxima etapa do Fluvi.</Alert>
        {me && <p className="muted">Situação da conta: ativa.</p>}
        <Link to="/seguranca/mfa">Configurar verificação em duas etapas</Link>
      </section>
    </>
  );
}
