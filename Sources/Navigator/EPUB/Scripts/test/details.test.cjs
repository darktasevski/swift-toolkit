const assert = require("node:assert/strict");
const fs = require("node:fs");
const { createRequire } = require("node:module");
const test = require("node:test");
const vm = require("node:vm");
const babel = require("@babel/core");

// Loads an ES module of `src` as CommonJS, as the bundle's Babel pass reads
// it, with each import named in `stubs` answered by its stub.
function load(file, stubs = {}) {
  const path = require.resolve(`../src/${file}`);
  const { code } = babel.transformSync(fs.readFileSync(path, "utf8"), {
    babelrc: false,
    configFile: false,
    presets: [["@babel/preset-env", { modules: "commonjs" }]],
  });
  const module = { exports: {} };
  const requireFrom = createRequire(path);
  vm.runInNewContext(code, {
    exports: module.exports,
    module,
    require: (specifier) => stubs[specifier] ?? requireFrom(specifier),
  });
  return module.exports;
}

// An element of a fake document: its children are attached as given.
function element(localName, children = [], { open = false } = {}) {
  const node = {
    localName,
    nodeName: localName.toUpperCase(),
    children: [],
    parentElement: null,
    open,
    outerHTML: `<${localName}>`,
    hasAttribute: () => false,
    getAttribute: () => null,
  };
  for (const child of children) {
    child.parentElement = node;
    if (child.localName) {
      node.children.push(child);
    }
  }
  return node;
}

function text() {
  return { parentElement: null };
}

test("a target in a closed disclosure's content opens it, and every closed one around it", () => {
  const { revealDetailsAround } = load("details-reveal.js");
  const target = text();
  const inner = element("details", [element("summary"), element("p", [target])]);
  const outer = element("details", [element("summary"), inner]);

  revealDetailsAround(target);

  assert.equal(inner.open, true);
  assert.equal(outer.open, true);
});

test("a target in a disclosure's summary leaves it as it was", () => {
  const { revealDetailsAround } = load("details-reveal.js");
  const target = text();
  const details = element("details", [element("summary", [target]), element("p")]);

  revealDetailsAround(target);

  assert.equal(details.open, false);
});

test("only a disclosure's first summary is its summary", () => {
  const { revealDetailsAround } = load("details-reveal.js");
  const target = text();
  const details = element("details", [
    element("summary"),
    element("summary", [target]),
  ]);

  revealDetailsAround(target);

  assert.equal(details.open, true);
});

test("a tap in a disclosure's content is no tap on a control, and one in its summary is", () => {
  const { findNearestInteractiveElement } = load("dom.js", {
    "./utils": { isScrollModeEnabled: () => false },
    "css-selector-generator": { getCssSelector: () => "" },
  });
  const inContent = element("span");
  const inSummary = element("span");
  element("details", [element("summary", [inSummary]), element("p", [inContent])]);

  assert.equal(findNearestInteractiveElement(inContent), null);
  assert.equal(findNearestInteractiveElement(inSummary), "<summary>");
});
