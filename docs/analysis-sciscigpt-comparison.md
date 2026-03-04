# SciSciGPT vs. Impress: A Comparative Analysis

## Context

This document contrasts the ideas in **"SciSciGPT: advancing human–AI collaboration in the science of science"** (Shao, Wang, Qian, Pan, Liu & Wang; *Nature Computational Science*, Dec 2025) with the design philosophy and implementation of **impress-apps**. The goal is to identify deep similarities, fundamental differences, and — most importantly — ideas from SciSciGPT that our approach currently lacks.

Sources:
- [SciSciGPT paper](https://www.nature.com/articles/s43588-025-00906-6)
- [Companion editorial](https://www.nature.com/articles/s43588-025-00935-1)
- [arXiv preprint](https://arxiv.org/abs/2504.05559)
- [GitHub](https://github.com/Northwestern-CSSI/SciSciGPT)

---

## 1. Shared Convictions

Both projects arrive at strikingly similar conclusions about what a research-oriented AI system needs, despite targeting different domains (science-of-science vs. general research workflow) and using very different technology stacks (Python/LangChain/cloud vs. Rust/Swift/local-first).

### 1.1 Multi-Agent Specialization

Both systems reject the "one monolithic LLM" approach in favor of **specialized agents with distinct roles**.

| SciSciGPT | Impress (impel) |
|-----------|-----------------|
| ResearchManager, LiteratureSpecialist, DatabaseSpecialist, AnalyticsSpecialist, EvaluationSpecialist | Research, Code, Verification, Adversarial, Review, Librarian agent archetypes |

Both recognize that different research tasks require different cognitive modes — literature synthesis is not data analysis is not quality assessment. The taxonomies are remarkably parallel: SciSciGPT's LiteratureSpecialist ↔ impel's Librarian; AnalyticsSpecialist ↔ Code agent; EvaluationSpecialist ↔ Verification + Adversarial agents.

### 1.2 Human-in-the-Loop as a Design Principle

Both systems are **intentionally not fully autonomous**. SciSciGPT's companion editorial states: "SciSciGPT is intentionally not fully automated, serving instead as a conversational AI collaborator that allows for iterative human–AI collaborations." Impress's CLAUDE.md states: "Human review points are explicit and respected."

Both treat human oversight not as a limitation to be minimized but as a feature to be designed for.

### 1.3 Auditability and Reproducibility

Both systems prioritize making agent actions inspectable:
- **SciSciGPT**: XML semantic tags preserve full provenance; collapsible UI doesn't discard audit data
- **Impress**: Event sourcing with `actor`, `causation_id`, `correlation_id` fields enables time-travel debugging and full audit trails

### 1.4 Cross-Tool Orchestration

Both systems coordinate multiple capabilities as a unified workflow rather than isolated tools. SciSciGPT routes through its ResearchManager; impel coordinates across imbib, imprint, implore, and impart via SiblingBridge HTTP APIs and the MCP server.

### 1.5 Researcher as Primary User

Both assume intelligent, domain-expert users. Neither system tries to replace the researcher's judgment — both aim to accelerate and augment.

---

## 2. Fundamental Architectural Differences

### 2.1 Coordination Topology: Central Conductor vs. Stigmergic Swarm

This is the deepest architectural divergence.

**SciSciGPT** uses a **hierarchical, push-based model**. The ResearchManager decomposes tasks and assigns them to specialists. Control flow is explicit: user → ResearchManager → specialist → EvaluationSpecialist → ResearchManager → next specialist. This is a classic orchestrator pattern.

**Impress (impel)** uses a **stigmergic, pull-based model** (ADR-001, ADR-007). There is no central scheduler. Agents observe shared state (temperature signals, thread status), autonomously select their own work, claim threads advisory-ly, and coordinate through the environment itself — like ants leaving pheromone trails. Human attention is a multiplicative temperature boost, not a direct assignment.

**Implications**: SciSciGPT's approach is simpler to reason about and implement (linear task decomposition), but has a single point of failure/bottleneck in the ResearchManager. Impel's approach scales more naturally, handles failure gracefully (no central coordinator to crash), and maps more faithfully to how real research groups work — but is harder to implement and reason about correctness.

### 2.2 Infrastructure Philosophy: Cloud-Native vs. Local-First

**SciSciGPT** is thoroughly cloud-native: Google BigQuery for data, Pinecone for vector search, Google Cloud Storage for artifacts, Vertex AI for LLM inference, Redis for session state.

**Impress** is militantly local-first: SQLite/Core Data for persistence, localhost-only HTTP servers, no mandatory cloud dependency, user owns all data.

This reflects fundamentally different trust models. SciSciGPT trusts cloud infrastructure and optimizes for data scale (11M papers, 78M citations). Impress trusts the user's machine and optimizes for privacy, sovereignty, and offline capability.

### 2.3 Interaction Modality: Chat Interface vs. Keyboard-First Native UI

**SciSciGPT**: Web-based chat interface (Next.js), like ChatGPT. Interaction is conversational — users type natural language queries, see streaming responses.

**Impress**: Native macOS application with vim-style keyboard navigation, command palettes, modal editing. Interaction is direct manipulation — users navigate, select, and act on objects.

SciSciGPT optimizes for *expressiveness* (say what you want in natural language). Impress optimizes for *flow* (hands never leave the keyboard, actions are instantaneous).

### 2.4 Scope: Domain-Specific vs. Domain-General

**SciSciGPT** is deeply domain-specific: purpose-built for science-of-science research, with a curated data lake (SciSciNet, 19 tables), domain-specific RAG corpus, and specialized SQL schemas mapping to established SciSci concepts.

**Impress** is domain-general for research: bibliography management, manuscript authoring, data visualization, email, and agent orchestration — applicable across any research field.

---

## 3. Deep Ideas from SciSciGPT That Impress Lacks

These are the most valuable takeaways — ideas that could meaningfully strengthen the impress architecture.

### 3.1 Closed-Loop Self-Evaluation (Verbal Reinforcement Learning)

**What SciSciGPT does**: The EvaluationSpecialist performs three-stage quality assessment after every specialist's work: (1) tool evaluation (did individual tool calls succeed?), (2) visual evaluation (are visualizations correct?), (3) workflow evaluation (is the complete execution chain sound?). Each assessment produces a **reward score**. Based on the score, the system either continues, makes minor adjustments, or **backtracks for major revisions**.

This is based on the Reflexion framework (Shinn et al., NeurIPS 2023) — "verbal reinforcement learning" where agents improve through linguistic self-reflection rather than weight updates.

**What Impress lacks**: Impel has Verification and Adversarial agents (ADR-005), but these are *separate agents in the swarm*, not an integrated evaluation loop. There is no mechanism for an agent to receive a quality score after completing work, no automated backtracking, and no reward signal driving iterative refinement. Impel's verification is **external critique** (another agent checks your work); SciSciGPT's is **integrated self-improvement** (the system evaluates itself and adapts).

**Why this matters**: Without a closed evaluation loop, impel agents can produce work of unknown quality. The temperature system guides *what* to work on, but nothing evaluates *how well* the work was done. Adding a reward-score mechanism to impel's event system — where verification agents post quality assessments that affect thread temperature — would create a similar feedback loop while preserving the stigmergic model.

### 3.2 Structured Reasoning via Semantic Tags

**What SciSciGPT does**: Uses a comprehensive XML tag taxonomy (`<thinking>`, `<step>`, `<reflection>`, `<answer>`, `<count>`, `<reward>`) to structure the LLM's reasoning process. These tags serve dual purposes: (1) they guide the LLM into deeper, more systematic analysis, and (2) they create machine-readable structure that the UI can selectively display or fold.

**What Impress lacks**: Impel's agents don't use structured reasoning tags. The event system records *what happened* (event payloads), but doesn't structure *how agents think*. There's no taxonomy of cognitive stages, no mechanism to make the reasoning process itself inspectable at different granularities.

**Why this matters**: Structured reasoning tags create a **separation between audit sufficiency and display density**. The system can show users a high-level summary while preserving the full reasoning chain for debugging or reproduction. This is particularly relevant for impel, where multi-level views (ADR-009, Levels 1-4) already implement information density hierarchy for *events* — extending this to *reasoning processes within events* would add a powerful dimension.

### 3.3 Cognitive Load Management Through Selective Display

**What SciSciGPT does**: Because agent outputs are XML-tagged with semantic meaning, the UI can **automatically fold or hide low-level details by default** while preserving full transparency. Collapsible toggles let motivated readers drill into provenance without forcing casual users to wade through logs.

**What Impress lacks**: Impel's multi-level view hierarchy (Program → Project → Thread → Event, ADR-009) is excellent for *navigating* the hierarchy but doesn't have a concept of **automatically summarizing within a level**. An event is either shown or not shown. There's no progressive disclosure of event content — no way to show "agent completed literature review (score: 0.92)" at one level and the full search queries, retrieved documents, and synthesis at another.

**Why this matters**: As impel manages more complex, longer-running research projects, the raw event stream will become overwhelming. SciSciGPT's approach of semantic-tagged outputs that UI can fold/expand provides a model for how impel's Event View (Level 4) could offer progressive disclosure rather than flat content display.

### 3.4 Domain-Grounded Data Lakes

**What SciSciGPT does**: Ships with SciSciNet — a massive, structured data repository (11M+ papers, 78M+ citation relationships, 19 relational tables) with column descriptions mapped to established domain concepts. The DatabaseSpecialist uses SQL + embedding-based entity matching to navigate this data.

**What Impress lacks**: Imbib manages the user's personal bibliography (local BibTeX/Core Data), and the MCP server can search it. But there's no concept of a large-scale structured data lake that agents can query. If a researcher asks "what's the citation pattern for papers in my field?", imbib can only answer from the user's personal collection, not from a comprehensive scholarly database.

**Why this matters**: The power of SciSciGPT's case studies — replicating citation analyses, computing disruption indices from scratch, mapping collaboration networks — comes from having **data at scale** that agents can query programmatically. Impress could benefit from integrating with open scholarly APIs (OpenAlex, Semantic Scholar, CrossRef) through impel adapters, giving agents access to the broader scholarly landscape while maintaining the local-first philosophy (query remote, cache locally).

### 3.5 Multimodal Input as Research Interface

**What SciSciGPT does**: In one case study, a researcher uploads a *screenshot of a figure* from a published paper and asks SciSciGPT to interpret and replicate it. The system parses the visual, identifies the underlying analysis, extracts the right data, and generates a comparable visualization.

**What Impress lacks**: The MCP server and impel adapters work with text (BibTeX keys, document content, structured data). There's no pathway for a researcher to say "here's a figure I saw — reproduce this analysis." The visual ↔ analytical pipeline doesn't exist.

**Why this matters**: This is perhaps the most compelling research-workflow innovation in SciSciGPT. Researchers constantly encounter figures in papers and think "I want to do this with my data." Bridging from visual input to structured analysis eliminates a significant cognitive translation step. For implore (data visualization), adding multimodal input — where a user can provide a reference visualization and have the system generate code to produce something similar — would be genuinely transformative.

### 3.6 Capability Maturity Model as Meta-Framework

**What SciSciGPT does**: Proposes a four-level maturity model for AI research tools: (1) Functional Capabilities → (2) Workflow Orchestration → (3) Memory Architecture → (4) Human-AI Interaction. Each level builds on the previous. This serves as both a design guide and a self-assessment framework.

**What Impress lacks**: The CLAUDE.md has a Decision-Making Heuristic (flow → keyboard → agents → consistency → intelligence), but this is a *prioritization* guide for individual decisions, not a *maturity* framework for assessing the system's overall capability level.

**Why this matters**: A maturity model provides a roadmap. It answers "what should we build next?" systematically. Looking at impel through SciSciGPT's lens:
- Level 1 (Functional Capabilities): ✅ Strong — MCP tools, HTTP APIs, cross-app bridges
- Level 2 (Workflow Orchestration): ✅ Strong — Stigmergic coordination, pull-based work selection, temperature-based attention
- Level 3 (Memory Architecture): ⚠️ Partial — Event sourcing provides persistence, but no cross-session memory, no agent adaptation, no learned preferences
- Level 4 (Human-AI Interaction): ⚠️ Partial — Escalation system exists, but no progressive conversational refinement, no chat-based exploration mode

This analysis reveals that impel's **weakest area is memory across sessions** — agents start fresh each time, with no personalization or accumulated learning.

### 3.7 Formal Comparative Evaluation with Human Researchers

**What SciSciGPT does**: Conducted a controlled comparison where three researchers (predoc, PhD, postdoc) performed identical tasks with standard tools, while SciSciGPT performed the same tasks. SciSciGPT completed work in ~1/10th the time with higher ratings on effectiveness, technical soundness, analytical depth, visualization, and documentation.

**What Impress lacks**: No formal evaluation of any kind. No measurement of whether the suite actually improves research workflows compared to alternatives. No data on time savings, quality improvements, or user satisfaction.

**Why this matters**: Without evaluation, "flow above all" and "sustained flow for human and agentic colleagues" are aspirational claims, not demonstrated outcomes. Even a small-scale user study comparing research tasks done with-and-without impress would provide invaluable signal about what's actually working and what needs improvement.

---

## 4. Ideas Where Impress Is Ahead

For completeness, areas where impress has deeper solutions than SciSciGPT:

### 4.1 Decentralized Coordination
Impel's stigmergic model is fundamentally more sophisticated than SciSciGPT's hierarchical orchestrator. The temperature-based attention, pull-based work selection, and emergent coordination represent genuinely novel approaches to multi-agent research systems.

### 4.2 Trust Architecture
Impel's invariants (Verifier ≠ Producer, Adversary ≠ Team, Operator ≠ Research) enforce structural separation of concerns that SciSciGPT doesn't address. The EvaluationSpecialist in SciSciGPT evaluates everyone's work, including its own system's — there's no independence guarantee.

### 4.3 Typed Escalation Taxonomy
Impel's six escalation categories (Decision, Novelty, Stuck, Scope, Quality, Checkpoint) with defined priorities provide much richer vocabulary for human-AI communication than SciSciGPT's chat-based interaction.

### 4.4 Cross-Application Integration
Impress's suite of native apps (imbib, imprint, implore, impart, impel) sharing state through SiblingBridge provides a richer integration surface than SciSciGPT's single chat interface. Researchers can work in specialized tools while agents orchestrate across them.

### 4.5 Privacy and Data Sovereignty
Local-first, no mandatory cloud, localhost-only HTTP. SciSciGPT's cloud dependencies (BigQuery, Pinecone, GCS, Vertex AI) make it unsuitable for sensitive research data.

### 4.6 Keyboard-First Native Performance
Native macOS with vim-style keybindings, sub-frame response times. SciSciGPT's web-based chat requires constant context switching between typing queries and doing actual research work.

---

## 5. Synthesis: What Should Impress Learn from This Paper?

Priority-ordered actionable insights:

1. **Add a reward/quality signal to the event system.** When verification or adversarial agents assess work, their assessment should produce a structured quality score that feeds back into thread temperature and guides re-work. This closes the evaluation loop without requiring SciSciGPT's centralized architecture. *(Addresses §3.1)*

2. **Implement progressive disclosure within events.** Extend the Level 4 Event View to support collapsible detail layers. Agent events should have summary, detail, and provenance levels — not just flat content. *(Addresses §3.3)*

3. **Integrate open scholarly APIs.** Add OpenAlex/Semantic Scholar/CrossRef adapters so agents can answer questions about the broader scholarly landscape, not just the user's personal library. This preserves local-first (query remote, cache locally) while enabling SciSciGPT-style analytical workflows. *(Addresses §3.4)*

4. **Add cross-session memory for agents.** Currently agents start fresh each session. Implementing a memory layer — learned preferences, past decisions, accumulated context — would address the maturity model's Level 3 gap. *(Addresses §3.6)*

5. **Design a formal evaluation protocol.** Define standard research tasks, recruit a small group of researchers, measure time-to-completion and quality with-and-without impress. Even n=5 would provide signal. *(Addresses §3.7)*

6. **Explore multimodal input paths.** Especially for implore: "reproduce this figure" from an image input. This is a high-impact interaction pattern for data-oriented researchers. *(Addresses §3.5)*

7. **Structure agent reasoning with semantic stages.** Have agents tag their reasoning process (hypothesis → search → evidence → synthesis → conclusion) to enable better display, debugging, and reproducibility. *(Addresses §3.2)*

---

## Verification

This is an analysis document, not code. Verification = review for accuracy and completeness. The document should be committed to the repository for reference.
