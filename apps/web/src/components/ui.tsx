// Componentes de interface pequenos e acessíveis.
import { useEffect, useId, useRef, type InputHTMLAttributes, type ReactNode } from "react";
import { IconChevronLeft, IconChevronRight } from "./icons";

// Título da página recebe foco ao trocar de rota (leitor de tela anuncia a página).
export function PageTitle({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLHeadingElement>(null);
  useEffect(() => ref.current?.focus(), []);
  return <h1 ref={ref} tabIndex={-1}>{children}</h1>;
}

export function Field({ label, hint, error, ...input }: InputHTMLAttributes<HTMLInputElement> & {
  label: string; hint?: string; error?: string;
}) {
  const id = useId();
  const hintId = hint ? `${id}-hint` : undefined;
  const errId = error ? `${id}-err` : undefined;
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      <input id={id} aria-invalid={error ? true : undefined}
        aria-describedby={[hintId, errId].filter(Boolean).join(" ") || undefined} {...input} />
      {hint && <span id={hintId} className="hint">{hint}</span>}
      {error && <span id={errId} className="hint" style={{ color: "var(--bad-text)" }}>{error}</span>}
    </div>
  );
}

export function Alert({ kind, children }: { kind: "error" | "success" | "info" | "warn"; children: ReactNode }) {
  if (!children) return null;
  return (
    <div className={`alert ${kind}`} role={kind === "error" ? "alert" : "status"}>
      {children}
    </div>
  );
}

export function StatusBadge({ status, label }: { status: string; label: string }) {
  return <span className={`badge ${status}`}>{label}</span>;
}

export function Brand({ compact = false }: { compact?: boolean }) {
  const mark = <div className="brand"><img src="/favicon.svg" alt="" /><span>Fluvi<span className="accent">Finance</span></span></div>;
  if (compact) return mark;
  return (
    <div>
      {mark}
      <div className="tagline">Finanças da família, simples e privadas.</div>
    </div>
  );
}

export function Loading() {
  return <div className="auth-shell" role="status" aria-live="polite">Carregando…</div>;
}

// Navegação de mês: setas pequenas ao lado do nome do mês.
export function MonthNav({ label, onPrev, onNext }: { label: string; onPrev: () => void; onNext: () => void }) {
  return (
    <div className="month-nav">
      <button className="icon-btn" type="button" onClick={onPrev} aria-label="Mês anterior"><IconChevronLeft /></button>
      <strong aria-live="polite">{label}</strong>
      <button className="icon-btn" type="button" onClick={onNext} aria-label="Próximo mês"><IconChevronRight /></button>
    </div>
  );
}
