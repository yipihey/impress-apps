const $ = (selector) => document.querySelector(selector);

const elements = {
  manifest: $("#app-manifest"),
  brand: $("#brand"),
  brandName: $("#brand-name"),
  connection: $("#connection"),
  model: $("#model-select"),
  chatsButton: $("#chats-button"),
  chatsPanel: $("#chats-panel"),
  closeChats: $("#close-chats"),
  threadsTitle: $("#threads-title"),
  threadsSubtitle: $("#threads-subtitle"),
  conversationList: $("#conversation-list"),
  settingsButton: $("#settings-button"),
  settingsPanel: $("#settings-panel"),
  system: $("#system-prompt"),
  temperature: $("#temperature"),
  temperatureValue: $("#temperature-value"),
  maxTokens: $("#max-tokens"),
  thinking: $("#thinking"),
  webAccess: $("#web-access"),
  conversation: $("#conversation"),
  welcome: $("#welcome"),
  welcomeEyebrow: $("#welcome-eyebrow"),
  welcomeTitle: $("#welcome-title"),
  welcomeCopy: $("#welcome-copy"),
  messages: $("#messages"),
  composer: $("#composer"),
  prompt: $("#prompt"),
  send: $("#send-button"),
  stop: $("#stop-button"),
  newChat: $("#new-chat"),
  privacyNote: $("#privacy-note"),
};

const queryParameters = new URLSearchParams(location.search);
const queryToken = queryParameters.get("token");
const fragmentParameters = new URLSearchParams(location.hash.slice(1));
const fragmentToken = fragmentParameters.get("token");
const pairingTicket = fragmentParameters.get("pair");
const requestedProfile = fragmentParameters.get("profile") || queryParameters.get("profile");
const appProfile = location.pathname === "/vw" || location.pathname === "/vw/" || requestedProfile === "vw"
  ? "vw"
  : "default";
const STORE = `localmodels-mobile-v1-${appProfile}`;
const suppliedToken = fragmentToken || queryToken;
if (suppliedToken) {
  sessionStorage.setItem("localmodels-token", suppliedToken);
}
if (suppliedToken || pairingTicket) {
  const retainedQuery = appProfile === "vw" && !location.pathname.startsWith("/vw")
    ? "?profile=vw"
    : "";
  history.replaceState(null, "", `${location.pathname}${retainedQuery}`);
}
let accessToken = sessionStorage.getItem("localmodels-token") || "";

let state = loadState();
applyAppProfile();
let controller = null;
let currentConversationId = "";
let sharedConversations = [];
let conversationSignature = "";
let polling = false;
let mathTypesetChain = Promise.resolve();
let renamingConversationId = "";

function syncViewportHeight() {
  const height = window.visualViewport?.height || window.innerHeight;
  document.documentElement.style.setProperty("--app-height", `${Math.round(height)}px`);
}

function loadState() {
  const fallback = appProfile === "vw" ? {
    model: "mlx-community--Qwen3.5-122B-A10B-4bit",
    system: "You are a VW Type 2 knowledge assistant focused on the 1978 California L-Jetronic configuration. Use the vw tool before making factual repair claims. Cite the source title, PDF page, and citation identifier. Treat OCR as unreviewed evidence, distinguish configuration applicability, never invent measurements or specifications, and state clearly when the sources do not support an answer.",
    temperature: 0.1,
    maxTokens: 3072,
    thinking: false,
    webAccess: false,
    enabledTools: ["vw"],
    messages: [],
  } : {
    model: "",
    system: "Be precise, thoughtful, and honest about uncertainty.",
    temperature: 0.2,
    maxTokens: 2048,
    thinking: false,
    webAccess: true,
    enabledTools: ["web"],
    messages: [],
  };
  try {
    const saved = JSON.parse(localStorage.getItem(STORE));
    return { ...fallback, ...saved, messages: Array.isArray(saved?.messages) ? saved.messages : [] };
  } catch {
    return fallback;
  }
}

function applyAppProfile() {
  if (appProfile !== "vw") return;
  document.title = "VW Knowledge · Impress";
  elements.manifest.href = "/vw/site.webmanifest";
  elements.brand.setAttribute("aria-label", "VW Knowledge");
  elements.brandName.textContent = "VW Knowledge";
  elements.threadsTitle.textContent = "VW conversations";
  elements.threadsSubtitle.textContent = "Stored on your Mac and shared across paired phones";
  elements.welcomeEyebrow.textContent = "1978 CALIFORNIA TYPE 2";
  elements.welcomeTitle.innerHTML = "Cited workshop knowledge,<br>within reach.";
  elements.welcomeCopy.textContent = "Ask your local model to search the official service and fuel-injection manuals. Open the cited page before relying on a repair detail.";
  elements.prompt.placeholder = "Ask the VW manuals";
  elements.privacyNote.textContent = "Model runs on your Mac · Manual retrieval stays deterministic · Verify cited pages before repair work";
  const suggestions = document.querySelectorAll("[data-prompt]");
  const presets = [
    ["Search the double relay", "Search the admitted VW sources for information about the L-Jetronic double relay. Summarize only what the sources support and cite each relevant PDF page."],
    ["Investigate a no-start", "Help investigate a 1978 California VW Type 2 that cranks but does not start. Begin with source-backed questions and safe checks; do not assume measurements I have not supplied."],
    ["Find fuel-pressure tests", "Find the fuel-pressure testing procedures in the admitted VW sources. Explain their applicability and cite the relevant PDF pages."],
  ];
  suggestions.forEach((button, index) => {
    const preset = presets[index];
    if (!preset) return;
    button.innerHTML = `${preset[0]} <span>↗</span>`;
    button.dataset.prompt = preset[1];
  });
}

function saveState() {
  localStorage.setItem(STORE, JSON.stringify(state));
}

function normalizedState(candidate) {
  const fallback = loadState();
  return {
    ...fallback,
    ...(candidate || {}),
    enabledTools: Array.isArray(candidate?.enabledTools) ? candidate.enabledTools : fallback.enabledTools,
    messages: Array.isArray(candidate?.messages) ? candidate.messages : [],
  };
}

async function apiRequest(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { ...apiHeaders(Boolean(options.body)), ...(options.headers || {}) },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(body.error || `Request failed with HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return body;
}

async function redeemPairingTicket() {
  if (!pairingTicket || accessToken) return;
  const response = await fetch("/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ticket: pairingTicket }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body.access_token) {
    const error = new Error(body.error || "This pairing link is invalid, expired, or already used.");
    error.status = response.status;
    throw error;
  }
  accessToken = body.access_token;
  sessionStorage.setItem("localmodels-token", accessToken);
}

function describeConnectionError(error) {
  if (error?.status === 401) {
    setConnection("pairing", "Pairing required");
    return `This browser reached your Mac, but pairing failed. ${error?.message || "Request a new single-use pairing link."}`;
  }
  setConnection("offline", "Mac offline");
  return `Connection problem: ${error?.message || "The Mac service is unavailable."}`;
}

function acceptConversationList(body) {
  sharedConversations = Array.isArray(body.conversations) ? body.conversations : [];
  renderConversationList();
}

function applyConversationView(view, scrollToEnd = false) {
  if (!view?.conversation) return;
  currentConversationId = view.conversation.id;
  state = normalizedState({
    ...state,
    model: view.conversation.model || state.model,
    enabledTools: view.conversation.enabled_tools || [],
    webAccess: (view.conversation.enabled_tools || []).includes("web"),
    messages: (view.messages || []).map((message) => ({
      id: message.id,
      role: message.role,
      content: message.body || "",
      reasoning: message.reasoning || "",
      sources: Array.isArray(message.sources) ? message.sources : [],
      tools: Array.isArray(message.tool_invocations) ? message.tool_invocations : [],
      model: message.model || view.conversation.model,
      streaming: false,
      meta: message.status === "failed" ? "Generation failed" : null,
    })),
  });
  const liveTask = [...(view.tasks || [])]
    .reverse()
    .find((task) => ["pending", "running"].includes(task.state));
  if (liveTask) {
    state.messages.push({
      id: `task-${liveTask.id}`,
      role: "assistant",
      content: liveTask.preview_text || (liveTask.state === "running"
        ? "The model is working on your Mac…"
        : "Queued for the model on your Mac…"),
      model: view.conversation.model,
      streaming: true,
      meta: liveTask.preview_text ? "Response still generating" : null,
    });
  }
  const latestTask = (view.tasks || []).at(-1);
  if (latestTask && ["failed", "cancelled"].includes(latestTask.state)
      && !latestTask.response_message_id) {
    const detail = String(latestTask.error || "No response was produced.")
      .replace(/^permanent:\s*/i, "");
    state.messages.push({
      id: `task-${latestTask.id}`,
      role: "assistant",
      content: latestTask.state === "cancelled"
        ? "This response was cancelled."
        : `The model could not complete this response. ${detail}`,
      model: view.conversation.model,
      streaming: false,
      meta: latestTask.state === "cancelled" ? "Generation cancelled" : "Generation failed",
    });
  }
  conversationSignature = JSON.stringify([
    view.conversation.modified_at_ms,
    view.conversation.message_count,
    view.conversation.pending_task_count,
    (view.tasks || []).map((task) => [
      task.id,
      task.state,
      task.response_message_id,
      task.preview_text,
      task.preview_complete,
      task.error,
    ]),
  ]);
  saveState();
  restoreSettings();
  if (elements.model.options.length) elements.model.value = state.model;
  renderMessages(scrollToEnd);
}

async function loadConversation(id, scrollToEnd = false) {
  const body = await apiRequest(`/api/conversations/${encodeURIComponent(id)}`);
  applyConversationView(body.view, scrollToEnd);
  return body.view;
}

function renderConversationList() {
  elements.conversationList.textContent = "";
  if (!sharedConversations.length) {
    const empty = document.createElement("p");
    empty.className = "conversation-empty";
    empty.textContent = "No saved conversations yet.";
    elements.conversationList.append(empty);
    return;
  }
  for (const conversation of sharedConversations) {
    const row = document.createElement("div");
    row.className = `conversation-item${conversation.id === currentConversationId ? " current" : ""}`;
    if (conversation.id === renamingConversationId) {
      renderConversationRename(row, conversation);
      elements.conversationList.append(row);
      continue;
    }
    const select = document.createElement("button");
    select.type = "button";
    select.className = "conversation-select";
    const title = document.createElement("strong");
    title.textContent = conversation.title || "New chat";
    const date = document.createElement("small");
    const updated = new Date(conversation.last_activity_at_ms || conversation.modified_at_ms);
    date.textContent = Number.isNaN(updated.valueOf()) ? "Saved" : updated.toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
    select.append(title, date);
    select.addEventListener("click", () => selectConversation(conversation.id).catch((error) => showTransientError(error.message)));
    const suggest = document.createElement("button");
    suggest.type = "button";
    suggest.className = "conversation-action";
    suggest.textContent = "✦";
    suggest.disabled = Number(conversation.message_count || 0) === 0;
    suggest.setAttribute("aria-label", `Suggest a title for ${conversation.title || "this chat"}`);
    suggest.addEventListener("click", () => suggestConversationTitle(conversation.id, suggest));
    const rename = document.createElement("button");
    rename.type = "button";
    rename.className = "conversation-action";
    rename.textContent = "✎";
    rename.setAttribute("aria-label", `Rename ${conversation.title || "this chat"}`);
    rename.addEventListener("click", () => {
      renamingConversationId = conversation.id;
      renderConversationList();
      elements.conversationList.querySelector(".conversation-title-input")?.focus();
    });
    row.append(select, suggest, rename);
    elements.conversationList.append(row);
  }
}

function renderConversationRename(row, conversation) {
  row.classList.add("editing");
  const input = document.createElement("input");
  input.className = "conversation-title-input";
  input.type = "text";
  input.maxLength = 120;
  input.value = conversation.title || "";
  input.setAttribute("aria-label", "Conversation title");
  const save = document.createElement("button");
  save.type = "button";
  save.className = "conversation-action save";
  save.textContent = "✓";
  save.setAttribute("aria-label", "Save conversation title");
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "conversation-action";
  cancel.textContent = "×";
  cancel.setAttribute("aria-label", "Cancel rename");
  const commit = async () => {
    const title = input.value.trim();
    if (!title) {
      input.focus();
      return;
    }
    save.disabled = true;
    cancel.disabled = true;
    try {
      const body = await apiRequest(`/api/conversations/${encodeURIComponent(conversation.id)}`, {
        method: "PATCH",
        body: JSON.stringify({ title }),
      });
      renamingConversationId = "";
      if (conversation.id === currentConversationId) applyConversationView(body.view, false);
      await refreshConversationList();
    } catch (error) {
      save.disabled = false;
      cancel.disabled = false;
      showTransientError(error.message);
    }
  };
  save.addEventListener("click", commit);
  cancel.addEventListener("click", () => {
    renamingConversationId = "";
    renderConversationList();
  });
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      commit();
    } else if (event.key === "Escape") {
      event.preventDefault();
      renamingConversationId = "";
      renderConversationList();
    }
  });
  row.append(input, save, cancel);
}

async function suggestConversationTitle(id, button) {
  button.disabled = true;
  const prior = button.textContent;
  button.textContent = "…";
  try {
    await apiRequest(`/api/conversations/${encodeURIComponent(id)}/title-suggestion`, {
      method: "POST",
    });
    await pollSharedState();
  } catch (error) {
    showTransientError(error.message);
  } finally {
    button.disabled = false;
    button.textContent = prior;
  }
}

async function createConversation() {
  if (controller) return;
  const body = await apiRequest("/api/conversations", {
    method: "POST",
    body: JSON.stringify({
      title: "New chat",
      model: state.model,
      system_prompt: state.system,
      temperature: state.temperature,
      max_tokens: state.maxTokens,
      thinking: state.thinking,
      web_access: state.webAccess,
      enabled_tools: state.enabledTools,
    }),
  });
  await refreshConversationList();
  await loadConversation(body.id, false);
  closeChatsPanel();
  elements.prompt.focus();
}

async function selectConversation(id) {
  if (controller || id === currentConversationId) {
    closeChatsPanel();
    return;
  }
  await loadConversation(id, true);
  closeChatsPanel();
}

function closeChatsPanel() {
  elements.chatsPanel.hidden = true;
  elements.chatsButton.setAttribute("aria-expanded", "false");
}

async function initializeSharedState() {
  await refreshConversationList();
  if (!sharedConversations.length) {
    await createConversation();
    return;
  }
  const preferred = sharedConversations.some((row) => row.id === currentConversationId)
    ? currentConversationId
    : sharedConversations[0].id;
  await loadConversation(preferred, true);
}

async function refreshConversationList() {
  acceptConversationList(await apiRequest("/api/conversations"));
}

async function pollSharedState() {
  if (polling || controller || document.hidden || !currentConversationId) return;
  polling = true;
  try {
    await refreshConversationList();
    const body = await apiRequest(`/api/conversations/${encodeURIComponent(currentConversationId)}`);
    const view = body.view;
    const nextSignature = JSON.stringify([
      view.conversation.modified_at_ms,
      view.conversation.message_count,
      view.conversation.pending_task_count,
      (view.tasks || []).map((task) => [
        task.id,
        task.state,
        task.response_message_id,
        task.preview_text,
        task.preview_complete,
        task.error,
      ]),
    ]);
    if (nextSignature !== conversationSignature) applyConversationView(view, false);
    setConnection("online", "Mac online");
  } catch (error) {
    describeConnectionError(error);
  } finally {
    polling = false;
  }
}

function apiHeaders(json = false) {
  const headers = {};
  if (json) headers["Content-Type"] = "application/json";
  if (accessToken) headers.Authorization = `Bearer ${accessToken}`;
  return headers;
}

async function updateConversationPreferences(changes) {
  if (!currentConversationId) return;
  const body = await apiRequest(`/api/conversations/${encodeURIComponent(currentConversationId)}`, {
    method: "PATCH",
    body: JSON.stringify(changes),
  });
  applyConversationView(body.view, false);
  await refreshConversationList();
}

function setConnection(kind, text) {
  elements.connection.className = `connection ${kind}`;
  elements.connection.querySelector("span").textContent = text;
}

function compactModelName(id) {
  return id
    .replace(/^mlx-community--/, "")
    .replace(/-qat-4bit$/i, "")
    .replace(/-4bit$/i, "");
}

function appendTextWithBreaks(parent, text) {
  const lines = text.split("\n");
  lines.forEach((line, index) => {
    if (index) parent.append(document.createElement("br"));
    parent.append(document.createTextNode(line));
  });
}

function renderInline(parent, text) {
  const pattern = /(\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\]|\$\$[\s\S]*?\$\$|\$(?:\\.|[^$\n])+\$|`[^`\n]+`|\*\*[^*\n]+\*\*|\*[^*\n]+\*|\[[^\]\n]+\]\([^)\n]+\))/g;
  let cursor = 0;
  for (const match of text.matchAll(pattern)) {
    appendTextWithBreaks(parent, text.slice(cursor, match.index));
    const token = match[0];
    if (token.startsWith("$") || token.startsWith("\\(") || token.startsWith("\\[")) {
      parent.append(document.createTextNode(token));
    } else if (token.startsWith("`")) {
      const code = document.createElement("code");
      code.textContent = token.slice(1, -1);
      parent.append(code);
    } else if (token.startsWith("**")) {
      const strong = document.createElement("strong");
      renderInline(strong, token.slice(2, -2));
      parent.append(strong);
    } else if (token.startsWith("*")) {
      const emphasis = document.createElement("em");
      renderInline(emphasis, token.slice(1, -1));
      parent.append(emphasis);
    } else {
      const link = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      const href = link?.[2]?.trim().replace(/^<|>$/g, "");
      if (link && /^(https?:|mailto:)/i.test(href)) {
        const anchor = document.createElement("a");
        anchor.textContent = link[1];
        anchor.href = href;
        anchor.target = "_blank";
        anchor.rel = "noopener noreferrer nofollow";
        parent.append(anchor);
      } else {
        appendTextWithBreaks(parent, token);
      }
    }
    cursor = match.index + token.length;
  }
  appendTextWithBreaks(parent, text.slice(cursor));
}

function splitTableRow(line) {
  return line.trim().replace(/^\||\|$/g, "").split("|").map((cell) => cell.trim());
}

function isTableSeparator(line) {
  const cells = splitTableRow(line);
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function startsMarkdownBlock(lines, index) {
  const line = lines[index] || "";
  return /^\s*$/.test(line)
    || /^\s*```/.test(line)
    || /^#{1,6}\s+/.test(line)
    || /^\s*>\s?/.test(line)
    || /^\s*([-+*]|\d+[.)])\s+/.test(line)
    || /^\s*((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$/.test(line)
    || (line.includes("|") && isTableSeparator(lines[index + 1] || ""));
}

function renderMarkdownInto(container, markdown) {
  container.textContent = "";
  const lines = String(markdown || "").replace(/\r\n?/g, "\n").split("\n");
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) {
      index += 1;
      continue;
    }

    const fence = line.match(/^\s*```([^\s`]*)\s*$/);
    if (fence) {
      index += 1;
      const codeLines = [];
      while (index < lines.length && !/^\s*```\s*$/.test(lines[index])) {
        codeLines.push(lines[index]);
        index += 1;
      }
      if (index < lines.length) index += 1;
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      if (fence[1]) code.dataset.language = fence[1];
      code.textContent = codeLines.join("\n");
      pre.append(code);
      container.append(pre);
      continue;
    }

    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      const element = document.createElement(`h${heading[1].length}`);
      renderInline(element, heading[2]);
      container.append(element);
      index += 1;
      continue;
    }

    if (/^\s*((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$/.test(line)) {
      container.append(document.createElement("hr"));
      index += 1;
      continue;
    }

    if (line.includes("|") && isTableSeparator(lines[index + 1] || "")) {
      const tableWrap = document.createElement("div");
      tableWrap.className = "table-scroll";
      const table = document.createElement("table");
      const head = document.createElement("thead");
      const headRow = document.createElement("tr");
      for (const value of splitTableRow(line)) {
        const cell = document.createElement("th");
        renderInline(cell, value);
        headRow.append(cell);
      }
      head.append(headRow);
      table.append(head);
      index += 2;
      const body = document.createElement("tbody");
      while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
        const row = document.createElement("tr");
        for (const value of splitTableRow(lines[index])) {
          const cell = document.createElement("td");
          renderInline(cell, value);
          row.append(cell);
        }
        body.append(row);
        index += 1;
      }
      table.append(body);
      tableWrap.append(table);
      container.append(tableWrap);
      continue;
    }

    if (/^\s*>\s?/.test(line)) {
      const quoteLines = [];
      while (index < lines.length && /^\s*>\s?/.test(lines[index])) {
        quoteLines.push(lines[index].replace(/^\s*>\s?/, ""));
        index += 1;
      }
      const quote = document.createElement("blockquote");
      renderMarkdownInto(quote, quoteLines.join("\n"));
      container.append(quote);
      continue;
    }

    const listMatch = line.match(/^\s*([-+*]|\d+[.)])\s+(.+)$/);
    if (listMatch) {
      const ordered = /^\d/.test(listMatch[1]);
      const list = document.createElement(ordered ? "ol" : "ul");
      while (index < lines.length) {
        const itemMatch = lines[index].match(/^\s*([-+*]|\d+[.)])\s+(.+)$/);
        if (!itemMatch || /^\d/.test(itemMatch[1]) !== ordered) break;
        const item = document.createElement("li");
        const task = itemMatch[2].match(/^\[([ xX])\]\s+(.+)$/);
        if (task) {
          const checkbox = document.createElement("input");
          checkbox.type = "checkbox";
          checkbox.checked = task[1].toLowerCase() === "x";
          checkbox.disabled = true;
          item.append(checkbox);
          renderInline(item, task[2]);
        } else {
          renderInline(item, itemMatch[2]);
        }
        list.append(item);
        index += 1;
      }
      container.append(list);
      continue;
    }

    const paragraphLines = [line];
    index += 1;
    while (index < lines.length && !startsMarkdownBlock(lines, index)) {
      paragraphLines.push(lines[index]);
      index += 1;
    }
    const paragraph = document.createElement("p");
    renderInline(paragraph, paragraphLines.join("\n"));
    container.append(paragraph);
  }
}

function renderAssistantContent(container, markdown) {
  if (window.MathJax?.typesetClear) window.MathJax.typesetClear([container]);
  renderMarkdownInto(container, markdown);
  if (!window.MathJax?.startup?.promise || !window.MathJax?.typesetPromise) return;
  mathTypesetChain = mathTypesetChain
    .catch(() => undefined)
    .then(async () => {
      await window.MathJax.startup.promise;
      if (container.isConnected) await window.MathJax.typesetPromise([container]);
    })
    .catch((error) => console.warn("Equation rendering failed", error));
}

async function loadModels() {
  const body = await apiRequest("/api/models");
  elements.model.textContent = "";
  for (const model of body.models) {
    const option = document.createElement("option");
    option.value = model.id;
    option.textContent = compactModelName(model.id) + (model.loaded ? " · ready" : "");
    elements.model.append(option);
  }
  const ids = body.models.map((model) => model.id);
  const selected = ids.includes(state.model) ? state.model : (ids[0] || "");
  elements.model.value = selected;
  if (state.model !== selected) {
    state.model = selected;
    saveState();
  }
  setConnection("online", "Mac online");
}

function restoreSettings() {
  elements.system.value = state.system;
  elements.temperature.value = String(state.temperature);
  elements.temperatureValue.value = Number(state.temperature).toFixed(1);
  elements.maxTokens.value = String(state.maxTokens);
  elements.thinking.checked = Boolean(state.thinking);
  elements.webAccess.checked = state.webAccess !== false;
}

function messageElement(message, streaming = false) {
  const article = document.createElement("article");
  article.className = `message ${message.role}`;
  const label = document.createElement("div");
  label.className = "message-label";
  label.textContent = message.role === "user" ? "You" : compactModelName(message.model || state.model || "Local model");
  article.append(label);

  if (Array.isArray(message.sources) && message.sources.length) {
    const sourceGroup = document.createElement("div");
    sourceGroup.className = "message-source-group";
    const sourceLabel = document.createElement("div");
    sourceLabel.className = "facet-label";
    sourceLabel.textContent = "Sources";
    const sources = document.createElement("div");
    sources.className = "message-sources";
    for (const source of message.sources) {
      const anchor = document.createElement("a");
      anchor.href = source.url;
      anchor.target = "_blank";
      anchor.rel = "noopener noreferrer";
      anchor.textContent = source.title || new URL(source.url).hostname;
      sources.append(anchor);
    }
    sourceGroup.append(sourceLabel, sources);
    article.append(sourceGroup);
  }

  if (Array.isArray(message.tools) && message.tools.length) {
    const tools = document.createElement("details");
    tools.className = "message-tools";
    const summary = document.createElement("summary");
    summary.textContent = `Tools used · ${message.tools.length}`;
    const list = document.createElement("div");
    list.className = "tool-list";
    for (const tool of message.tools) {
      const row = document.createElement("div");
      row.className = "tool-row";
      const heading = document.createElement("div");
      const name = document.createElement("strong");
      name.textContent = tool.tool;
      const state = document.createElement("small");
      state.textContent = [tool.provider, tool.state].filter(Boolean).join(" · ");
      heading.append(name, state);
      row.append(heading);
      const detail = tool.error || tool.result_summary;
      if (detail) {
        const text = document.createElement("p");
        text.textContent = detail;
        row.append(text);
      }
      list.append(row);
    }
    tools.append(summary, list);
    article.append(tools);
  }

  if (message.reasoning) {
    const reasoning = document.createElement("details");
    const summary = document.createElement("summary");
    summary.textContent = "Thinking";
    const content = document.createElement("div");
    content.className = "reasoning markdown-body";
    renderAssistantContent(content, message.reasoning);
    reasoning.append(summary, content);
    article.append(reasoning);
  }

  const content = document.createElement("div");
  content.className = "message-content" + (message.role === "assistant" ? " markdown-body" : "") + (streaming ? " cursor" : "");
  if (message.role === "assistant") renderAssistantContent(content, message.content);
  else content.textContent = message.content;
  article.append(content);
  if (message.meta) {
    const meta = document.createElement("div");
    meta.className = "message-meta";
    meta.textContent = message.meta;
    article.append(meta);
  }
  return article;
}

function renderMessages(scrollToEnd = true) {
  elements.messages.textContent = "";
  elements.welcome.hidden = state.messages.length > 0;
  for (const message of state.messages) elements.messages.append(messageElement(message, Boolean(message.streaming)));
  if (scrollToEnd) requestAnimationFrame(scrollToBottom);
}

function scrollToBottom() {
  elements.conversation.scrollTop = elements.conversation.scrollHeight;
}

function revealMessageStart(node) {
  const conversationBox = elements.conversation.getBoundingClientRect();
  const messageBox = node.getBoundingClientRect();
  elements.conversation.scrollTo({
    top: Math.max(0, elements.conversation.scrollTop + messageBox.top - conversationBox.top - 12),
    behavior: "auto",
  });
}

function autosize() {
  elements.prompt.style.height = "auto";
  elements.prompt.style.height = Math.min(elements.prompt.scrollHeight, 140) + "px";
}

function setGenerating(active) {
  elements.send.hidden = active;
  elements.stop.hidden = !active;
  elements.model.disabled = active;
  elements.newChat.disabled = active;
  elements.chatsButton.disabled = active;
}

function showTransientError(text) {
  if (!text) return;
  const message = { role: "assistant", content: text, model: "LocalModels" };
  elements.welcome.hidden = true;
  elements.messages.append(messageElement(message));
  scrollToBottom();
}

async function sendMessage(text) {
  const prompt = text.trim();
  if (!prompt || controller || !state.model || !currentConversationId) return;

  state.messages.push({ role: "user", content: prompt });
  const assistant = {
    role: "assistant",
    content: "Queued for the model on your Mac…",
    reasoning: "",
    sources: [],
    model: state.model,
    streaming: true,
  };
  state.messages.push(assistant);
  elements.welcome.hidden = true;
  elements.messages.append(messageElement(state.messages.at(-2)));
  const assistantNode = messageElement(assistant, true);
  elements.messages.append(assistantNode);
  const contentNode = assistantNode.querySelector(".message-content");
  setGenerating(true);
  elements.prompt.blur();
  setTimeout(() => {
    syncViewportHeight();
    revealMessageStart(assistantNode);
  }, 100);

  controller = new AbortController();
  try {
    const queued = await apiRequest(
      `/api/conversations/${encodeURIComponent(currentConversationId)}/messages`,
      {
        method: "POST",
        signal: controller.signal,
        body: JSON.stringify({ body: prompt, attachment_ids: [] }),
      },
    );
    await refreshConversationList();
    const response = await fetch(queued.events, {
      method: "GET",
      headers: apiHeaders(),
      signal: controller.signal,
    });
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      throw new Error(body.error || `Task stream failed with HTTP ${response.status}`);
    }
    if (!response.body) throw new Error("This browser did not provide a response stream.");

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    while (true) {
      const { value, done } = await reader.read();
      buffer += decoder.decode(value || new Uint8Array(), { stream: !done });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";
      for (const line of lines) {
        if (!line.trim()) continue;
        const event = JSON.parse(line);
        if (event.type === "progress") {
          const taskState = event.task?.state || "pending";
          const preview = event.task?.preview_text;
          assistant.content = preview || (taskState === "running"
            ? "The model is working on your Mac…"
            : "Queued for the model on your Mac…");
          assistant.meta = preview ? "Response still generating" : null;
          renderAssistantContent(contentNode, assistant.content);
          if (["done", "failed", "cancelled"].includes(taskState)
              || event.task?.response_message_id) {
            break;
          }
        } else if (event.type === "error") {
          throw new Error(event.message || "Task stream failed");
        } else if (event.type === "timeout") {
          throw new Error("The model task is still pending; it will continue on the Mac.");
        }
      }
      if (done) break;
    }
    await loadConversation(currentConversationId, true);
    setConnection("online", "Mac online");
  } catch (error) {
    if (error.name === "AbortError") {
      assistant.content = "This task is continuing durably on your Mac.";
      assistant.meta = "Detached from live updates";
    } else {
      assistant.content = `I couldn't follow the task live. ${error.message}`;
      assistant.meta = "Connection error";
      setConnection("offline", "Check connection");
    }
    assistant.streaming = false;
    assistantNode.replaceWith(messageElement(assistant));
  } finally {
    controller = null;
    contentNode.classList.remove("cursor");
    setGenerating(false);
  }
}

elements.composer.addEventListener("submit", (event) => {
  event.preventDefault();
  const text = elements.prompt.value;
  elements.prompt.value = "";
  autosize();
  sendMessage(text);
});

elements.prompt.addEventListener("input", autosize);
elements.prompt.addEventListener("focus", () => {
  setTimeout(() => {
    syncViewportHeight();
    scrollToBottom();
  }, 80);
});
elements.prompt.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing && window.innerWidth >= 700) {
    event.preventDefault();
    elements.composer.requestSubmit();
  }
});

elements.stop.addEventListener("click", () => controller?.abort());
elements.newChat.addEventListener("click", () => createConversation().catch((error) => showTransientError(error.message)));

elements.chatsButton.addEventListener("click", () => {
  const open = elements.chatsPanel.hidden;
  elements.chatsPanel.hidden = !open;
  elements.chatsButton.setAttribute("aria-expanded", String(open));
  if (open) {
    elements.settingsPanel.hidden = true;
    elements.settingsButton.setAttribute("aria-expanded", "false");
    renderConversationList();
  }
});
elements.closeChats.addEventListener("click", closeChatsPanel);

elements.settingsButton.addEventListener("click", () => {
  const open = elements.settingsPanel.hidden;
  elements.settingsPanel.hidden = !open;
  elements.settingsButton.setAttribute("aria-expanded", String(open));
  if (open) closeChatsPanel();
});

elements.model.addEventListener("change", async () => {
  state.model = elements.model.value;
  saveState();
  try {
    await updateConversationPreferences({ model: state.model });
  } catch (error) {
    showTransientError(error.message);
    await loadConversation(currentConversationId, false).catch(() => {});
  }
});
elements.system.addEventListener("change", () => { state.system = elements.system.value; saveState(); });
elements.temperature.addEventListener("input", () => {
  state.temperature = Number(elements.temperature.value);
  elements.temperatureValue.value = state.temperature.toFixed(1);
  saveState();
});
elements.maxTokens.addEventListener("change", () => {
  state.maxTokens = Math.max(64, Math.min(32768, Number(elements.maxTokens.value) || 2048));
  elements.maxTokens.value = String(state.maxTokens);
  saveState();
});
elements.thinking.addEventListener("change", () => { state.thinking = elements.thinking.checked; saveState(); });
elements.webAccess.addEventListener("change", async () => {
  state.webAccess = elements.webAccess.checked;
  state.enabledTools = state.enabledTools.filter((tool) => tool !== "web");
  if (state.webAccess) state.enabledTools.push("web");
  saveState();
  try {
    await updateConversationPreferences({ enabled_tools: state.enabledTools });
  } catch (error) {
    showTransientError(error.message);
    await loadConversation(currentConversationId, false).catch(() => {});
  }
});

document.querySelectorAll("[data-prompt]").forEach((button) => {
  button.addEventListener("click", () => sendMessage(button.dataset.prompt));
});

async function initialize() {
  autosize();
  syncViewportHeight();
  try {
    await redeemPairingTicket();
    await loadModels();
    await initializeSharedState();
    setConnection("online", "Mac online");
  } catch (error) {
    restoreSettings();
    renderMessages(true);
    showTransientError(describeConnectionError(error));
  }
  setInterval(pollSharedState, 1400);
}

initialize();
window.addEventListener("resize", syncViewportHeight, { passive: true });
window.addEventListener("orientationchange", syncViewportHeight, { passive: true });
window.visualViewport?.addEventListener("resize", syncViewportHeight, { passive: true });
window.visualViewport?.addEventListener("scroll", syncViewportHeight, { passive: true });
