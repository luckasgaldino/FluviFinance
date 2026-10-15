// Telas de autenticação: entrar, esqueci a senha, definir senha (convite e
// recuperação), MFA (cadastro e verificação), conta pendente e bloqueada.
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { Link, useNavigate } from "react-router";
import { Alert, Brand, Field, PageTitle } from "../components/ui";
import { redirectTo } from "../lib/api";
import { errorMessage } from "../lib/errors";
import { noteLoginPassword } from "../lib/finance-lock";
import { initialLink } from "../lib/initial-url";
import { useSession } from "../lib/session";
import { supabase } from "../lib/supabase";

function AuthCard({ title, children }: { title: string; children: ReactNode }) {
  return (
    <main className="auth-shell">
      <div className="auth-card stack">
        <Brand />
        <PageTitle>{title}</PageTitle>
        {children}
      </div>
    </main>
  );
}

export function Login() {
  const navigate = useNavigate();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    setBusy(true);
    setError("");
    const { error } = await supabase.auth.signInWithPassword({
      email: String(form.get("email")).trim(),
      password: String(form.get("password")),
    });
    setBusy(false);
    if (error) return setError(errorMessage(error));
    noteLoginPassword();
    navigate("/", { replace: true });
  }

  return (
    <AuthCard title="Entrar">
      <form className="stack" onSubmit={onSubmit} noValidate>
        <Field label="E-mail" name="email" type="email" autoComplete="username" required />
        <Field label="Senha" name="password" type="password" autoComplete="current-password" required />
        <Alert kind="error">{error}</Alert>
        <button className="btn" type="submit" disabled={busy}>{busy ? "Entrando…" : "Entrar"}</button>
      </form>
      <Link to="/esqueci-senha">Esqueci minha senha</Link>
    </AuthCard>
  );
}

export function ForgotPassword() {
  const [sent, setSent] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const email = String(new FormData(e.currentTarget).get("email")).trim();
    setBusy(true);
    setError("");
    const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: redirectTo("/definir-senha") });
    setBusy(false);
    // Mesma resposta para e-mail existente, inexistente ou com envio recente:
    // a tela não revela quem tem conta (§19.5).
    if (error && error.code !== "over_email_send_rate_limit" && error.status !== 429) {
      return setError(errorMessage(error));
    }
    setSent(true);
  }

  return (
    <AuthCard title="Recuperar senha">
      {sent ? (
        <Alert kind="success">
          Se o e-mail estiver cadastrado, você receberá um link para definir uma nova senha.
          O link vale por 1 hora e só pode ser usado uma vez.
        </Alert>
      ) : (
        <form className="stack" onSubmit={onSubmit} noValidate>
          <Field label="E-mail" name="email" type="email" autoComplete="username" required />
          <Alert kind="error">{error}</Alert>
          <button className="btn" type="submit" disabled={busy}>Enviar link</button>
        </form>
      )}
      <Link to="/entrar">Voltar para entrar</Link>
    </AuthCard>
  );
}

const linkErrors: Record<string, string> = {
  otp_expired: "Este link expirou ou já foi usado. Peça um novo.",
  access_denied: "Não foi possível validar o link. Peça um novo.",
};

export function SetPassword() {
  const { session, refresh } = useSession();
  const navigate = useNavigate();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const isInvite = initialLink.type === "invite";

  if (initialLink.errorCode || initialLink.errorDescription) {
    const blocked = /bloqueada/i.test(initialLink.errorDescription ?? "");
    return (
      <AuthCard title="Link inválido">
        <Alert kind="error">
          {blocked ? "Conta bloqueada. Procure o administrador."
            : linkErrors[initialLink.errorCode ?? ""] ?? "Este link não é válido. Peça um novo."}
        </Alert>
        <Link to="/esqueci-senha">Pedir novo link</Link>
      </AuthCard>
    );
  }
  if (session === undefined) return <AuthCard title="Definir senha"><p role="status">Validando link…</p></AuthCard>;
  if (session === null) {
    return (
      <AuthCard title="Definir senha">
        <Alert kind="info">Abra esta página pelo link recebido por e-mail.</Alert>
        <Link to="/esqueci-senha">Pedir novo link</Link>
      </AuthCard>
    );
  }

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const password = String(form.get("password"));
    if (password !== String(form.get("confirm"))) return setError("As senhas não conferem.");
    setBusy(true);
    setError("");
    const { error } = await supabase.auth.updateUser({ password });
    if (error) {
      setBusy(false);
      return setError(errorMessage(error));
    }
    // a ativação (pending → active) acontece no banco ao definir a senha
    noteLoginPassword();
    await refresh();
    navigate("/", { replace: true });
  }

  return (
    <AuthCard title={isInvite ? "Ative sua conta" : "Definir nova senha"}>
      <p className="muted">Conta: {session.user.email}</p>
      <form className="stack" onSubmit={onSubmit} noValidate>
        <Field label="Nova senha" name="password" type="password" autoComplete="new-password" required
          minLength={12} hint="Mínimo de 12 caracteres, com letras maiúsculas, minúsculas e números." />
        <Field label="Confirme a senha" name="confirm" type="password" autoComplete="new-password" required />
        <Alert kind="error">{error}</Alert>
        <button className="btn" type="submit" disabled={busy}>Salvar senha</button>
      </form>
    </AuthCard>
  );
}

export function MfaEnroll() {
  const { gate, totp, refresh } = useSession();
  const navigate = useNavigate();
  const [factor, setFactor] = useState<{ id: string; qr: string; secret: string } | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const started = useRef(false);
  const required = gate === "mfa-enroll";

  useEffect(() => {
    if (totp.length > 0 || started.current) return;
    started.current = true;
    (async () => {
      // remove cadastros iniciados e não concluídos antes de começar outro
      const { data } = await supabase.auth.mfa.listFactors();
      for (const f of data?.all ?? []) {
        if (f.status === "unverified") await supabase.auth.mfa.unenroll({ factorId: f.id });
      }
      const { data: enrolled, error } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: "Fluvi" });
      if (error) return setError(errorMessage(error));
      setFactor({ id: enrolled.id, qr: enrolled.totp.qr_code, secret: enrolled.totp.secret });
    })();
  }, [totp.length]);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!factor) return;
    setBusy(true);
    setError("");
    const code = String(new FormData(e.currentTarget).get("code")).replace(/\s/g, "");
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code });
    setBusy(false);
    if (error) return setError(errorMessage({ ...error, code: "mfa_verification_failed" }));
    await refresh();
    navigate("/", { replace: true });
  }

  if (totp.length > 0) {
    return (
      <AuthCard title="Verificação em duas etapas">
        <Alert kind="success">A verificação em duas etapas está ativa nesta conta.</Alert>
        <Link to="/">Voltar</Link>
      </AuthCard>
    );
  }

  return (
    <AuthCard title="Ativar verificação em duas etapas">
      {required
        ? <Alert kind="info">Contas administrativas precisam de verificação em duas etapas antes de qualquer operação.</Alert>
        : <p className="muted">Opcional para sua conta, mas recomendado.</p>}
      <ol className="stack" style={{ paddingLeft: 20, margin: 0 }}>
        <li>Abra um aplicativo autenticador (Google Authenticator, Microsoft Authenticator, 1Password…).</li>
        <li>Leia o QR code ou digite a chave manualmente.</li>
        <li>Informe o código de 6 dígitos gerado.</li>
      </ol>
      {factor ? (
        <>
          <img className="qr" src={factor.qr} alt="QR code para cadastrar o Fluvi no aplicativo autenticador" />
          <div>
            <span className="muted">Chave para digitação manual:</span>{" "}
            <code data-testid="totp-secret">{factor.secret}</code>
          </div>
          <form className="stack" onSubmit={onSubmit} noValidate>
            <Field label="Código de 6 dígitos" name="code" inputMode="numeric" autoComplete="one-time-code"
              pattern="[0-9]*" maxLength={6} required />
            <Alert kind="error">{error}</Alert>
            <button className="btn" type="submit" disabled={busy}>Confirmar</button>
          </form>
        </>
      ) : (
        <>
          <Alert kind="error">{error}</Alert>
          {!error && <p role="status">Preparando…</p>}
        </>
      )}
    </AuthCard>
  );
}

export function MfaVerify() {
  const { totp, refresh, signOut } = useSession();
  const navigate = useNavigate();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const factor = totp[0];
    if (!factor) return;
    setBusy(true);
    setError("");
    const code = String(new FormData(e.currentTarget).get("code")).replace(/\s/g, "");
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code });
    setBusy(false);
    if (error) return setError(errorMessage({ ...error, code: "mfa_verification_failed" }));
    await refresh();
    navigate("/", { replace: true });
  }

  return (
    <AuthCard title="Verificação em duas etapas">
      <form className="stack" onSubmit={onSubmit} noValidate>
        <Field label="Código do aplicativo autenticador" name="code" inputMode="numeric"
          autoComplete="one-time-code" pattern="[0-9]*" maxLength={6} required />
        <Alert kind="error">{error}</Alert>
        <button className="btn" type="submit" disabled={busy}>Verificar</button>
      </form>
      <button className="btn link" type="button" onClick={signOut}>Sair</button>
    </AuthCard>
  );
}

export function Pending() {
  const { signOut } = useSession();
  return (
    <AuthCard title="Ativação pendente">
      <Alert kind="warn">
        Sua conta ainda não foi ativada. Use o link do convite recebido por e-mail para definir sua senha.
      </Alert>
      <button className="btn secondary" type="button" onClick={signOut}>Sair</button>
    </AuthCard>
  );
}

export function Blocked() {
  return (
    <AuthCard title="Conta bloqueada">
      <Alert kind="error">Conta bloqueada. Procure o administrador.</Alert>
      <Link to="/entrar">Voltar para entrar</Link>
    </AuthCard>
  );
}
