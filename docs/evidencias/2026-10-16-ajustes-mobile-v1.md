# Evidência — Ajustes de homologação no celular (rodada 1)

**Data:** 16/10/2026 · **Branch:** `ajustes/mobile-v1` · **Origem:** retorno do responsável usando o iPhone

| Pedido | Causa | Correção |
|---|---|---|
| Nome "Fiance" | grafia da spec v2.2 | **FluviFinance** em marca, título, manifest, meta de iOS e CSV |
| Novo lançamento: opções em quadrado 2×2 | grade com quebra automática | opções lado a lado em colunas iguais; fonte menor em telas estreitas; abas longas de Relatórios em duas linhas (`.segmented.grid-2`) |
| Campo de data passando da tela | largura intrínseca do campo de data no iOS | `appearance: none`, `min-width: 0` e `max-width: 100%` nos campos de data, mês e hora |
| Setas do mês grandes | regra genérica de linha dava 180 px a cada item | componente `MonthNav`: setas de 40 px ao lado do mês (Visão geral e Lançamentos) |
| Botões colados no quadro de baixo (Lançamentos, Contas) | barra de ações sem espaçamento | `.toolbar`; botões em linha mantêm o próprio tamanho |
| Cabeçalho mudando de tamanho e de lugar (Contas e telas abaixo) | grade com altura mínima de tela distribuía a sobra também para a linha do cabeçalho em páginas curtas | `align-content: start` no shell |

**Diagnóstico:** feito no **WebKit (motor do Safari) com tela de iPhone 13 (390 px) e iPhone SE (320 px)**, medindo a largura de todos os elementos de cada tela. Não havia estouro de largura; o problema do cabeçalho era de altura.

**Novo na suíte:** projetos `iphone-webkit` e `iphone-se-webkit` rodam o `responsive.spec` (axe + sem rolagem horizontal) no motor do Safari. O CI passa a instalar o WebKit. O helper de login confere o valor digitado antes de enviar, porque no WebKit o preenchimento automático pode ocorrer antes de a página estabilizar. Uma sonda manual mostrou 0 perdas em 8 tentativas com a página já carregada, então isso não afeta quem digita.

**Testes:** E2E **57/57** (desktop, Chrome 360 px, iPhone 13 WebKit, iPhone SE WebKit); typecheck ok.
