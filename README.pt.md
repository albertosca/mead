🇧🇷 [Português](README.pt.md) · 🇺🇸 [English](README.md)

# mead

**Roteador Inteligente de LLMs & Runtime de Agentes Consciente de Custos construído sobre a BEAM / OTP.**

O `mead` é um motor de orquestração tolerante a falhas projetado para gerenciar conversas com inteligência artificial, coordenar múltiplos modelos e expor ferramentas através do protocolo Model Context Protocol (MCP). Construído sobre a máquina virtual BEAM (Erlang/Elixir), cada turno de conversa e chamada de ferramenta externa roda dentro de processos supervisionados e isolados (modelo de atores).

---

## Arquitetura do Ecossistema

O `mead` forma o núcleo de execução de uma plataforma desacoplada em três repositórios:

* **`mead` (este repositório):** Motor central em Elixir/OTP, agendador híbrido com corte de custos (Ollama local vs. provedores de nuvem) e Hub MCP concorrente.
* **[`agent-swarm-deck`](../agent-swarm-deck):** Cliente multiplataforma em Flutter com interface *Action-First* (cards interativos de aprovação, barras de progresso ao vivo, modais estruturados).
* **[`open-butler`](../open-butler):** Aplicação de domínio do assistente pessoal com regras de automação (rotinas diárias, triagem de e-mail, organização de agenda) e ponte segura para scripts locais.

---

## Pilares Principais

1. **Supervisão por Modelo de Atores:** Cada sessão de usuário ativa é supervisionada dinamicamente (`DynamicSupervisor`). Erros de timeout ou falhas em ferramentas externas são isolados naquele turno específico sem derrubar o restante do sistema.
2. **Agendador Híbrido de Custo e Modelos:** Um classificador de baixa latência (<200ms) avalia a intenção da entrada, roteando tarefas mecânicas e simples para modelos locais (Ollama, com o modelo que o operador escolher; o uso de tools exige um modelo que as suporte, como o Llama 3.1) com custo zero e total privacidade, reservando modelos de nuvem (Claude / Gemini) para síntese e raciocínio deliberado.
3. **Hub MCP Concorrente:** Atua simultaneamente como cliente MCP (agregando ferramentas externas via stdio/HTTP) e servidor MCP (permitindo que agentes de terminal se conectem ao `mead`).
4. **Telemetria e Livro-Razão de Tokens:** Contabilidade rigorosa de tokens de entrada e saída, latência e custo financeiro por sessão.

---

## Documentação Técnica

* Arquitetura detalhada e árvore de supervisão: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
* Diretrizes operacionais e regras para agentes: [AGENTS.md](AGENTS.md)
* Histórico e registro do projeto: [docs/superpowers/PROJECT-LOG.md](docs/superpowers/PROJECT-LOG.md)

---

## Licença

MIT © Alberto Cavalcanti
