// Mensagens de erro em português, sem expor detalhes internos nem dados de terceiros.
type AnyError = { code?: string; message?: string; status?: number; error?: string } | null | undefined;

const byCode: Record<string, string> = {
  PT429: "Muitas tentativas em pouco tempo. Aguarde um pouco e tente novamente.",
  rate_limited: "Muitas tentativas em pouco tempo. Aguarde um pouco e tente novamente.",
  "42501": "Você não tem permissão para esta ação.",
  forbidden: "Você não tem permissão para esta ação.",
  "40001": "Este registro foi alterado por outra pessoa. Recarregue a página e tente de novo.",
  "23514": "Operação inválida para o estado atual.",
  "23505": "Esta operação já foi registrada com outros dados.",
  invalid_credentials: "E-mail ou senha incorretos.",
  weak_password: "Senha fraca: use pelo menos 12 caracteres, com letras maiúsculas, minúsculas e números.",
  same_password: "A nova senha precisa ser diferente da atual.",
  over_email_send_rate_limit: "Um e-mail já foi enviado há pouco. Aguarde um minuto antes de pedir outro.",
  mfa_verification_failed: "Código incorreto ou expirado. Confira o aplicativo autenticador.",
  already_provisioned: "Este e-mail já pertence a um usuário ativo.",
  identity_conflict: "Já existe uma conta pendente com este e-mail criada por outro processo. Verifique antes de convidar.",
  operation_conflict: "Esta operação já foi registrada com outros dados.",
  invalid_email: "E-mail inválido.",
  invalid_display_name: "Informe um nome com até 80 caracteres.",
  P0002: "Não encontrado ou sem permissão.",
  "22023": "Dados inválidos. Revise os campos.",
  "22P02": "Dados inválidos. Revise os campos.",
};

// Regras de negócio recusadas pelo banco chegam como 23514 com mensagem em português
// (sem dados de terceiros): exibidas como estão.
const businessRule = /^(só |use |compra |operação |esta operação |anule |reverta |estorno|valor acima|crédito |obrigação |transferência |novo total|quantidade |informe |categoria |parcelas |período |cartão )/i;

export function errorMessage(error: unknown): string {
  const e = error as AnyError;
  if (!e) return "";
  if (e.code === "23514" && e.message && businessRule.test(e.message)) {
    return e.message.charAt(0).toUpperCase() + e.message.slice(1) + ".";
  }
  if (e.message && /bloqueada/i.test(e.message)) return "Conta bloqueada. Procure o administrador.";
  const code = e.code ?? e.error;
  if (code && byCode[code]) return byCode[code];
  if (e.status === 429) return byCode.PT429;
  return "Não foi possível concluir. Tente novamente.";
}
