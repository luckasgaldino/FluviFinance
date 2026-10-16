// Layouts autenticados (v2.2 §3): sidebar expandida no desktop; no celular, cabeçalho discreto
// com menu hambúrguer e gaveta lateral, sem barra inferior. O menu abre sem senha; o conteúdo
// das áreas financeiras só aparece depois do desbloqueio (RequireUnlock).
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Link, NavLink, Outlet, useLocation } from "react-router";
import {
  IconCard, IconChart, IconClose, IconHome, IconLayers, IconLock, IconLogout, IconMenu, IconPlus, IconReport,
  IconSettings, IconUnlock, IconUsers, IconList, IconWallet,
} from "../components/icons";
import { Brand } from "../components/ui";
import { useFamily } from "../lib/family";
import { useIsDesktop } from "../lib/device";
import { useFinanceLock } from "../lib/finance-lock";
import { useSession } from "../lib/session";

type NavItem = { to: string; label: string; icon: ReactNode; protected?: boolean; mobileOnly?: boolean };

export const userNav: NavItem[] = [
  { to: "/inicio", label: "Início", icon: <IconHome />, mobileOnly: true },
  { to: "/painel", label: "Visão geral", icon: <IconChart />, protected: true },
  { to: "/lancamentos", label: "Lançamentos", icon: <IconList />, protected: true },
  { to: "/contas", label: "Contas e saldos", icon: <IconWallet />, protected: true },
  { to: "/cartoes", label: "Cartões e faturas", icon: <IconCard />, protected: true },
  { to: "/parcelas", label: "Parcelas", icon: <IconLayers />, protected: true },
  { to: "/relatorios", label: "Relatórios", icon: <IconReport />, protected: true },
  { to: "/configuracoes", label: "Configurações", icon: <IconSettings /> },
];

const adminNav: NavItem[] = [
  { to: "/admin/usuarios", label: "Usuários", icon: <IconUsers /> },
  { to: "/admin/nucleos", label: "Famílias e membros", icon: <IconHome /> },
  { to: "/admin/auditoria", label: "Auditoria", icon: <IconReport /> },
];

function NavList({ items, locked, onPick }: { items: NavItem[]; locked: boolean; onPick?: () => void }) {
  return (
    <nav className="nav" aria-label="Navegação principal">
      {items.map((n) => (
        <NavLink key={n.to} to={n.to} className="nav-link" onClick={onPick}>
          {n.icon}
          <span>{n.label}</span>
          {n.protected && locked && (
            <span className="lock-mark"><IconLock /><span className="visually-hidden">(protegido)</span></span>
          )}
        </NavLink>
      ))}
    </nav>
  );
}

// Ao ir para segundo plano, cobre a tela (melhor esforço para a prévia do alternador de apps).
function PrivacyVeil() {
  const [hidden, setHidden] = useState(false);
  useEffect(() => {
    const onChange = () => setHidden(document.visibilityState === "hidden");
    document.addEventListener("visibilitychange", onChange);
    return () => document.removeEventListener("visibilitychange", onChange);
  }, []);
  if (!hidden) return null;
  return <div className="privacy-veil" aria-hidden="true"><Brand compact /></div>;
}

function Shell({ nav, family, children }: { nav: NavItem[]; family?: boolean; children: ReactNode }) {
  const { session, signOut } = useSession();
  const { unlocked, lock } = useFinanceLock();
  const { active } = useFamily();
  const desktop = useIsDesktop();
  const drawer = useRef<HTMLDialogElement>(null);
  const location = useLocation();
  const items = desktop ? nav.filter((n) => !n.mobileOnly) : nav;
  const financial = nav.some((n) => n.protected);

  // Fecha a gaveta ao trocar de rota.
  useEffect(() => { drawer.current?.close(); }, [location.pathname]);

  const foot = (
    <div className="sidebar-foot">
      <span className="who">{session?.user.email}</span>
      {financial && unlocked && (
        <button className="nav-link" type="button" onClick={() => { lock(); drawer.current?.close(); }}>
          <IconLock /><span>Bloquear área financeira</span>
        </button>
      )}
      <button className="nav-link" type="button" onClick={signOut}><IconLogout /><span>Sair</span></button>
    </div>
  );

  const familyChip = family && (
    <div className="family-chip">
      <span className="label">Família ativa</span>
      <strong>{active?.name ?? "Sem família"}</strong>
    </div>
  );

  return (
    <div className="app-shell">
      <PrivacyVeil />
      {desktop ? (
        <aside className="sidebar" aria-label="Menu lateral">
          <Brand compact />
          {familyChip}
          {financial && <Link className="btn gradient block" to="/novo"><IconPlus />Novo lançamento</Link>}
          <NavList items={items} locked={!unlocked} />
          {foot}
        </aside>
      ) : (
        <>
          <header className="topbar">
            <button className="icon-btn" type="button" aria-label="Abrir menu" aria-haspopup="dialog"
              onClick={() => drawer.current?.showModal()}>
              <IconMenu />
            </button>
            <Brand compact />
            <span className="spacer" />
            {financial && unlocked && (
              <button className="icon-btn" type="button" onClick={lock} aria-label="Bloquear área financeira">
                <IconUnlock />
              </button>
            )}
          </header>
          <dialog ref={drawer} className="drawer" aria-label="Menu"
            onClick={(e) => { if (e.target === drawer.current) drawer.current.close(); }}>
            <div className="drawer-inner">
              <div className="drawer-head">
                <Brand compact />
                <button className="icon-btn" type="button" aria-label="Fechar menu" onClick={() => drawer.current?.close()}>
                  <IconClose />
                </button>
              </div>
              {familyChip}
              <NavList items={items} locked={!unlocked} onPick={() => drawer.current?.close()} />
              {foot}
            </div>
          </dialog>
        </>
      )}
      <main className="main">{children}</main>
    </div>
  );
}

export function AdminLayout() {
  return <Shell nav={adminNav}><Outlet /></Shell>;
}

export function UserLayout() {
  return <Shell nav={userNav} family><Outlet /></Shell>;
}
