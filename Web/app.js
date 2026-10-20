export function tokens(query) {
  return (query.toLocaleLowerCase("ru").match(/-?"[^"]*"|\S+/g) || [])
    .map((s) => ({
      exclude: s.startsWith("-"),
      value: s.replace(/^-/, "").replaceAll('"', ""),
    }))
    .filter((x) => x.value);
}
export function matches(item, state) {
  const hay = [item.title, item.category, ...item.tags]
    .join(" ")
    .toLocaleLowerCase("ru");
  return (
    (!state.category || item.category === state.category) &&
    (!state.orientation ||
      (state.orientation === "square"
        ? item.width === item.height
        : state.orientation === "landscape"
          ? item.width > item.height
          : item.height > item.width)) &&
    item.width >= state.resolution &&
    [...state.tags].every((t) => item.tags.includes(t)) &&
    (!state.onlyFavorites || state.favorites.has(item.sha256)) &&
    tokens(state.query).every((t) =>
      t.exclude ? !hay.includes(t.value) : hay.includes(t.value),
    )
  );
}
export function safeMedia(path) {
  return (
    typeof path === "string" &&
    /^(media\/[a-f0-9]{64}\.(jpg|jpeg|png|webp|gif|bmp|avif|tif|tiff)|thumbs\/[a-f0-9]{64}\.jpg)$/.test(
      path,
    )
  );
}
export function safeSource(url) {
  try {
    const u = new URL(url);
    return (
      u.protocol === "https:" &&
      u.hostname === "frutigeraeroarchive.org" &&
      !u.username &&
      !u.password
    );
  } catch {
    return false;
  }
}

if (typeof document !== "undefined") {
  const $ = (id) => document.getElementById(id),
    PAGE = 60;
  const state = {
    query: "",
    category: "",
    orientation: "",
    resolution: 0,
    tags: new Set(),
    favorites: new Set(),
    onlyFavorites: false,
    sort: "source",
    page: 1,
  };
  let items = [],
    filtered = [],
    current = -1,
    lastFocus = null;
  try {
    const saved = JSON.parse(
      localStorage.getItem("memebooru.favorites") || "[]",
    );
    if (Array.isArray(saved))
      state.favorites = new Set(saved.filter((x) => typeof x === "string"));
  } catch {}
  function element(tag, text, className) {
    const el = document.createElement(tag);
    if (text !== undefined) el.textContent = text;
    if (className) el.className = className;
    return el;
  }
  function button(text, action, className) {
    const el = element("button", text, className);
    el.type = "button";
    el.addEventListener("click", action);
    return el;
  }
  function favorite(item) {
    const id = item.sha256;
    state.favorites.has(id)
      ? state.favorites.delete(id)
      : state.favorites.add(id);
    try {
      localStorage.setItem(
        "memebooru.favorites",
        JSON.stringify([...state.favorites]),
      );
    } catch {}
    render();
    if ($("detail").open) {
      const index = filtered.findIndex((x) => x.sha256 === id);
      if (index < 0) close();
      else show(id);
    }
  }
  function updateFavorite(item) {
    const saved = state.favorites.has(item.sha256);
    $("favorite-detail").textContent = saved
      ? "♥ В избранном"
      : "♡ В избранное";
    $("favorite-detail").setAttribute("aria-pressed", String(saved));
  }
  function toggleTag(tag) {
    state.tags.has(tag) ? state.tags.delete(tag) : state.tags.add(tag);
    state.page = 1;
    render();
  }
  function renderTags() {
    const counts = new Map();
    for (const item of items)
      for (const tag of item.tags) counts.set(tag, (counts.get(tag) || 0) + 1);
    const query = $("tag-search").value.toLocaleLowerCase("ru");
    $("tag-count").textContent = counts.size;
    $("tag-list").replaceChildren(
      ...[...counts]
        .filter(([tag]) => tag.toLocaleLowerCase("ru").includes(query))
        .sort((a, b) => b[1] - a[1])
        .slice(0, 100)
        .map(([tag, n]) => {
          const b = button(tag, () => toggleTag(tag));
          b.append(element("small", n));
          b.setAttribute("aria-pressed", String(state.tags.has(tag)));
          return b;
        }),
    );
  }
  function render() {
    filtered = items.filter((item) => matches(item, state));
    if (state.sort === "resolution")
      filtered.sort((a, b) => b.width * b.height - a.width * a.height);
    else if (state.sort === "name")
      filtered.sort((a, b) => a.title.localeCompare(b.title, "ru"));
    const pages = Math.max(1, Math.ceil(filtered.length / PAGE));
    state.page = Math.min(state.page, pages);
    $("results").textContent =
      `Найдено: ${filtered.length.toLocaleString("ru")} из ${items.length.toLocaleString("ru")}`;
    $("fav-count").textContent = state.favorites.size;
    $("favorites").setAttribute("aria-pressed", String(state.onlyFavorites));
    $("selected-tags").replaceChildren(
      ...[...state.tags].map((t) => button(t + " ×", () => toggleTag(t))),
    );
    $("grid").replaceChildren(
      ...filtered
        .slice((state.page - 1) * PAGE, state.page * PAGE)
        .map((item) => {
          const card = element("article", undefined, "card");
          const open = button("", () => show(item.sha256), "card-open");
          open.setAttribute("aria-label", "Открыть: " + item.title);
          const img = element("img");
          img.src = item.thumb;
          img.alt = item.title;
          img.loading = "lazy";
          img.decoding = "async";
          img.width = 480;
          img.height = 336;
          open.append(img);
          const text = element("div", undefined, "card-text");
          text.append(element("h3", item.title));
          const meta = element("div", undefined, "meta");
          meta.append(
            element("span", `${item.width} × ${item.height}`),
            element("span", `${item.tags.length} тег.`),
          );
          text.append(meta);
          open.append(text);
          const heart = button(
            state.favorites.has(item.sha256) ? "♥" : "♡",
            () => favorite(item),
            "heart",
          );
          heart.setAttribute("aria-label", "Избранное: " + item.title);
          heart.setAttribute(
            "aria-pressed",
            String(state.favorites.has(item.sha256)),
          );
          card.append(open, heart);
          return card;
        }),
    );
    $("empty").hidden = filtered.length > 0;
    $("pagination").hidden = filtered.length === 0;
    $("page-label").textContent = `${state.page} / ${pages}`;
    $("previous").disabled = state.page === 1;
    $("next").disabled = state.page === pages;
    renderTags();
    const params = new URLSearchParams();
    if (state.query) params.set("q", state.query);
    if (state.category) params.set("category", state.category);
    for (const t of state.tags) params.append("tag", t);
    if (state.orientation) params.set("orientation", state.orientation);
    if (state.resolution) params.set("width", state.resolution);
    if (state.onlyFavorites) params.set("favorites", "1");
    if (state.sort !== "source") params.set("sort", state.sort);
    if (state.page > 1) params.set("page", state.page);
    history.replaceState(
      null,
      "",
      location.pathname + (params.size ? "?" + params : "") + location.hash,
    );
  }
  function show(id) {
    current = filtered.findIndex((x) => x.sha256 === id);
    if (current < 0) return;
    const item = filtered[current];
    $("full-image").src = item.file;
    $("full-image").alt = item.title;
    $("detail-title").textContent = item.title;
    $("detail-meta").textContent =
      `${item.width} × ${item.height} пикселей · ${(item.bytes / 1048576).toLocaleString("ru", { maximumFractionDigits: 2 })} МБ · ${item.category.replaceAll("_", " ")}`;
    $("download").href = item.file;
    $("download").download = item.file.split("/").pop();
    $("source").href = item.sourcePage;
    $("detail-tags").replaceChildren(
      ...item.tags.map((tag) =>
        button(tag, () => {
          close();
          toggleTag(tag);
        }),
      ),
    );
    $("favorite-detail").onclick = () => favorite(item);
    updateFavorite(item);
    $("detail-position").textContent = `${current + 1} / ${filtered.length}`;
    $("detail-prev").disabled = current === 0;
    $("detail-next").disabled = current === filtered.length - 1;
    if (!$("detail").open) {
      lastFocus = document.activeElement;
      $("detail").showModal();
      document.body.style.overflow = "hidden";
    }
    history.replaceState(
      null,
      "",
      location.pathname + location.search + "#" + item.sha256,
    );
  }
  function close() {
    $("detail").close();
  }
  $("detail").addEventListener("close", () => {
    document.body.style.overflow = "";
    history.replaceState(null, "", location.pathname + location.search);
    if (lastFocus?.isConnected) lastFocus.focus();
  });
  $("close").onclick = close;
  $("detail").addEventListener("click", (e) => {
    if (e.target === $("detail")) {
      const r = $("detail").getBoundingClientRect();
      if (
        e.clientX < r.left ||
        e.clientX > r.right ||
        e.clientY < r.top ||
        e.clientY > r.bottom
      )
        close();
    }
  });
  function step(delta) {
    const item = filtered[current + delta];
    if (item) show(item.sha256);
  }
  $("detail-prev").onclick = () => step(-1);
  $("detail-next").onclick = () => step(1);
  document.addEventListener("keydown", (e) => {
    if (
      $("detail").open &&
      !["INPUT", "TEXTAREA", "SELECT"].includes(e.target.tagName)
    ) {
      if (e.key === "ArrowLeft") {
        e.preventDefault();
        step(-1);
      }
      if (e.key === "ArrowRight") {
        e.preventDefault();
        step(1);
      }
    }
  });
  $("search-form").onsubmit = (e) => {
    e.preventDefault();
    state.query = $("search").value;
    state.page = 1;
    render();
  };
  $("search").addEventListener("search", () => {
    state.query = $("search").value;
    state.page = 1;
    render();
  });
  for (const key of ["category", "orientation", "resolution", "sort"])
    $(key).onchange = () => {
      state[key] = key === "resolution" ? Number($(key).value) : $(key).value;
      state.page = 1;
      render();
    };
  $("favorites").onclick = () => {
    state.onlyFavorites = !state.onlyFavorites;
    state.page = 1;
    render();
  };
  $("tag-search").oninput = renderTags;
  $("reset").onclick = () => {
    state.query = "";
    state.category = "";
    state.orientation = "";
    state.resolution = 0;
    state.tags.clear();
    state.onlyFavorites = false;
    state.page = 1;
    for (const k of ["search", "category", "orientation", "tag-search"])
      $(k).value = "";
    $("resolution").value = "0";
    render();
  };
  for (const [id, delta] of [
    ["previous", -1],
    ["next", 1],
  ])
    $(id).onclick = () => {
      state.page += delta;
      render();
      $("gallery").scrollIntoView({ behavior: "instant" });
    };
  $("filters-toggle").onclick = () => {
    const open = $("filters").classList.toggle("visible");
    $("filters-toggle").setAttribute("aria-expanded", String(open));
  };
  try {
    const response = await fetch("catalogue.json");
    if (!response.ok) throw new Error("catalogue unavailable");
    const data = await response.json();
    if (!Array.isArray(data.items) || !data.items.length)
      throw new Error("empty catalogue");
    items = data.items;
    for (const item of items)
      if (
        !safeMedia(item.file) ||
        !safeMedia(item.thumb) ||
        !safeSource(item.sourcePage) ||
        !Array.isArray(item.tags) ||
        typeof item.title !== "string" ||
        typeof item.category !== "string" ||
        !Number.isFinite(item.bytes) ||
        !Number.isFinite(item.width) ||
        !Number.isFinite(item.height)
      )
        throw new Error("invalid catalogue");
    const categories = [...new Set(items.map((x) => x.category))].sort();
    for (const cat of categories) {
      const o = element("option", cat.replaceAll("_", " "));
      o.value = cat;
      $("category").append(o);
    }
    $("collection-count").textContent =
      `${items.length.toLocaleString("ru")} изображений · разделов: ${categories.length}`;
    const p = new URLSearchParams(location.search);
    state.query = p.get("q") || "";
    state.category = p.get("category") || "";
    state.orientation = p.get("orientation") || "";
    state.resolution = Math.max(0, Number(p.get("width")) || 0);
    state.onlyFavorites = p.get("favorites") === "1";
    state.tags = new Set(p.getAll("tag"));
    state.sort = p.get("sort") || "source";
    state.page = Math.max(1, Math.floor(Number(p.get("page")) || 1));
    $("search").value = state.query;
    for (const key of ["category", "orientation", "resolution", "sort"])
      $(key).value = String(state[key]);
    render();
    if (location.hash) show(location.hash.slice(1));
  } catch (error) {
    $("results").textContent =
      "Не удалось загрузить каталог. Обновите страницу или попробуйте позже.";
    $("collection-count").textContent = "Каталог недоступен";
    console.error("Gallery could not load:", error.message);
  }
}
