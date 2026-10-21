import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const source = await readFile(
  new URL("../../Web/app.js", import.meta.url),
  "utf8",
);
const { tokens, matches, safeMedia, safeSource } = await import(
  "data:text/javascript;base64," + Buffer.from(source).toString("base64")
);
const item = {
  title: "Зелёные холмы",
  category: "nature",
  tags: ["небо", "трава"],
  width: 1920,
  height: 1080,
  sha256: "a".repeat(64),
};
const state = {
  query: "",
  category: "",
  orientation: "",
  resolution: 0,
  tags: new Set(),
  onlyFavorites: false,
  favorites: new Set(),
};
test("search combines phrases, exclusions, tags and dimensions", () => {
  assert.equal(
    matches(item, {
      ...state,
      query: '"зелёные холмы" -аниме',
      tags: new Set(["небо"]),
      resolution: 1920,
      orientation: "landscape",
    }),
    true,
  );
  for (const extra of [
    { query: "-небо" },
    { tags: new Set(["океан"]) },
    { resolution: 3840 },
    { orientation: "portrait" },
    { onlyFavorites: true },
    { category: "other" },
  ])
    assert.equal(matches(item, { ...state, ...extra }), false);
  assert.equal(
    matches(item, {
      ...state,
      onlyFavorites: true,
      favorites: new Set([item.sha256]),
    }),
    true,
  );
  assert.equal(tokens('  -"blue sky" ').length, 1);
});
test("only content-addressed image paths and HTTPS archive sources are accepted", () => {
  assert.equal(safeMedia(`media/${item.sha256}.jpg`), true);
  assert.equal(safeMedia(`thumbs/${item.sha256}.jpg`), true);
  for (const p of [
    "../collection.db",
    "media/a.svg",
    "https://evil.test/x.jpg",
    "media/%2e%2e/secret",
    "device.json",
  ])
    assert.equal(safeMedia(p), false);
  for (const u of [
    "javascript:alert(1)",
    "https://frutigeraeroarchive.org.evil.test/",
    "https://user:pass@frutigeraeroarchive.org/",
  ])
    assert.equal(safeSource(u), false);
  assert.equal(safeSource("https://frutigeraeroarchive.org/wallpapers"), true);
});

test("excluded tags match whole names, not substrings or title/category text", () => {
  const picture = {
    ...item,
    title: "Yellow flower l",
    category: "l",
    tags: ["metalheart", "yellow", "flower"],
  };
  for (const suffix of ["l", "llo", "llowe", "unknown", "L"]) {
    for (const tags of [new Set(), new Set(["metalheart"])]) {
      assert.equal(
        matches(picture, { ...state, query: `metalheart -${suffix}`, tags }),
        true,
      );
    }
  }
  for (const query of [
    "metalheart -yellow",
    "metalheart -YELLOW",
    "metalheart -flower",
  ]) {
    assert.equal(matches(picture, { ...state, query }), false);
  }
  assert.equal(
    matches(
      { ...picture, tags: [...picture.tags, "l"] },
      { ...state, query: "metalheart -l" },
    ),
    false,
  );
  assert.equal(
    matches(
      { ...picture, tags: [...picture.tags, "L"] },
      { ...state, query: "metalheart -l" },
    ),
    false,
  );
});
