/* Содержание справа подстраивается под активную вкладку (Вариант 1 / Вариант 2) */
(function () {
  function buildMap() {
    var map = [];
    var sets = document.querySelectorAll(".tabbed-set");
    sets.forEach(function (set) {
      var inputs = Array.prototype.slice.call(set.querySelectorAll(":scope > input"));
      var blocks = Array.prototype.slice.call(set.querySelectorAll(":scope > .tabbed-content > .tabbed-block"));
      inputs.forEach(function (inp, i) {
        var block = blocks[i];
        if (!block) return;
        var ids = Array.prototype.slice
          .call(block.querySelectorAll("h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]"))
          .map(function (h) { return h.id; });
        map.push({ input: inp, ids: ids });
      });
    });
    return map;
  }

  function refresh() {
    var toc = document.querySelector(".md-sidebar--secondary .md-nav--secondary");
    if (!toc) return;
    var map = buildMap();
    if (!map.length) return;

    var visible = new Set();
    map.forEach(function (t) { if (t.input.checked) t.ids.forEach(function (id) { visible.add(id); }); });

    toc.querySelectorAll("a").forEach(function (a) {
      var href = a.getAttribute("href") || "";
      var hashAt = href.indexOf("#");
      if (hashAt === -1) return;
      var id = decodeURIComponent(href.slice(hashAt + 1));
      if (!id) return;
      var inTab = map.some(function (t) { return t.ids.indexOf(id) !== -1; });
      if (!inTab) return;
      var li = a.closest("li");
      if (li) li.style.display = visible.has(id) ? "" : "none";
    });
  }

  function activateTabForHash() {
    var id = decodeURIComponent(location.hash.slice(1));
    if (!id) return;
    var target = document.getElementById(id);
    if (!target) return;
    var block = target.closest(".tabbed-block");
    if (block) {
      var set = block.closest(".tabbed-set");
      var blocks = Array.prototype.slice.call(set.querySelectorAll(":scope > .tabbed-content > .tabbed-block"));
      var idx = blocks.indexOf(block);
      var labels = set.querySelectorAll(":scope > .tabbed-labels > label");
      if (labels[idx]) labels[idx].click();
    }
  }

  function setup() {
    refresh();
    activateTabForHash();
    document.addEventListener("change", function (e) {
      if (e.target && e.target.closest && e.target.closest(".tabbed-set")) refresh();
    });
    window.addEventListener("hashchange", function () { activateTabForHash(); refresh(); });
  }

  if (typeof document$ !== "undefined" && document$.subscribe) {
    document$.subscribe(setup);          /* Material: переживает instant navigation */
  } else if (document.readyState !== "loading") {
    setup();
  } else {
    document.addEventListener("DOMContentLoaded", setup);
  }
})();
