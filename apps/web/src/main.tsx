import "./lib/initial-url";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, Navigate, RouterProvider } from "react-router";
import { Loading } from "./components/ui";
import { userHome } from "./lib/device";
import { FamilyProvider } from "./lib/family";
import { FinanceLockProvider } from "./lib/finance-lock";
import { gatePath, SessionProvider, useSession } from "./lib/session";
import type { Gate } from "./lib/supabase";
import { Audit } from "./routes/admin/Audit";
import { Households } from "./routes/admin/Households";
import { Users } from "./routes/admin/Users";
import { Blocked, ForgotPassword, Login, MfaEnroll, MfaVerify, Pending, SetPassword } from "./routes/auth";
import { AccountDetail, Accounts } from "./routes/finance/Accounts";
import { CardDetail, Cards } from "./routes/finance/Cards";
import { InstallmentsPage, Overview, Reports } from "./routes/finance/Insights";
import { NewPurchase, PurchaseDetail } from "./routes/finance/Purchases";
import { NewTransaction, Transactions } from "./routes/finance/Transactions";
import { DiscreetHome, QuickEntry, RequireUnlock } from "./routes/privacy";
import { Settings } from "./routes/settings";
import { AdminLayout, UserLayout } from "./routes/shell";
import "./styles/app.css";

// Dados financeiros e administrativos não são persistidos: cache só em memória, limpo ao
// sair, ao trocar de usuário (SessionProvider) e ao bloquear a área financeira. Nada de
// busca automática ao voltar o foco: o desbloqueio é reavaliado antes de qualquer leitura.
const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false, staleTime: 15_000 } },
});

const pathFor = (gate: Gate) => (gate === "user" ? userHome() : gatePath[gate]);

function GateRedirect() {
  const { gate } = useSession();
  if (gate === "loading") return <Loading />;
  return <Navigate to={pathFor(gate)} replace />;
}

function RequireGate({ allow, children }: { allow: Gate[]; children: ReactNode }) {
  const { gate } = useSession();
  if (gate === "loading") return <Loading />;
  if (!allow.includes(gate)) return <Navigate to={pathFor(gate)} replace />;
  return <>{children}</>;
}

const router = createBrowserRouter([
  { path: "/entrar", element: <RequireGate allow={["anon"]}><Login /></RequireGate> },
  { path: "/esqueci-senha", element: <ForgotPassword /> },
  { path: "/definir-senha", element: <SetPassword /> },
  { path: "/bloqueada", element: <Blocked /> },
  { path: "/pendente", element: <RequireGate allow={["pending"]}><Pending /></RequireGate> },
  { path: "/verificar", element: <RequireGate allow={["mfa-verify"]}><MfaVerify /></RequireGate> },
  { path: "/seguranca/mfa", element: <RequireGate allow={["mfa-enroll", "user", "admin"]}><MfaEnroll /></RequireGate> },
  {
    element: <RequireGate allow={["user"]}><UserLayout /></RequireGate>,
    children: [
      // sem desbloqueio: tela discreta, lançamento rápido e configurações (nenhum dado financeiro)
      { path: "/inicio", element: <DiscreetHome /> },
      { path: "/novo", element: <QuickEntry /> },
      { path: "/configuracoes", element: <Settings /> },
      {
        element: <RequireUnlock />,
        children: [
          { path: "/painel", element: <Overview /> },
          { path: "/contas", element: <Accounts /> },
          { path: "/contas/:id", element: <AccountDetail /> },
          { path: "/lancamentos", element: <Transactions /> },
          { path: "/lancamentos/novo", element: <NewTransaction /> },
          { path: "/cartoes", element: <Cards /> },
          { path: "/cartoes/compra", element: <NewPurchase /> },
          { path: "/cartoes/:id", element: <CardDetail /> },
          { path: "/compras/:id", element: <PurchaseDetail /> },
          { path: "/parcelas", element: <InstallmentsPage /> },
          { path: "/relatorios", element: <Reports /> },
        ],
      },
    ],
  },
  {
    path: "/admin",
    element: <RequireGate allow={["admin"]}><AdminLayout /></RequireGate>,
    children: [
      { index: true, element: <Navigate to="usuarios" replace /> },
      { path: "usuarios", element: <Users /> },
      { path: "nucleos", element: <Households /> },
      { path: "auditoria", element: <Audit /> },
    ],
  },
  { path: "*", element: <GateRedirect /> },
]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <SessionProvider>
        <FamilyProvider>
          <FinanceLockProvider>
            <RouterProvider router={router} />
          </FinanceLockProvider>
        </FamilyProvider>
      </SessionProvider>
    </QueryClientProvider>
  </StrictMode>,
);
