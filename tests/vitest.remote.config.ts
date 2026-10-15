import { defineConfig } from "vitest/config";

// Testes contra o Supabase hospedado (projeto de desenvolvimento). Não rodam no CI.
export default defineConfig({
  test: { include: ["remote/**/*.test.ts"], fileParallelism: false, testTimeout: 60_000 },
});
