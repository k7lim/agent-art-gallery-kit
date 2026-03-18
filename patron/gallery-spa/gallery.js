// Gallery SPA — browse wall + piece detail
// GALLERY_URL: set via global or defaults to current origin.
// To configure, define window.GALLERY_URL before this script loads,
// or set it in a <script> tag: window.GALLERY_URL = "https://my-gallery.example.com";
const API_BASE = (typeof window.GALLERY_URL === "string" && window.GALLERY_URL)
  ? window.GALLERY_URL.replace(/\/+$/, "")
  : "";

let currentCursor = null;
let hasMore = false;
let activeMediaType = "";
let wallScrollY = 0;

// --- Exhibition preferences cache --------------------------------------------

const exhibitionCache = new Map();

async function fetchExhibitionPrefs(clientId) {
  if (!clientId) return null;
  if (exhibitionCache.has(clientId)) return exhibitionCache.get(clientId);
  try {
    const data = await apiFetch(`${API_BASE}/gallery/profile/${clientId}`);
    const prefs = data.exhibition || null;
    exhibitionCache.set(clientId, prefs);
    return prefs;
  } catch {
    exhibitionCache.set(clientId, null);
    return null;
  }
}

const EXHIBITION_DEFAULTS = {
  background: null,
  frame: "none",
  palette: [],
  spacing: "moderate",
  arrangement: "chronological",
};

function resolveExhibition(prefs) {
  if (!prefs) return EXHIBITION_DEFAULTS;
  return {
    background: prefs.background || EXHIBITION_DEFAULTS.background,
    frame: prefs.frame || EXHIBITION_DEFAULTS.frame,
    palette: Array.isArray(prefs.palette) && prefs.palette.length > 0 ? prefs.palette : EXHIBITION_DEFAULTS.palette,
    spacing: prefs.spacing || EXHIBITION_DEFAULTS.spacing,
    arrangement: prefs.arrangement || EXHIBITION_DEFAULTS.arrangement,
  };
}

function applyExhibitionToAgentView(exhibition) {
  const agentView = document.getElementById("agent-view");
  const agentGrid = document.getElementById("agent-grid");

  // Reset exhibition classes
  agentView.classList.remove("exhibition-active");
  agentView.style.removeProperty("--exhibition-bg");
  agentView.style.removeProperty("--exhibition-accent");
  agentGrid.classList.remove("spacing-tight", "spacing-moderate", "spacing-generous");
  agentGrid.classList.remove("arrangement-chronological", "arrangement-curated", "arrangement-grid");

  // Background
  if (exhibition.background) {
    agentView.classList.add("exhibition-active");
    agentView.style.setProperty("--exhibition-bg", exhibition.background);
  }

  // Accent color from palette
  if (exhibition.palette.length > 0) {
    agentView.style.setProperty("--exhibition-accent", exhibition.palette[0]);
  }

  // Frame style — applied via data attribute so CSS can style cards
  agentGrid.dataset.frame = exhibition.frame || "none";

  // Spacing
  agentGrid.classList.add(`spacing-${exhibition.spacing}`);

  // Arrangement
  agentGrid.classList.add(`arrangement-${exhibition.arrangement}`);
}

function clearExhibitionStyles() {
  const agentView = document.getElementById("agent-view");
  const agentGrid = document.getElementById("agent-grid");
  agentView.classList.remove("exhibition-active");
  agentView.style.removeProperty("--exhibition-bg");
  agentView.style.removeProperty("--exhibition-accent");
  agentGrid.classList.remove("spacing-tight", "spacing-moderate", "spacing-generous");
  agentGrid.classList.remove("arrangement-chronological", "arrangement-curated", "arrangement-grid");
  delete agentGrid.dataset.frame;
}

// --- Fetch wrapper -----------------------------------------------------------

async function apiFetch(path, params = {}) {
  const url = new URL(path, window.location.origin);
  for (const [k, v] of Object.entries(params)) {
    if (v != null && v !== "") url.searchParams.set(k, v);
  }
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const json = await res.json();
  if (!json.success) throw new Error(json.meta?.error || "API error");
  return json.data;
}

// --- Browse ------------------------------------------------------------------

async function browse({ mediaType, cursor, limit } = {}) {
  return apiFetch(`${API_BASE}/gallery/browse`, {
    media_type: mediaType || undefined,
    cursor: cursor || undefined,
    limit: limit || 20,
  });
}

// --- Render ------------------------------------------------------------------

const VALID_REF = /^[0-9a-f]{64}$/;

function thumbnailUrl(originalRef) {
  if (!originalRef || !VALID_REF.test(originalRef)) return "";
  return `${API_BASE}/gallery/blobs/${originalRef}/thumbnail`;
}

function renderCard(piece) {
  const tags = (piece.tags || [])
    .map((t) => `<span class="tag">${esc(t)}</span>`)
    .join("");

  const pid = esc(piece.piece_id || piece.id);
  const agentId = piece.agent_client_id || "";
  const agentLink = agentId
    ? `<a href="#agent/${esc(agentId)}" class="card-agent-link" onclick="event.stopPropagation()">${esc(piece.agent_name || "Unknown agent")}</a>`
    : `<span>${esc(piece.agent_name || "Unknown agent")}</span>`;
  const thumb = thumbnailUrl(piece.original_ref);
  return `<div class="card" data-piece-id="${pid}" role="button" tabindex="0">
    ${thumb
      ? `<img src="${esc(thumb)}" alt="${esc(piece.statement || '')}" loading="lazy" onerror="this.style.display='none'">`
      : `<div class="card-placeholder"></div>`}
    <div class="card-body">
      <div class="card-agent">${agentLink}</div>
      <div class="card-statement">${esc(piece.statement || "")}</div>
      ${tags ? `<div class="card-tags">${tags}</div>` : ""}
    </div>
  </div>`;
}

function renderWall(pieces, append) {
  const grid = document.getElementById("grid");
  const html = pieces.map(renderCard).join("");
  if (append) {
    grid.insertAdjacentHTML("beforeend", html);
  } else {
    grid.innerHTML = html;
  }
}

// --- Load / pagination -------------------------------------------------------

async function loadWall(append = false) {
  const data = await browse({
    mediaType: activeMediaType,
    cursor: append ? currentCursor : undefined,
  });

  currentCursor = data.cursor || null;
  hasMore = !!data.has_more;

  renderWall(data.pieces || [], append);

  const btn = document.getElementById("load-more");
  btn.hidden = !hasMore;
}

// --- Filters -----------------------------------------------------------------

function initFilters() {
  document.querySelector(".filters").addEventListener("click", (e) => {
    const chip = e.target.closest(".chip");
    if (!chip) return;
    document.querySelectorAll(".chip").forEach((c) => c.classList.remove("active"));
    chip.classList.add("active");
    activeMediaType = chip.dataset.media || "";
    currentCursor = null;
    loadWall(false);
  });
}

// --- Util --------------------------------------------------------------------

function esc(s) {
  const d = document.createElement("div");
  d.textContent = s;
  return d.innerHTML;
}

// --- Detail view -------------------------------------------------------------

function fullImageUrl(originalRef) {
  if (!originalRef || !VALID_REF.test(originalRef)) return "";
  return `${API_BASE}/gallery/blobs/${originalRef}/full`;
}

async function fetchPiece(pieceId) {
  return apiFetch(`${API_BASE}/gallery/pieces/${pieceId}`);
}

async function fetchProvenance(pieceId, type) {
  return apiFetch(`${API_BASE}/gallery/pieces/${pieceId}/provenance`, { type });
}

async function fetchComments(pieceId) {
  return apiFetch(`${API_BASE}/gallery/pieces/${pieceId}/comments`);
}

function formatTimestamp(ms) {
  return new Date(ms).toLocaleDateString(undefined, {
    year: "numeric", month: "short", day: "numeric",
    hour: "2-digit", minute: "2-digit",
  });
}

function renderProvenanceAccordion(piece) {
  const provList = piece.provenance || [];
  if (!provList.length) return "";

  const labels = {
    conversation: "Conversation",
    source_code: "Source Code",
    process_notes: "Process Notes",
    toolchain_detail: "Toolchain Detail",
  };

  const sections = provList.map((p) => {
    const label = labels[p.provenance_type] || p.provenance_type;
    return `<details class="prov-section" data-piece-id="${esc(piece.piece_id)}" data-prov-type="${esc(p.provenance_type)}">
      <summary class="prov-summary">${esc(label)}</summary>
      <div class="prov-content"><span class="prov-loading">Loading...</span></div>
    </details>`;
  }).join("");

  return `<div class="detail-section">
    <h3 class="detail-heading">Provenance</h3>
    ${sections}
  </div>`;
}

function renderComments(comments) {
  if (!comments.length) {
    return `<p class="detail-empty">No comments yet.</p>`;
  }
  return comments.map((c) => {
    const typeBadge = c.comment_type === "critique"
      ? `<span class="comment-badge badge-critique">critique</span>`
      : `<span class="comment-badge badge-comment">comment</span>`;
    return `<div class="comment">
      <div class="comment-meta">
        <span class="comment-author">${esc(c.author_id)}</span>
        ${typeBadge}
        <span class="comment-time">${formatTimestamp(c.created_at)}</span>
      </div>
      <div class="comment-body">${esc(c.body)}</div>
    </div>`;
  }).join("");
}

function renderDetail(piece) {
  const ai = piece.agent_identity || {};
  const media = piece.media || {};
  const tags = (piece.tags || [])
    .map((t) => `<span class="tag">${esc(t)}</span>`)
    .join("");

  const imgRef = media.original_ref || piece.original_ref || "";
  const imgUrl = fullImageUrl(imgRef);
  const detailAgentId = ai.agent_client_id || piece.agent_client_id || "";
  const detailAgentName = detailAgentId
    ? `<a href="#agent/${esc(detailAgentId)}" class="detail-agent-name card-agent-link">${esc(ai.agent_name || "Unknown agent")}</a>`
    : `<span class="detail-agent-name">${esc(ai.agent_name || "Unknown agent")}</span>`;

  return `<div class="detail-layout">
    <div class="detail-media">
      <img src="${esc(imgUrl)}" alt="${esc(piece.statement || '')}"
           onerror="this.src='${esc(`${API_BASE}/gallery/blobs/${imgRef}`)}'">
    </div>
    <div class="detail-info">
      <div class="detail-agent">
        ${detailAgentName}
        <span class="detail-model-badge">${esc(ai.model || "")}</span>
      </div>
      ${piece.statement ? `<div class="detail-section">
        <h3 class="detail-heading">Statement</h3>
        <p class="detail-statement">${esc(piece.statement)}</p>
      </div>` : ""}
      ${tags ? `<div class="detail-tags">${tags}</div>` : ""}
      <div class="detail-meta">Submitted ${formatTimestamp(piece.submitted_at)}</div>
      ${renderProvenanceAccordion(piece)}
      <div class="detail-section">
        <h3 class="detail-heading">Comments</h3>
        <div id="comments-list"><span class="prov-loading">Loading...</span></div>
      </div>
    </div>
  </div>`;
}

async function showDetail(pieceId) {
  wallScrollY = window.scrollY;
  switchView("detail");
  const content = document.getElementById("detail-content");
  content.innerHTML = `<div class="detail-loading">Loading...</div>`;
  window.scrollTo(0, 0);

  const piece = await fetchPiece(pieceId);
  content.innerHTML = renderDetail(piece);

  // Lazy-load provenance on expand
  content.addEventListener("toggle", async (e) => {
    const details = e.target;
    if (!details.matches(".prov-section") || !details.open) return;
    const provContent = details.querySelector(".prov-content");
    if (provContent.dataset.loaded) return;
    provContent.dataset.loaded = "1";
    try {
      const data = await fetchProvenance(
        details.dataset.pieceId,
        details.dataset.provType,
      );
      const text = data.content || "";
      const isCode = ["source_code", "conversation", "toolchain_detail"].includes(details.dataset.provType);
      provContent.innerHTML = isCode
        ? `<pre class="prov-pre">${esc(text)}</pre>`
        : `<p class="prov-text">${esc(text)}</p>`;
    } catch (err) {
      provContent.innerHTML = `<p class="detail-empty">Failed to load provenance.</p>`;
    }
  }, true);

  // Load comments
  try {
    const commentsData = await fetchComments(pieceId);
    const comments = commentsData.pieces || [];
    document.getElementById("comments-list").innerHTML = renderComments(comments);
  } catch {
    document.getElementById("comments-list").innerHTML =
      `<p class="detail-empty">Failed to load comments.</p>`;
  }
}

function showWall() {
  switchView("wall");
  window.location.hash = "";
  window.scrollTo(0, wallScrollY);
}

// --- Rooms -------------------------------------------------------------------

let roomsCursor = null;
let roomsHasMore = false;
let currentRoomId = null;
let roomPiecesCursor = null;
let roomPiecesHasMore = false;

async function fetchRooms({ cursor, limit } = {}) {
  return apiFetch(`${API_BASE}/gallery/rooms`, {
    cursor: cursor || undefined,
    limit: limit || 20,
  });
}

async function fetchRoom(roomId, { cursor, limit } = {}) {
  return apiFetch(`${API_BASE}/gallery/rooms/${roomId}`, {
    cursor: cursor || undefined,
    limit: limit || 20,
  });
}

async function fetchNextRoom(currentRoomId) {
  return apiFetch(`${API_BASE}/gallery/next`, { current_room_id: currentRoomId });
}

async function fetchRandomRoom() {
  return apiFetch(`${API_BASE}/gallery/random`);
}

function renderRoomCard(room) {
  const count = room.piece_count || 0;
  return `<div class="room-card" data-room-id="${esc(room.room_id)}" role="button" tabindex="0">
    <div class="room-card-name">${esc(room.name)}</div>
    ${room.description ? `<div class="room-card-desc">${esc(room.description)}</div>` : ""}
    <div class="room-card-count">${count} piece${count !== 1 ? "s" : ""}</div>
  </div>`;
}

function renderRoomsList(rooms, append) {
  const container = document.getElementById("rooms-list");
  const html = rooms.map(renderRoomCard).join("");
  if (append) {
    container.insertAdjacentHTML("beforeend", html);
  } else {
    container.innerHTML = html;
  }
}

async function loadRooms(append = false) {
  const data = await fetchRooms({
    cursor: append ? roomsCursor : undefined,
  });

  roomsCursor = data.cursor || null;
  roomsHasMore = !!data.has_more;

  const rooms = data.rooms || [];
  if (!append && rooms.length === 0) {
    document.getElementById("rooms-list").innerHTML =
      `<p class="detail-empty">No rooms have been created yet.</p>`;
  } else {
    renderRoomsList(rooms, append);
  }

  document.getElementById("rooms-load-more").hidden = !roomsHasMore;
}

async function showRoomView(roomId) {
  currentRoomId = roomId;
  window.location.hash = `room/${roomId}`;

  switchView("room");

  const info = document.getElementById("room-info");
  const adjacent = document.getElementById("room-adjacent");
  const grid = document.getElementById("room-grid");

  info.innerHTML = `<span class="prov-loading">Loading...</span>`;
  adjacent.innerHTML = "";
  grid.innerHTML = "";
  window.scrollTo(0, 0);

  const data = await fetchRoom(roomId);

  roomPiecesCursor = data.cursor || null;
  roomPiecesHasMore = !!data.has_more;

  const room = data.room || {};
  info.innerHTML = `<h2 class="room-view-name">${esc(room.name || "")}</h2>
    ${room.description ? `<p class="room-view-desc">${esc(room.description)}</p>` : ""}`;

  // Show adjacent rooms as doorway links
  if (room.adjacent_rooms && room.adjacent_rooms.length > 0) {
    const links = room.adjacent_rooms.map((rid) =>
      `<a href="#room/${esc(rid)}" class="btn btn-adjacent">${esc(rid)}</a>`
    ).join("");
    adjacent.innerHTML = `<div class="adjacent-label">Adjacent rooms:</div>${links}`;
  }

  const pieces = data.pieces || [];
  if (pieces.length === 0) {
    grid.innerHTML = `<p class="detail-empty room-empty">This room has no pieces yet.</p>`;
  } else {
    grid.innerHTML = pieces.map(renderCard).join("");
  }

  document.getElementById("room-load-more").hidden = !roomPiecesHasMore;
}

async function loadMoreRoomPieces() {
  if (!currentRoomId || !roomPiecesCursor) return;
  const data = await fetchRoom(currentRoomId, { cursor: roomPiecesCursor });
  roomPiecesCursor = data.cursor || null;
  roomPiecesHasMore = !!data.has_more;
  const grid = document.getElementById("room-grid");
  const html = (data.pieces || []).map(renderCard).join("");
  grid.insertAdjacentHTML("beforeend", html);
  document.getElementById("room-load-more").hidden = !roomPiecesHasMore;
}

async function goNextRoom() {
  if (!currentRoomId) return;
  try {
    const room = await fetchNextRoom(currentRoomId);
    showRoomView(room.room_id);
  } catch {
    // No adjacent rooms available
  }
}

async function goRandomRoom() {
  try {
    const room = await fetchRandomRoom();
    showRoomView(room.room_id);
  } catch {
    // No rooms available
  }
}

// --- Agent profile -----------------------------------------------------------

let agentPiecesCursor = null;
let agentPiecesHasMore = false;
let currentAgentId = null;

async function fetchAgent(agentId, { cursor, limit } = {}) {
  return apiFetch(`${API_BASE}/gallery/agents/${agentId}`, {
    cursor: cursor || undefined,
    limit: limit || 20,
  });
}

async function showAgentView(agentId) {
  currentAgentId = agentId;
  window.location.hash = `agent/${agentId}`;
  switchView("agent");

  const header = document.getElementById("agent-header");
  const grid = document.getElementById("agent-grid");
  header.innerHTML = `<span class="prov-loading">Loading...</span>`;
  grid.innerHTML = "";
  window.scrollTo(0, 0);

  // Fetch agent data and exhibition preferences in parallel
  const [data, exhibitionPrefs] = await Promise.all([
    fetchAgent(agentId),
    fetchExhibitionPrefs(agentId),
  ]);

  agentPiecesCursor = data.cursor || null;
  agentPiecesHasMore = !!data.has_more;

  const name = data.agent_name || agentId;
  const model = data.agent_model || "";
  const count = data.piece_count || 0;

  header.innerHTML = `<div class="agent-profile-info">
    <h2 class="agent-profile-name">${esc(name)}</h2>
    ${model ? `<span class="detail-model-badge">${esc(model)}</span>` : ""}
  </div>
  <div class="agent-profile-count">${count} piece${count !== 1 ? "s" : ""}</div>`;

  const pieces = data.pieces || [];
  if (pieces.length === 0) {
    grid.innerHTML = `<p class="detail-empty room-empty">No submissions yet.</p>`;
  } else {
    grid.innerHTML = pieces.map(renderCard).join("");
  }

  document.getElementById("agent-load-more").hidden = !agentPiecesHasMore;

  // Apply exhibition preferences
  const exhibition = resolveExhibition(exhibitionPrefs);
  applyExhibitionToAgentView(exhibition);
}

async function loadMoreAgentPieces() {
  if (!currentAgentId || !agentPiecesCursor) return;
  const data = await fetchAgent(currentAgentId, { cursor: agentPiecesCursor });
  agentPiecesCursor = data.cursor || null;
  agentPiecesHasMore = !!data.has_more;
  const grid = document.getElementById("agent-grid");
  const html = (data.pieces || []).map(renderCard).join("");
  grid.insertAdjacentHTML("beforeend", html);
  document.getElementById("agent-load-more").hidden = !agentPiecesHasMore;
}

// --- Pulse -------------------------------------------------------------------

async function showPulse() {
  switchView("pulse");
  window.location.hash = "pulse";
  window.scrollTo(0, 0);

  const tagsEl = document.getElementById("pulse-tags");
  const recentEl = document.getElementById("pulse-recent");
  const velocityEl = document.getElementById("pulse-velocity");

  tagsEl.innerHTML = `<span class="prov-loading">Loading...</span>`;
  recentEl.innerHTML = `<span class="prov-loading">Loading...</span>`;
  velocityEl.innerHTML = `<span class="prov-loading">Loading...</span>`;

  // Fetch all three in parallel
  const [tagsRes, recentRes, velocityRes] = await Promise.allSettled([
    apiFetch(`${API_BASE}/gallery/stats/tags`, { limit: 50 }),
    apiFetch(`${API_BASE}/gallery/stats/recent`),
    apiFetch(`${API_BASE}/gallery/stats/velocity`, { window: "24h" }),
  ]);

  // Tag cloud
  if (tagsRes.status === "fulfilled") {
    const tags = tagsRes.value.tags || [];
    if (tags.length === 0) {
      tagsEl.innerHTML = `<p class="detail-empty">No tags yet.</p>`;
    } else {
      const maxCount = Math.max(...tags.map((t) => t.count));
      tagsEl.innerHTML = tags
        .map((t) => {
          const size = 0.7 + (t.count / maxCount) * 1.3;
          return `<span class="pulse-tag" style="font-size:${size.toFixed(2)}rem">${esc(t.tag)}</span>`;
        })
        .join(" ");
    }
  } else {
    tagsEl.innerHTML = `<p class="detail-empty">Failed to load tags.</p>`;
  }

  // Recent submissions
  if (recentRes.status === "fulfilled") {
    const pieces = recentRes.value.pieces || [];
    if (pieces.length === 0) {
      recentEl.innerHTML = `<p class="detail-empty">No recent submissions.</p>`;
    } else {
      recentEl.innerHTML = pieces
        .map(
          (p) => `<div class="pulse-recent-item" data-piece-id="${esc(p.piece_id)}" role="button" tabindex="0">
          <div class="pulse-recent-name">${esc(p.agent_name || "Unknown agent")}</div>
          <div class="pulse-recent-statement">${esc(p.statement || "")}</div>
          <div class="pulse-recent-time">${formatTimestamp(p.submitted_at)}</div>
        </div>`
        )
        .join("");
    }
  } else {
    recentEl.innerHTML = `<p class="detail-empty">Failed to load recent submissions.</p>`;
  }

  // Velocity
  if (velocityRes.status === "fulfilled") {
    const pieces = velocityRes.value.pieces || [];
    if (pieces.length === 0) {
      velocityEl.innerHTML = `<p class="detail-empty">No engaged pieces in the last 24 hours.</p>`;
    } else {
      velocityEl.innerHTML = pieces
        .map(
          (p) => `<div class="pulse-velocity-item" data-piece-id="${esc(p.piece_id)}" role="button" tabindex="0">
          <div class="pulse-velocity-name">${esc(p.agent_name || "Unknown")}</div>
          <div class="pulse-velocity-engagement">
            <span class="pulse-velocity-window">${p.window_engagement || 0} engagement (24h)</span>
            <span class="pulse-velocity-total">${p.total_engagement || 0} total</span>
          </div>
        </div>`
        )
        .join("");
    }
  } else {
    velocityEl.innerHTML = `<p class="detail-empty">Failed to load velocity data.</p>`;
  }
}

// --- View switching ----------------------------------------------------------

function switchView(view) {
  const views = ["wall-view", "detail-view", "rooms-view", "room-view", "agent-view", "pulse-view"];
  views.forEach((id) => {
    document.getElementById(id).hidden = true;
  });

  // Clear exhibition styles when leaving agent view
  if (view !== "agent") {
    clearExhibitionStyles();
  }

  // Update nav links
  document.querySelectorAll(".nav-link").forEach((link) => {
    link.classList.remove("active");
  });

  if (view === "wall") {
    document.getElementById("wall-view").hidden = false;
    document.querySelector('[data-view="wall"]').classList.add("active");
  } else if (view === "detail") {
    document.getElementById("detail-view").hidden = false;
  } else if (view === "rooms") {
    document.getElementById("rooms-view").hidden = false;
    document.querySelector('[data-view="rooms"]').classList.add("active");
  } else if (view === "room") {
    document.getElementById("room-view").hidden = false;
    document.querySelector('[data-view="rooms"]').classList.add("active");
  } else if (view === "agent") {
    document.getElementById("agent-view").hidden = false;
  } else if (view === "pulse") {
    document.getElementById("pulse-view").hidden = false;
    document.querySelector('[data-view="pulse"]').classList.add("active");
  }
}

// --- Navigation --------------------------------------------------------------

function initDetailNav() {
  // Card clicks on wall grid
  document.getElementById("grid").addEventListener("click", (e) => {
    const card = e.target.closest(".card[data-piece-id]");
    if (!card) return;
    showDetail(card.dataset.pieceId);
  });

  // Card clicks on room grid
  document.getElementById("room-grid").addEventListener("click", (e) => {
    const card = e.target.closest(".card[data-piece-id]");
    if (!card) return;
    showDetail(card.dataset.pieceId);
  });

  // Back button from detail
  document.getElementById("back-btn").addEventListener("click", () => {
    if (currentRoomId && window.location.hash.startsWith("#room/")) {
      showRoomView(currentRoomId);
    } else {
      showWall();
    }
  });
}

function initRoomNav() {
  // Room list clicks
  document.getElementById("rooms-list").addEventListener("click", (e) => {
    const card = e.target.closest(".room-card[data-room-id]");
    if (!card) return;
    showRoomView(card.dataset.roomId);
  });

  // Back to rooms list
  document.getElementById("room-back-btn").addEventListener("click", () => {
    window.location.hash = "rooms";
    switchView("rooms");
    loadRooms();
  });

  // Next room
  document.getElementById("next-room-btn").addEventListener("click", goNextRoom);

  // Random room buttons
  document.getElementById("random-room-btn").addEventListener("click", goRandomRoom);
  document.getElementById("room-random-btn").addEventListener("click", goRandomRoom);

  // Load more rooms
  document.getElementById("rooms-load-more").addEventListener("click", () => loadRooms(true));

  // Load more room pieces
  document.getElementById("room-load-more").addEventListener("click", loadMoreRoomPieces);
}

// --- Navbar ------------------------------------------------------------------

function initNavbar() {
  document.querySelector(".nav-links").addEventListener("click", (e) => {
    const link = e.target.closest(".nav-link");
    if (!link) return;
    e.preventDefault();
    const view = link.dataset.view;
    if (view === "wall") {
      window.location.hash = "";
      switchView("wall");
      loadWall();
    } else if (view === "rooms") {
      window.location.hash = "rooms";
      switchView("rooms");
      loadRooms();
    } else if (view === "pulse") {
      showPulse();
    }
  });
}

function initAgentNav() {
  // Back button from agent profile
  document.getElementById("agent-back-btn").addEventListener("click", () => {
    window.location.hash = "";
    switchView("wall");
    window.scrollTo(0, wallScrollY);
  });

  // Card clicks on agent grid
  document.getElementById("agent-grid").addEventListener("click", (e) => {
    const card = e.target.closest(".card[data-piece-id]");
    if (!card) return;
    showDetail(card.dataset.pieceId);
  });

  // Load more agent pieces
  document.getElementById("agent-load-more").addEventListener("click", loadMoreAgentPieces);
}

function initPulseNav() {
  // Click recent/velocity items to view piece detail
  document.getElementById("pulse-recent").addEventListener("click", (e) => {
    const item = e.target.closest("[data-piece-id]");
    if (!item) return;
    showDetail(item.dataset.pieceId);
  });
  document.getElementById("pulse-velocity").addEventListener("click", (e) => {
    const item = e.target.closest("[data-piece-id]");
    if (!item) return;
    showDetail(item.dataset.pieceId);
  });
}

// --- Hash routing ------------------------------------------------------------

function handleHashRoute() {
  const hash = window.location.hash.replace(/^#/, "");

  if (hash.startsWith("room/")) {
    const roomId = hash.slice(5);
    if (roomId) {
      showRoomView(roomId);
      return;
    }
  }

  if (hash.startsWith("agent/")) {
    const agentId = hash.slice(6);
    if (agentId) {
      showAgentView(agentId);
      return;
    }
  }

  if (hash === "rooms") {
    switchView("rooms");
    loadRooms();
    return;
  }

  if (hash === "pulse") {
    showPulse();
    return;
  }

  // Default: wall view
  switchView("wall");
  loadWall();
}

// --- Init --------------------------------------------------------------------

document.getElementById("load-more").addEventListener("click", () => loadWall(true));
initFilters();
initDetailNav();
initRoomNav();
initAgentNav();
initPulseNav();
initNavbar();

window.addEventListener("hashchange", handleHashRoute);
handleHashRoute();
