import "./lib/initial-url";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, Navigate, RouterProvider } from "react-router";
import { Loading } from "./components/ui";
import { gatePath, SessionProvider, useSession } from "./lib/session";
import type { Gate } from "./lib/supabase";
import { Audit } from "./routes/admin/Audit";
import { Grants } from "./routes/admin/Grants";
import { Households } from "./routes/admin/Households";
import { Users } from "./routes/admin/Users";
import { Blocked, ForgotPassword, Login, MfaEnroll, MfaVerify, Pending, SetPassword } from "./routes/auth";
import { AccountDetail, Accounts } from "./routes/finance/Accounts";
import { CardDetail, Cards } from "./routes/finance/Cards";
import { NewPurchase, PurchaseDetail } from "./routes/finance/Purchases";
import { NewTransaction, Transactions } from "./routes/finance/Transactions";
import { AdminLayout, Home, UserLayout } from "./routes/shell";
import "./styles/app.css";

// Dados financeiros e administrativos não são persistidos: cache só em memória,
// limpo ao sair ou trocar de usuário (SessionProvider).
const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: true, staleTime: 15_000 } },
});

function GateRedirect() {
  const { gate } = useSession();
  if (gate === "loading") return <Loading />;
  return <Navigate to={gatePath[gate]} replace />;
}

function RequireGate({ allow, children }: { allow: Gate[]; children: ReactNode }) {
  const { gate } = useSession();
  if (gate === "loading") return <Loading />;
  if (!allow.includes(gate)) return <Navigate to={gatePath[gate]} replace />;
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
      { path: "/inicio", element: <Home /> },
      { path: "/contas", element: <Accounts /> },
      { path: "/contas/:id", element: <AccountDetail /> },
      { path: "/lancamentos", element: <Transactions /> },
      { path: "/lancamentos/novo", element: <NewTransaction /> },
      { path: "/cartoes", element: <Cards /> },
      { path: "/cartoes/compra", element: <NewPurchase /> },
      { path: "/cartoes/:id", element: <CardDetail /> },
      { path: "/compras/:id", element: <PurchaseDetail /> },
    ],
  },
  {
    path: "/admin",
    element: <RequireGate allow={["admin"]}><AdminLayout /></RequireGate>,
    children: [
      { index: true, element: <Navigate to="usuarios" replace /> },
      { path: "usuarios", element: <Users /> },
      { path: "nucleos", element: <Households /> },
      { path: "permissoes", element: <Grants /> },
      { path: "auditoria", element: <Audit /> },
    ],
  },
  { path: "*", element: <GateRedirect /> },
]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <SessionProvider>
        <RouterProvider router={router} />
      </SessionProvider>
    </QueryClientProvider>
  </StrictMode>,
);
