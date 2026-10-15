import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["integration/**/*.test.ts"],
    globalSetup: ["integration/global-setup.ts"],
    // um único banco local compartilhado: arquivos em sequência
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 60_000,
  },
});
