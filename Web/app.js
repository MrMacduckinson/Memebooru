export function tokens(query) {
  return (query.toLocaleLowerCase("en").match(/-?"[^"]*"|\S+/g) || [])
    .map((s) => ({
      exclude: s.startsWith("-"),
      value: s.replace(/^-/, "").replaceAll('"', ""),
    }))
    .filter((x) => x.value);
}
export function matches(item, state) {
  const hay = [item.title, item.category, ...item.tags]
    .join(" ")
    .toLocaleLowerCase("en");
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
      t.exclude
        ? !item.tags.some((tag) => tag.toLocaleLowerCase("en") === t.value)
        : hay.includes(t.value),
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
    lastFocus = null,
    galleryScroll = 0;
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
  function detailOpen() {
    return !$("detail").hidden;
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
    if (detailOpen()) {
      const index = filtered.findIndex((x) => x.sha256 === id);
      if (index < 0) close();
      else show(id);
    }
  }
  function updateFavorite(item) {
    const saved = state.favorites.has(item.sha256);
    $("favorite-detail").textContent = saved
      ? "♥ In favorites"
      : "♡ Add to favorites";
    $("favorite-detail").setAttribute("aria-pressed", String(saved));
  }
  function toggleTag(tag) {
    close();
    setDrawer(false);
    state.tags.has(tag) ? state.tags.delete(tag) : state.tags.add(tag);
    state.page = 1;
    $("gallery").scrollTop = 0;
    render();
  }
  function renderTags() {
    const counts = new Map();
    for (const item of items)
      for (const tag of item.tags) counts.set(tag, (counts.get(tag) || 0) + 1);
    const query = $("tag-search").value.toLocaleLowerCase("en");
    $("tag-count").textContent = counts.size;
    $("tag-list").replaceChildren(
      ...[...counts]
        .filter(([tag]) => tag.toLocaleLowerCase("en").includes(query))
        .sort((a, b) => b[1] - a[1])
        .slice(0, query ? 100 : 16)
        .map(([tag, n]) => {
          const b = button("", () => toggleTag(tag));
          b.append(element("span", tag), element("small", n));
          b.setAttribute("aria-pressed", String(state.tags.has(tag)));
          return b;
        }),
    );
  }
  function render(append = false) {
    filtered = items.filter((item) => matches(item, state));
    if (state.sort === "resolution")
      filtered.sort((a, b) => b.width * b.height - a.width * a.height);
    else if (state.sort === "name")
      filtered.sort((a, b) => a.title.localeCompare(b.title, "en"));
    const pages = Math.max(1, Math.ceil(filtered.length / PAGE));
    state.page = Math.min(state.page, pages);
    $("page-title").textContent = state.onlyFavorites
      ? "Favorites"
      : state.query ||
          state.tags.size ||
          state.category ||
          state.orientation ||
          state.resolution
        ? "Search"
        : "Collection";
    $("reset").hidden = !(
      state.query ||
      state.tags.size ||
      state.category ||
      state.orientation ||
      state.resolution
    );
    $("collection").setAttribute("aria-pressed", String(!state.onlyFavorites));
    $("results").textContent =
      `Found: ${filtered.length.toLocaleString("en")} of ${items.length.toLocaleString("en")}`;
    $("fav-count").textContent = state.favorites.size;
    $("favorites").setAttribute("aria-pressed", String(state.onlyFavorites));
    $("selected-tags").replaceChildren(
      ...[...state.tags].map((t) => button(t + " ×", () => toggleTag(t))),
    );
    const cards = filtered
      .slice(append ? (state.page - 1) * PAGE : 0, state.page * PAGE)
      .map((item) => {
        const card = element("article", undefined, "card");
        const open = button("", () => show(item.sha256), "card-open");
        open.setAttribute("aria-label", "Open: " + item.title);
        const img = element("img");
        img.src = item.thumb;
        img.alt = item.title;
        img.loading = "lazy";
        img.decoding = "async";
        img.width = item.width;
        img.height = item.height;
        const box = element("div", undefined, "thumb-box");
        box.append(img);
        open.append(box);
        const text = element("div", undefined, "card-text");
        text.append(
          element("h3", item.tags.slice(0, 3).join(" ") || item.title),
        );
        const meta = element("div", undefined, "meta");
        meta.append(
          element("span", "in "),
          document.createTextNode("Pictures"),
        );
        text.append(meta);
        open.append(text);
        card.append(open);
        return card;
      });
    if (append) $("grid").append(...cards);
    else $("grid").replaceChildren(...cards);
    $("empty").hidden = filtered.length > 0;
    $("pagination").hidden = filtered.length === 0;
    $("page-label").textContent =
      `${Math.min(state.page * PAGE, filtered.length)} of ${filtered.length}`;
    $("load-more").hidden = state.page >= pages;
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
    if ($("full-image").dataset.sha256 !== item.sha256) {
      const image = element("img");
      image.id = "full-image";
      image.alt = item.title;
      image.dataset.sha256 = item.sha256;
      image.hidden = true;
      const status = $("image-status");
      status.textContent = "Loading image…";
      status.hidden = false;
      image.onload = () => {
        if ($("full-image") !== image) return;
        image.hidden = false;
        status.hidden = true;
      };
      image.onerror = () => {
        if ($("full-image") !== image) return;
        status.textContent =
          "Could not load this image. Try downloading the original.";
      };
      $("full-image").replaceWith(image);
      image.src = item.file;
    }
    $("detail-title").textContent =
      item.tags.slice(0, 4).join(" ") || item.title;
    $("detail-meta").replaceChildren(
      ...[
        ["File", item.title],
        ["Section", item.category.replaceAll("_", " ")],
        ["Resolution", `${item.width} × ${item.height}`],
        [
          "File size",
          `${(item.bytes / 1048576).toLocaleString("en", { maximumFractionDigits: 2 })} MB`,
        ],
        ["Format", item.file.split(".").pop().toUpperCase()],
        ["SHA-256", item.sha256.slice(0, 12) + "…"],
      ].flatMap(([key, value]) => [
        element("dt", key + ":"),
        element("dd", value),
      ]),
    );
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
    if (!detailOpen()) {
      lastFocus = document.activeElement;
      galleryScroll = $("gallery").scrollTop;
      $("gallery").hidden = true;
      $("detail").hidden = false;
      $("detail").focus();
      if (location.hash.slice(1) !== id)
        history.pushState(
          null,
          "",
          location.pathname + location.search + "#" + id,
        );
    }
    $("detail").scrollTop = 0;
    history.replaceState(
      null,
      "",
      location.pathname + location.search + "#" + id,
    );
  }
  function close() {
    if (!detailOpen()) return;
    $("detail").hidden = true;
    $("gallery").hidden = false;
    $("gallery").scrollTop = galleryScroll;
    history.replaceState(null, "", location.pathname + location.search);
    if (lastFocus?.isConnected) lastFocus.focus({ preventScroll: true });
  }
  $("close").onclick = close;
  window.addEventListener("popstate", () => {
    if (location.hash) show(location.hash.slice(1));
    else close();
  });
  function step(delta) {
    const item = filtered[current + delta];
    if (item) show(item.sha256);
  }
  $("detail-prev").onclick = () => step(-1);
  $("detail-next").onclick = () => step(1);
  document.addEventListener("keydown", (e) => {
    if (
      detailOpen() &&
      !["INPUT", "TEXTAREA", "SELECT"].includes(e.target.tagName)
    ) {
      if (e.key === "Escape") close();
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
    close();
    setDrawer(false);
    state.query = $("search").value;
    state.page = 1;
    $("gallery").scrollTop = 0;
    render();
  };
  $("search").addEventListener("search", () => {
    close();
    state.query = $("search").value;
    state.page = 1;
    $("gallery").scrollTop = 0;
    render();
  });
  for (const key of ["category", "orientation", "resolution", "sort"])
    $(key).onchange = () => {
      close();
      state[key] = key === "resolution" ? Number($(key).value) : $(key).value;
      state.page = 1;
      $("gallery").scrollTop = 0;
      render();
    };
  $("favorites").onclick = () => {
    close();
    setDrawer(false);
    state.onlyFavorites = !state.onlyFavorites;
    state.page = 1;
    $("gallery").scrollTop = 0;
    render();
  };
  $("tag-search").oninput = renderTags;
  $("reset").onclick = () => {
    close();
    setDrawer(false);
    state.query = "";
    state.category = "";
    state.orientation = "";
    state.resolution = 0;
    state.tags.clear();
    state.onlyFavorites = false;
    state.page = 1;
    $("gallery").scrollTop = 0;
    for (const k of ["search", "category", "orientation", "tag-search"])
      $(k).value = "";
    $("resolution").value = "0";
    render();
  };
  for (const id of [
    "collection",
    "pictures",
    "detail-category",
    "image-category",
  ])
    $(id).onclick = () => $("reset").click();
  function loadMore() {
    if (state.page * PAGE >= filtered.length || detailOpen()) return;
    state.page += 1;
    render(true);
  }
  $("load-more").onclick = loadMore;
  const observer = new IntersectionObserver(
    ([entry]) => {
      if (entry.isIntersecting) loadMore();
    },
    { root: $("gallery"), rootMargin: "150px" },
  );
  observer.observe($("pagination"));
  function setDrawer(open) {
    $("filters").classList.toggle("visible", open);
    $("filters-toggle").setAttribute("aria-expanded", String(open));
    $("drawer-shade").hidden = !open;
  }
  $("filters-toggle").onclick = () =>
    setDrawer(!$("filters").classList.contains("visible"));
  $("drawer-shade").onclick = () => setDrawer(false);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") setDrawer(false);
  });
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
    $("picture-count").textContent = items.length.toLocaleString("en");
    $("collection-count").textContent =
      `Aero Archive · posts: ${items.length.toLocaleString("en")}`;
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
      "Could not load the catalogue. Refresh the page or try again later.";
    $("collection-count").textContent = "Catalogue unavailable";
    console.error("Gallery could not load:", error.message);
  }
}
