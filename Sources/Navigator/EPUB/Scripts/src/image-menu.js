(() => {
  let pending = null;
  let consumed = false;

  // A fixed-layout wrapper can receive the press and its page frame the release.
  // The isolated world shares this record only with frames that can access the wrapper.
  const sequence = (() => {
    try {
      return (window.top[Symbol.for("readium.imageMenu.sequence")] ??= {});
    } catch {
      return {};
    }
  })();

  function cancelGesture() {
    cancelHold();
    delete sequence.secondary;
  }

  function moved(event, press) {
    return (
      press.start &&
      Math.hypot(event.screenX - press.start.x, event.screenY - press.start.y) >
        10
    );
  }

  function cancelHold() {
    if (pending) clearTimeout(pending.timer);
    pending = null;
  }

  function candidate(event) {
    let image = null;
    for (const node of event.composedPath()) {
      if (!(node instanceof Element)) continue;
      const href =
        node.getAttribute("href") ??
        node.getAttributeNS("http://www.w3.org/1999/xlink", "href");
      if (
        href !== null &&
        (node.localName === "a" ||
          node.localName === "area" ||
          node.namespaceURI === "http://www.w3.org/1998/Math/MathML")
      ) {
        return { kind: "link", raw: href, base: node.baseURI };
      }
      if (!image && (node.localName === "img" || node.localName === "image")) {
        image = {
          kind: "image",
          raw: node.currentSrc || node.getAttribute("src") || href,
          base: node.baseURI,
        };
      }
    }
    return image;
  }

  // Fixed-layout pages live in scaled frames. Translate into the top visual viewport
  // before UIKit anchors its popover. An inaccessible parent gets a centered popover.
  function anchor(x, y) {
    let view = window;
    try {
      while (view !== view.top) {
        const frame = view.frameElement;
        if (!frame || !frame.offsetWidth || !frame.offsetHeight)
          return [0.5, 0.5];
        const rect = frame.getBoundingClientRect();
        x =
          rect.left + ((x + frame.clientLeft) * rect.width) / frame.offsetWidth;
        y =
          rect.top + ((y + frame.clientTop) * rect.height) / frame.offsetHeight;
        view = view.parent;
      }
      const viewport = view.visualViewport;
      x =
        (x - (viewport?.offsetLeft ?? 0)) /
        (viewport?.width ?? view.innerWidth);
      y =
        (y - (viewport?.offsetTop ?? 0)) /
        (viewport?.height ?? view.innerHeight);
      if (Number.isFinite(x) && Number.isFinite(y)) {
        return [Math.min(1, Math.max(0, x)), Math.min(1, Math.max(0, y))];
      }
    } catch {
      // A cross-origin parent cannot supply its frame geometry.
    }
    return [0.5, 0.5];
  }

  function request(target, x, y) {
    consumed = true;
    cancelGesture();
    if (!target.raw) return;
    let url;
    try {
      url = new URL(target.raw, target.base);
    } catch {
      return;
    }
    if (["data:", "blob:", "javascript:"].includes(url.protocol)) return;
    const [px, py] = anchor(x, y);
    webkit.messageHandlers.readiumImageMenu?.postMessage({
      kind: target.kind,
      url: url.href,
      x: px,
      y: py,
    });
  }

  function swallow(event) {
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  window.addEventListener(
    "pointerdown",
    (event) => {
      if (!event.isTrusted) return;
      cancelGesture();
      consumed = false;
      if (!event.isPrimary) return;
      const target = candidate(event);
      if (!target) {
        if (event.button === 2 && event.pointerType === "mouse") {
          // Catalyst can send the press and contextmenu to the document at (-1, -1)
          // before WebKit resolves the image under the stationary button release.
          sequence.secondary = {
            id: event.pointerId,
            start:
              event.clientX < 0 || event.clientY < 0
                ? null
                : { x: event.screenX, y: event.screenY },
          };
        }
        return;
      }
      const x = event.clientX,
        y = event.clientY;
      if (
        event.button === 2 ||
        (event.button === 0 && event.ctrlKey && event.pointerType === "mouse")
      ) {
        swallow(event);
        request(target, x, y);
      } else if (
        event.button === 0 &&
        (event.pointerType === "touch" || event.pointerType === "pen")
      ) {
        pending = {
          id: event.pointerId,
          x,
          y,
          timer: setTimeout(() => request(target, x, y), 500),
        };
      }
    },
    true
  );

  window.addEventListener(
    "pointermove",
    (event) => {
      if (!event.isTrusted) return;
      const press = sequence.secondary;
      if (
        press?.id === event.pointerId &&
        (moved(event, press) || (!press.start && event.buttons & 2))
      ) {
        delete sequence.secondary;
      }
      if (
        pending?.id === event.pointerId &&
        Math.hypot(event.clientX - pending.x, event.clientY - pending.y) > 10
      )
        cancelHold();
    },
    true
  );

  window.addEventListener(
    "pointerup",
    (event) => {
      if (!event.isTrusted) return;
      const press = sequence.secondary;
      cancelGesture();
      if (
        press?.id === event.pointerId &&
        event.isPrimary &&
        event.pointerType === "mouse" &&
        event.button === 2 &&
        !moved(event, press)
      ) {
        const target = candidate(event);
        if (target) request(target, event.clientX, event.clientY);
      }
      if (consumed) swallow(event);
    },
    true
  );

  window.addEventListener(
    "contextmenu",
    (event) => {
      if (!event.isTrusted) return;
      const target = candidate(event);
      if (!target) {
        const press = sequence.secondary;
        if (
          press &&
          !press.start &&
          event.button === 2 &&
          (event.clientX < 0 || event.clientY < 0)
        ) {
          // Do not open the generic edit menu over a pending physical release.
          swallow(event);
        }
        return;
      }
      swallow(event);
      if (!consumed) request(target, event.clientX, event.clientY);
    },
    true
  );

  // WebKit can synthesize a click when releasing its highlight gesture. An ordinary
  // new pointer or keyboard activation starts a fresh sequence.
  for (const name of ["click", "auxclick"]) {
    window.addEventListener(
      name,
      (event) => {
        if (event.isTrusted && consumed) swallow(event);
      },
      true
    );
  }
  window.addEventListener(
    "keydown",
    (event) => {
      if (event.isTrusted) {
        cancelGesture();
        consumed = false;
      }
    },
    true
  );
  for (const name of ["pointercancel", "scroll", "blur", "pagehide"]) {
    window.addEventListener(name, cancelGesture, true);
  }
})();
