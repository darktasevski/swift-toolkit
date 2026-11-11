const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const test = require("node:test");

const script = fs.readFileSync(require.resolve("../src/image-menu.js"), "utf8");

function frame(requests, parent) {
  const handlers = new Map();
  const window = {
    innerWidth: 400,
    innerHeight: 800,
    addEventListener(type, listener) {
      handlers.set(type, listener);
    },
  };
  window.top = parent ?? window;
  window.parent = window.top;
  class Element {
    constructor(localName) {
      this.localName = localName;
    }
    baseURI = "readium://fixture/chapter.xhtml";
    getAttribute(name) {
      return this.localName === "img" && name === "src" ? "image.png" : null;
    }
    getAttributeNS() {
      return null;
    }
  }
  const webkit = {
    messageHandlers: {
      readiumImageMenu: { postMessage: (item) => requests.push(item) },
    },
  };
  vm.runInNewContext(script, { window, Element, URL, webkit });
  function fire(type, tag, overrides = {}) {
    let prevented = false;
    handlers.get(type)({
      isTrusted: true,
      isPrimary: true,
      pointerId: 1,
      pointerType: "mouse",
      button: 2,
      clientX: 20,
      clientY: 30,
      screenX: 120,
      screenY: 130,
      composedPath: () => [new Element(tag)],
      preventDefault() {
        prevented = true;
      },
      stopImmediatePropagation() {},
      ...overrides,
    });
    return prevented;
  }
  return { window, fire };
}

for (const nested of [false, true]) {
  test(
    "resolves a late image hit " +
      (nested ? "inside a fixed-layout frame" : "in the current document"),
    () => {
      const requests = [];
      const press = frame(requests);
      const release = nested ? frame(requests, press.window) : press;
      press.fire("pointerdown", "html", { clientX: -1, clientY: -1 });
      press.fire("contextmenu", "html", { clientX: -1, clientY: -1 });
      release.fire("pointerup", "img");
      assert.equal(
        requests.length,
        1,
        "the right-button release opened the menu"
      );
      release.fire("contextmenu", "img");
      assert.deepEqual(
        requests.map((item) => [item.kind, item.url]),
        [["image", "readium://fixture/image.png"]]
      );
    }
  );
}

test("suppresses the fallback edit menu when WebKit has no press location", () => {
  const { fire } = frame([]);
  const missing = { clientX: -1, clientY: -1 };
  fire("pointerdown", "html", missing);
  assert.equal(fire("contextmenu", "html", missing), true);
});

test("a right drag from the background does not open an image menu", () => {
  const requests = [];
  const { fire } = frame(requests);
  fire("pointerdown", "html");
  fire("pointermove", "img", { screenX: 220, buttons: 2 });
  fire("pointerup", "img");
  assert.deepEqual(requests, []);
});
