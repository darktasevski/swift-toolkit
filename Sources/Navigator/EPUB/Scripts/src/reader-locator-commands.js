// Copyright 2026 Readium Foundation. All rights reserved.
// Use of this source code is governed by the BSD-style license
// available in the top-level LICENSE file of the project.

import { TextQuoteAnchor } from "./vendor/hypothesis/anchoring/types";
import { getClientRectsNoOverlap } from "./rect";

const LIMITS = Object.freeze({
  payloadBytes: 64 * 1024,
  nestingDepth: 6,
  stringUTF16: 16 * 1024,
  selectorUTF16: 8 * 1024,
  hrefOrTitleUTF16: 4 * 1024,
  // Must accept the bounded context emitted by selection.js and stored in Locator.Text.
  quoteContextUTF16: 200,
  highlightUTF16: 16384,
});

const TOKEN_KEYS = new Set([
  "webViewInstanceID",
  "documentEpoch",
  "operationKind",
  "sequence",
  "groupID",
  "budgetMilliseconds",
]);
// Upper bound on the injected remaining budget. The budget is minted by the
// native side from one absolute monotonic deadline, so this is a validation
// ceiling against a malformed/hostile value, not a policy timeout.
const MAX_BUDGET_MILLISECONDS = 600000;
const LOCATOR_KEYS = new Set(["href", "type", "title", "locations", "text"]);
const LOCATION_KEYS = new Set([
  "fragments",
  "progression",
  "totalProgression",
  "position",
  "cssSelector",
  "domRange",
]);
const TEXT_KEYS = new Set(["before", "highlight", "after"]);
const DOM_RANGE_KEYS = new Set(["start", "end"]);
const DOM_POINT_KEYS = new Set(["cssSelector", "textNodeIndex", "charOffset"]);
const NAVIGATE_KEYS = new Set(["kind", "payload", "animated"]);
const VALIDATE_UNIQUE_TEXT_KEYS = new Set(["kind", "payload", "cssSelector"]);
const REPLACE_DECORATIONS_KEYS = new Set([
  "kind",
  "groupID",
  "decorations",
  "activable",
]);
const DECORATION_KEYS = new Set(["id", "locator", "style"]);
const DECORATION_STYLE_KEYS = new Set([
  "layout",
  "width",
  "element",
  "stylesheet",
]);
const OPERATION_KINDS = new Set(["navigation", "decoration", "validation"]);
const DECORATION_LAYOUTS = new Set(["bounds", "boxes"]);
const DECORATION_WIDTHS = new Set(["wrap", "bounds", "viewport", "page"]);

const utf8Encoder = new TextEncoder();
const requestFrame = globalThis.requestAnimationFrame.bind(globalThis);
const cancelFrame = globalThis.cancelAnimationFrame.bind(globalThis);
const scheduleTimeout = globalThis.setTimeout.bind(globalThis);
const cancelTimeout = globalThis.clearTimeout.bind(globalThis);
const FRAME_DEADLINE_MILLISECONDS = 250;
const latestSequences = new Map();
const decorationGroups = new Map();
// Per-command cancellation relay: maps a command's `tokenKey` to the
// `AbortController` for the command currently in flight under that key. This is
// the JS half of the relay — the exported `invalidate(token)` positively aborts
// an in-flight command that cooperative sequence-polling (`isCurrent`) would
// otherwise never notice (a caller cancellation with no successor bumps no
// sequence). The native bridge round-trip that CALLS `invalidate(token)` on
// supersession/caller cancellation is in place: the bridge records the in-flight
// (token, frame) synchronously before `callAsyncJavaScript` and runs
// `invalidate(token)` in that same stored frame and content world, and the
// navigation queue fires that relay before awaiting its predecessor's bounded
// acknowledgement. Each `execute` registers its controller synchronously before
// its first suspension so a relay `invalidate()` issued in the next JS turn
// finds it.
const inFlightCommands = new Map();
let documentIdentity = null;

class CommandRejection {
  constructor(reasonCode) {
    this.reasonCode = reasonCode;
  }
}

function reject(reasonCode) {
  throw new CommandRejection(reasonCode);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireOnlyKeys(object, allowed) {
  if (!isObject(object)) {
    reject("invalidField");
  }
  for (const key of Object.keys(object)) {
    if (!allowed.has(key)) {
      reject("unknownField");
    }
  }
}

function requireString(value, limit, tooLongCode = "stringTooLong") {
  if (typeof value !== "string") {
    reject("invalidField");
  }
  if (value.length > limit) {
    reject(tooLongCode);
  }
  return value;
}

function requireNonnegativeInteger(value) {
  if (!Number.isInteger(value) || value < 0) {
    reject("invalidInteger");
  }
}

function requireProgression(value) {
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    reject("invalidNumber");
  }
}

function scanStrictJSON(source) {
  let index = 0;

  function current() {
    return index < source.length ? source[index] : null;
  }

  function skipWhitespace() {
    while (
      current() === " " ||
      current() === "\t" ||
      current() === "\n" ||
      current() === "\r"
    ) {
      index += 1;
    }
  }

  function consume(expected) {
    if (current() !== expected) {
      reject("malformed");
    }
    index += 1;
  }

  function consumeIfPresent(expected) {
    if (current() !== expected) {
      return false;
    }
    index += 1;
    return true;
  }

  function scanString() {
    const start = index;
    consume('"');
    let escaped = false;
    while (current() !== null) {
      const character = current();
      index += 1;
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === '"') {
        try {
          return JSON.parse(source.slice(start, index));
        } catch (_) {
          reject("malformed");
        }
      }
    }
    reject("malformed");
  }

  function scanLiteral(literal) {
    for (const character of literal) {
      consume(character);
    }
  }

  function scanNumber() {
    const start = index;
    while (
      current() !== null &&
      current() !== " " &&
      current() !== "\t" &&
      current() !== "\n" &&
      current() !== "\r" &&
      current() !== "," &&
      current() !== "]" &&
      current() !== "}"
    ) {
      index += 1;
    }
    if (index === start) {
      reject("malformed");
    }
  }

  function validateDepth(depth) {
    if (depth > LIMITS.nestingDepth) {
      reject("nestingTooDeep");
    }
  }

  function scanObject(depth) {
    validateDepth(depth);
    consume("{");
    skipWhitespace();
    if (consumeIfPresent("}")) {
      return;
    }

    const keys = new Set();
    for (;;) {
      const key = scanString();
      if (keys.has(key)) {
        reject("duplicateField");
      }
      keys.add(key);
      skipWhitespace();
      consume(":");
      skipWhitespace();
      scanValue(depth);
      skipWhitespace();
      if (consumeIfPresent("}")) {
        return;
      }
      consume(",");
      skipWhitespace();
    }
  }

  function scanArray(depth) {
    validateDepth(depth);
    consume("[");
    skipWhitespace();
    if (consumeIfPresent("]")) {
      return;
    }
    for (;;) {
      scanValue(depth);
      skipWhitespace();
      if (consumeIfPresent("]")) {
        return;
      }
      consume(",");
      skipWhitespace();
    }
  }

  function scanValue(depth) {
    switch (current()) {
      case "{":
        scanObject(depth + 1);
        break;
      case "[":
        scanArray(depth + 1);
        break;
      case '"':
        scanString();
        break;
      case "t":
        scanLiteral("true");
        break;
      case "f":
        scanLiteral("false");
        break;
      case "n":
        scanLiteral("null");
        break;
      default:
        scanNumber();
        break;
    }
  }

  skipWhitespace();
  scanValue(0);
  skipWhitespace();
  if (index !== source.length) {
    reject("malformed");
  }
}

function validateDOMPoint(value) {
  if (!isObject(value)) {
    reject("invalidDOMRange");
  }
  requireOnlyKeys(value, DOM_POINT_KEYS);
  if (!("cssSelector" in value) || !("textNodeIndex" in value)) {
    reject("invalidDOMRange");
  }
  requireString(value.cssSelector, LIMITS.selectorUTF16, "selectorTooLong");
  requireNonnegativeInteger(value.textNodeIndex);
  if ("charOffset" in value) {
    requireNonnegativeInteger(value.charOffset);
  }
}

function validateDOMRange(value) {
  if (!isObject(value)) {
    reject("invalidDOMRange");
  }
  requireOnlyKeys(value, DOM_RANGE_KEYS);
  if (!("start" in value) || !("end" in value)) {
    reject("invalidDOMRange");
  }
  validateDOMPoint(value.start);
  validateDOMPoint(value.end);
}

function validateLocations(value) {
  requireOnlyKeys(value, LOCATION_KEYS);
  if ("fragments" in value) {
    if (!Array.isArray(value.fragments)) {
      reject("invalidField");
    }
    for (const fragment of value.fragments) {
      requireString(fragment, LIMITS.stringUTF16);
    }
  }
  if ("progression" in value) {
    requireProgression(value.progression);
  }
  if ("totalProgression" in value) {
    requireProgression(value.totalProgression);
  }
  if ("position" in value) {
    requireNonnegativeInteger(value.position);
  }
  if ("cssSelector" in value) {
    requireString(value.cssSelector, LIMITS.selectorUTF16, "selectorTooLong");
  }
  if ("domRange" in value) {
    validateDOMRange(value.domRange);
  }
}

function validateText(value) {
  requireOnlyKeys(value, TEXT_KEYS);
  if ("before" in value) {
    requireString(
      value.before,
      LIMITS.quoteContextUTF16,
      "quoteContextTooLong"
    );
  }
  if ("highlight" in value) {
    requireString(value.highlight, LIMITS.highlightUTF16, "highlightTooLong");
  }
  if ("after" in value) {
    requireString(value.after, LIMITS.quoteContextUTF16, "quoteContextTooLong");
  }
}

function decodeLocator(source) {
  if (typeof source !== "string") {
    reject("invalidField");
  }
  if (utf8Encoder.encode(source).length > LIMITS.payloadBytes) {
    reject("payloadTooLarge");
  }
  scanStrictJSON(source);

  let locator;
  try {
    locator = JSON.parse(source);
  } catch (_) {
    reject("malformed");
  }
  if (!isObject(locator)) {
    reject("invalidRoot");
  }
  requireOnlyKeys(locator, LOCATOR_KEYS);
  if (!("href" in locator)) {
    reject("missingRequiredField");
  }
  requireString(locator.href, LIMITS.hrefOrTitleUTF16);
  if ("type" in locator) {
    requireString(locator.type, LIMITS.stringUTF16);
  }
  if ("title" in locator) {
    requireString(locator.title, LIMITS.hrefOrTitleUTF16);
  }
  if ("locations" in locator) {
    validateLocations(locator.locations);
  }
  if ("text" in locator) {
    validateText(locator.text);
  }
  return locator;
}

function validateToken(value) {
  requireOnlyKeys(value, TOKEN_KEYS);
  const webViewInstanceID = requireString(value.webViewInstanceID, 128);
  const operationKind = requireString(value.operationKind, 32);
  if (!OPERATION_KINDS.has(operationKind)) {
    reject("invalidToken");
  }
  requireNonnegativeInteger(value.documentEpoch);
  requireNonnegativeInteger(value.sequence);
  if ("groupID" in value) {
    requireString(value.groupID, LIMITS.hrefOrTitleUTF16);
  }
  // The remaining budget is REQUIRED: it is the JavaScript end of the single
  // absolute deadline the native side mints at operation start. Accepting a
  // token without it would silently restore the unbounded, reset-per-rung
  // behaviour this replaces, so a missing budget is a rejected token.
  requireNonnegativeInteger(value.budgetMilliseconds);
  if (value.budgetMilliseconds > MAX_BUDGET_MILLISECONDS) {
    reject("invalidToken");
  }
  return {
    webViewInstanceID,
    documentEpoch: value.documentEpoch,
    operationKind,
    sequence: value.sequence,
    budgetMilliseconds: value.budgetMilliseconds,
    ...(value.groupID === undefined ? {} : { groupID: value.groupID }),
  };
}

function tokenKey(token) {
  return `${token.operationKind}:${token.groupID ?? ""}`;
}

function acceptToken(token) {
  const identity = `${token.webViewInstanceID}:${token.documentEpoch}`;
  if (documentIdentity !== null && documentIdentity !== identity) {
    return false;
  }
  documentIdentity = identity;

  const key = tokenKey(token);
  const latest = latestSequences.get(key);
  if (latest !== undefined && latest > token.sequence) {
    return false;
  }
  latestSequences.set(key, token.sequence);
  return true;
}

function isCurrent(token) {
  const identity = `${token.webViewInstanceID}:${token.documentEpoch}`;
  return (
    documentIdentity === identity &&
    latestSequences.get(tokenKey(token)) === token.sequence
  );
}

function commandResult(token, outcome, reasonCode) {
  return { token, outcome, reasonCode };
}

function textNodeAt(element, requestedIndex) {
  let index = 0;
  for (const child of element.childNodes) {
    if (child.nodeType !== Node.TEXT_NODE) {
      continue;
    }
    if (index === requestedIndex) {
      return child;
    }
    index += 1;
  }
  return null;
}

function uniqueElement(selector) {
  let matches;
  try {
    matches = document.querySelectorAll(selector);
  } catch (_) {
    return null;
  }
  return matches.length === 1 ? matches[0] : null;
}

function quoteRoot(locator) {
  const selector = locator.locations?.cssSelector;
  return (selector && uniqueElement(selector)) || document.body;
}

function rangeMatchesQuote(range, root, text) {
  if (!text?.highlight) {
    return true;
  }
  try {
    const actual = TextQuoteAnchor.fromRange(root, range);
    return (
      actual.exact === text.highlight &&
      (text.before === undefined || actual.context.prefix === text.before) &&
      (text.after === undefined || actual.context.suffix === text.after)
    );
  } catch (_) {
    return false;
  }
}

function rangeFromDOMRange(locator) {
  const value = locator.locations?.domRange;
  if (!value) {
    return null;
  }
  const startElement = uniqueElement(value.start.cssSelector);
  const endElement = uniqueElement(value.end.cssSelector);
  if (!startElement || !endElement) {
    return null;
  }
  const startNode = textNodeAt(startElement, value.start.textNodeIndex);
  const endNode = textNodeAt(endElement, value.end.textNodeIndex);
  if (!startNode || !endNode) {
    return null;
  }
  const startOffset = value.start.charOffset ?? 0;
  const endOffset = value.end.charOffset ?? 0;
  if (startOffset > startNode.length || endOffset > endNode.length) {
    return null;
  }

  try {
    const range = document.createRange();
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
    if (
      range.collapsed ||
      !rangeMatchesQuote(range, quoteRoot(locator), locator.text)
    ) {
      return null;
    }
    return range;
  } catch (_) {
    return null;
  }
}

function rangeFromQuote(locator) {
  if (!locator.text?.highlight) {
    return null;
  }
  try {
    return new TextQuoteAnchor(quoteRoot(locator), locator.text.highlight, {
      prefix: locator.text.before,
      suffix: locator.text.after,
    }).toRange();
  } catch (_) {
    return null;
  }
}

function rangeAroundElement(element) {
  try {
    const range = document.createRange();
    range.selectNode(element);
    return range;
  } catch (_) {
    return null;
  }
}

function rangeFromElement(locator) {
  if (locator.text?.highlight) {
    return null;
  }
  const locations = locator.locations;
  if (!locations) {
    return null;
  }
  if (locations.cssSelector) {
    const element = uniqueElement(locations.cssSelector);
    if (element) {
      return rangeAroundElement(element);
    }
  }
  for (const fragment of locations.fragments ?? []) {
    const element = document.getElementById(fragment);
    if (element) {
      return rangeAroundElement(element);
    }
  }
  return null;
}

function resolveLocator(locator) {
  return (
    rangeFromDOMRange(locator) ||
    rangeFromQuote(locator) ||
    rangeFromElement(locator)
  );
}

async function boundedTextContentExcludingUnrenderedSubtrees(
  root,
  token,
  signal
) {
  if (root.matches("script,style,noscript")) {
    return { status: "ready", text: "" };
  }
  const walker = document.createTreeWalker(
    root,
    NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
    {
      acceptNode(node) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          const tag = node.tagName;
          if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT") {
            return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    }
  );
  const parts = [];
  let textUnits = 0;
  let visitedNodes = 0;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    visitedNodes += 1;
    if (visitedNodes > 100_000) {
      return { status: "tooLarge" };
    }
    if (visitedNodes % 2_048 === 0) {
      await new Promise((resolve) => scheduleTimeout(resolve, 0));
      if (signal?.aborted || !isCurrent(token)) {
        return { status: "stale" };
      }
    }
    if (node.nodeType !== Node.TEXT_NODE) {
      continue;
    }
    const value = node.nodeValue || "";
    textUnits += value.length;
    if (textUnits > 1_000_000) {
      return { status: "tooLarge" };
    }
    parts.push(value);
  }
  return { status: "ready", text: parts.join("") };
}

function normalizeDOMText(value) {
  return value
    .replace(/[\u202A-\u202E\u2066-\u2069\uFEFF\u200B]/g, "")
    .normalize("NFC")
    .replace(/[\s\u0085]+/g, " ");
}

async function validateUniqueTextMatch(command, token, signal) {
  requireOnlyKeys(command, VALIDATE_UNIQUE_TEXT_KEYS);
  if (
    command.kind !== "validateUniqueTextMatch" ||
    token.operationKind !== "validation"
  ) {
    reject("invalidCommand");
  }
  const locator = decodeLocator(command.payload);
  const highlight = locator.text?.highlight;
  if (!highlight) {
    reject("invalidField");
  }
  const selector =
    command.cssSelector === undefined
      ? undefined
      : requireString(
          command.cssSelector,
          LIMITS.selectorUTF16,
          "selectorTooLong"
        );
  if (signal?.aborted || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  const root = selector === undefined ? document.body : uniqueElement(selector);
  if (!root) {
    return commandResult(token, "miss", "notFound");
  }
  const extraction = await boundedTextContentExcludingUnrenderedSubtrees(
    root,
    token,
    signal
  );
  if (extraction.status === "stale") {
    return commandResult(token, "cancelled", "staleToken");
  }
  if (extraction.status !== "ready") {
    return commandResult(token, "miss", "matchRootTooLarge");
  }
  const text = normalizeDOMText(extraction.text);
  const quote = normalizeDOMText(highlight);
  if (!quote) {
    return commandResult(token, "miss", "invalidField");
  }
  let count = 0;
  for (
    let index = text.indexOf(quote);
    index !== -1;
    index = text.indexOf(quote, index + quote.length)
  ) {
    count += 1;
    if (count > 1) {
      break;
    }
  }
  if (signal?.aborted || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  return commandResult(
    token,
    count === 1 ? "applied" : "miss",
    count === 1 ? "none" : "notUnique"
  );
}

function validateDecorationStyle(value) {
  requireOnlyKeys(value, DECORATION_STYLE_KEYS);
  const layout = requireString(value.layout, 16);
  const width = requireString(value.width, 16);
  const element = requireString(value.element, LIMITS.payloadBytes);
  const stylesheet =
    value.stylesheet === undefined
      ? ""
      : requireString(value.stylesheet, LIMITS.payloadBytes);
  if (!DECORATION_LAYOUTS.has(layout) || !DECORATION_WIDTHS.has(width)) {
    reject("invalidField");
  }
  return { layout, width, element, stylesheet };
}

function validateReplaceDecorations(command, token) {
  requireOnlyKeys(command, REPLACE_DECORATIONS_KEYS);
  if (
    command.kind !== "replaceDecorationGroup" ||
    token.operationKind !== "decoration" ||
    typeof command.activable !== "boolean" ||
    !Array.isArray(command.decorations)
  ) {
    reject("invalidCommand");
  }
  const groupID = requireString(command.groupID, LIMITS.hrefOrTitleUTF16);
  if (token.groupID !== groupID || command.decorations.length > 4096) {
    reject("invalidToken");
  }

  const identifiers = new Set();
  let stringUnits = groupID.length;
  const decorations = command.decorations.map((value) => {
    requireOnlyKeys(value, DECORATION_KEYS);
    const id = requireString(value.id, LIMITS.hrefOrTitleUTF16);
    if (identifiers.has(id)) {
      reject("duplicateField");
    }
    identifiers.add(id);
    const locatorSource = requireString(value.locator, LIMITS.payloadBytes);
    const locator = decodeLocator(locatorSource);
    const style = validateDecorationStyle(value.style);
    stringUnits +=
      id.length +
      locatorSource.length +
      style.element.length +
      style.stylesheet.length;
    if (stringUnits > 2 * 1024 * 1024) {
      reject("payloadTooLarge");
    }
    return {
      id,
      locator,
      style,
      fingerprint: JSON.stringify([
        locatorSource,
        style.layout,
        style.width,
        style.element,
        style.stylesheet,
      ]),
    };
  });
  return { groupID, decorations, activable: command.activable };
}

function decorationWritingMode() {
  return globalThis.getComputedStyle(document.body).writingMode;
}

function positionDecorationElement(element, rect, bounds, style) {
  const scrollingElement = document.scrollingElement;
  if (!scrollingElement) {
    reject("notScrollable");
  }
  const writingMode = decorationWritingMode();
  const isVertical = writingMode.startsWith("vertical");
  const isVerticalRL = writingMode === "vertical-rl";
  const rootViewport = effectiveRootViewportSize();
  const viewportWidth = isVertical ? rootViewport.height : rootViewport.width;
  const viewportHeight = isVertical ? rootViewport.width : rootViewport.height;
  const columnCount =
    Number.parseInt(
      globalThis
        .getComputedStyle(document.documentElement)
        .getPropertyValue("column-count")
    ) || 1;
  const pageSize = (isVertical ? viewportHeight : viewportWidth) / columnCount;
  const xOffset = scrollingElement.scrollLeft;
  const yOffset = scrollingElement.scrollTop;

  element.style.position = "absolute";
  element.style.pointerEvents = "none";
  element.dataset.writingMode = writingMode;

  if (isVertical) {
    let source = rect;
    if (style.width === "wrap") {
      element.style.width = `${rect.width}px`;
      element.style.height = `${rect.height}px`;
      element.style.top = `${rect.top + yOffset}px`;
    } else if (style.width === "viewport") {
      element.style.width = `${rect.height}px`;
      element.style.height = `${viewportWidth}px`;
      element.style.top = `${
        Math.floor(rect.top / viewportWidth) * viewportWidth + yOffset
      }px`;
    } else if (style.width === "page") {
      element.style.width = `${rect.height}px`;
      element.style.height = `${pageSize}px`;
      element.style.top = `${
        Math.floor(rect.top / pageSize) * pageSize + yOffset
      }px`;
    } else {
      source = bounds;
      element.style.width = `${bounds.height}px`;
      element.style.height = `${viewportWidth}px`;
      element.style.top = `${bounds.top + yOffset}px`;
    }
    if (isVerticalRL) {
      element.style.right = `${
        -source.right - xOffset + scrollingElement.clientWidth
      }px`;
    } else {
      element.style.left = `${source.left + xOffset}px`;
    }
    return;
  }

  const source = style.width === "bounds" ? bounds : rect;
  if (style.width === "viewport") {
    element.style.width = `${viewportWidth}px`;
    element.style.left = `${
      Math.floor(rect.left / viewportWidth) * viewportWidth + xOffset
    }px`;
  } else if (style.width === "page") {
    element.style.width = `${pageSize}px`;
    element.style.left = `${
      Math.floor(rect.left / pageSize) * pageSize + xOffset
    }px`;
  } else {
    element.style.width = `${source.width}px`;
    element.style.left = `${source.left + xOffset}px`;
  }
  element.style.height = `${source.height}px`;
  element.style.top = `${source.top + yOffset}px`;
}

function buildDecorationGroup(value, token, previous) {
  if (!document.body) {
    reject("notFound");
  }
  const container = document.createElement("div");
  container.style.pointerEvents = "none";

  const stylesheets = new Set(
    value.decorations
      .map((decoration) => decoration.style.stylesheet)
      .filter((stylesheet) => stylesheet.length > 0)
  );
  if (stylesheets.size > 0) {
    const styleElement = document.createElement("style");
    styleElement.textContent = Array.from(stylesheets).join("\n");
    container.append(styleElement);
  }

  const items = [];
  const previousItems = new Map(
    (previous?.items ?? []).map((item) => [item.id, item])
  );
  for (const decoration of value.decorations) {
    if (!isCurrent(token)) {
      return { status: "stale" };
    }
    const previousItem = previousItems.get(decoration.id);
    const range =
      previousItem?.fingerprint === decoration.fingerprint
        ? previousItem.range
        : resolveLocator(decoration.locator);
    if (!range) {
      return { status: "notFound" };
    }
    const bounds = range.getBoundingClientRect();
    const rects =
      decoration.style.layout === "boxes"
        ? getClientRectsNoOverlap(
            range,
            !decorationWritingMode().startsWith("vertical")
          )
        : [bounds];
    if (rects.length === 0) {
      return { status: "notFound" };
    }

    const template = document.createElement("template");
    template.innerHTML = decoration.style.element.trim();
    const elementTemplate = template.content.firstElementChild;
    if (!elementTemplate) {
      return { status: "invalid" };
    }

    const itemContainer = document.createElement("div");
    itemContainer.style.pointerEvents = "none";
    const clickableElements = [];
    for (const rect of rects) {
      const element = elementTemplate.cloneNode(true);
      positionDecorationElement(element, rect, bounds, decoration.style);
      itemContainer.append(element);
      clickableElements.push(element);
    }
    container.append(itemContainer);
    items.push({
      id: decoration.id,
      fingerprint: decoration.fingerprint,
      range,
      clickableElements,
    });
  }
  return { status: "ready", container, items };
}

function restoreDecorationGroup(groupID, state) {
  const current = decorationGroups.get(groupID);
  current?.container?.remove();
  if (state) {
    document.body.append(state.container);
    decorationGroups.set(groupID, state);
  } else {
    decorationGroups.delete(groupID);
  }
}

function isScrollModeEnabled() {
  return (
    globalThis
      .getComputedStyle(document.documentElement)
      .getPropertyValue("--USER__view")
      .trim() === "readium-scroll-on"
  );
}

function isVerticalWritingMode() {
  return globalThis
    .getComputedStyle(document.documentElement)
    .writingMode.startsWith("vertical");
}

function isRTL() {
  const style = globalThis.getComputedStyle(document.documentElement);
  return style.direction === "rtl" || style.writingMode === "vertical-rl";
}

function snapOffset(offset) {
  const viewportWidth = effectiveRootViewportSize().width;
  const delta = isRTL() ? -1 : 1;
  const value = offset + delta;
  return value - (value % viewportWidth);
}

function scrollToRange(range, animated) {
  const rect = range.getBoundingClientRect();
  const scrollingElement = document.scrollingElement;
  if (!scrollingElement) {
    return false;
  }
  if (isScrollModeEnabled() && !isVerticalWritingMode()) {
    scrollingElement.scrollTo({
      top: rect.top + globalThis.scrollY,
      behavior: animated ? "smooth" : "instant",
    });
  } else {
    scrollingElement.scrollTo({
      left: snapOffset(rect.left + globalThis.scrollX),
      behavior: animated ? "smooth" : "instant",
    });
  }
  return true;
}

// `deadlineAt` is an absolute `performance.now()` instant derived ONCE per
// command from the native side's monotonic deadline. Each frame wait is bounded
// by whatever remains of it, never by a fresh per-frame allowance — so a
// starved rAF can no longer multiply a per-rung timeout across the viewport,
// offset-settle, and correction rungs and overrun the total command budget.
function nextFrame(token, signal, deadlineAt) {
  return new Promise((resolve) => {
    const remaining = deadlineAt - performance.now();
    if (!(remaining > 0)) {
      // Budget already spent (or a non-finite deadline): terminal now, before
      // any timer/rAF/listener is registered, so there is nothing to tear down.
      // Resolving here is what stops an exhausted command from buying one more
      // frame at every remaining rung.
      resolve("timeout");
      return;
    }
    let settled = false;
    let frameID = 0;
    const finish = (status) => {
      if (settled) {
        return;
      }
      settled = true;
      cancelTimeout(timeoutID);
      if (frameID) {
        cancelFrame(frameID);
      }
      if (signal) {
        signal.removeEventListener("abort", onAbort);
      }
      resolve(status);
    };
    const onAbort = () => finish("stale");
    const timeoutID = scheduleTimeout(
      () => finish("timeout"),
      Math.min(FRAME_DEADLINE_MILLISECONDS, remaining)
    );
    if (signal) {
      if (signal.aborted) {
        finish("stale");
        return;
      }
      signal.addEventListener("abort", onAbort, { once: true });
    }
    try {
      frameID = requestFrame(() =>
        finish(
          isCurrent(token) && !(signal && signal.aborted) ? "current" : "stale"
        )
      );
    } catch (_) {
      finish("timeout");
    }
  });
}

// Bounded per the decoration engine's own per-item rect count (buildDecorationGroup
// has no explicit rect cap today, but its callers bound decoration count at 4096 and
// this check exists purely to defend the interior hit-test below against a hostile
// document producing pathological fragment counts for one range).
const MAX_VISIBILITY_FRAGMENTS = 64;
// A late reflow (font/layout settle finishing after the scroll offset itself already
// stabilized) can leave the scroll position correct for a now-stale target rect. Bound
// the number of corrective re-scroll attempts rather than looping unboundedly.
const MAX_VISIBILITY_CORRECTIONS = 2;
const CORRECTION_SETTLE_FRAMES = 10;
// A freshly attached spread web view learns its size from the UI process
// asynchronously; until then the layout viewport is 0×0 and every
// viewport-relative computation is degenerate (NaN page snapping, clamped
// scroll writes, structurally false visibility). Frozen as
// `locatorNavigationBudgets.viewportReadyFrames` in
// docs/benchmarks/render-faithful-v7-budgets.json (measured propagation is
// ~5 frames; the cap is a generous bound, not a tuning knob).
const VIEWPORT_READY_FRAMES = 60;
// Node-span preflight budget, aligned with the visited-node cap of
// `boundedTextContentExcludingUnrenderedSubtrees` above: a range spanning more
// nodes than this is rejected BEFORE `Range.getClientRects()` materializes a
// fragment list for it. Legitimate ranges (a quote, a chapter element) span
// far fewer nodes; only a hostile document exceeds it.
const MAX_VISIBILITY_NODE_SPAN = 100_000;
const MAX_CLIP_ANCESTOR_DEPTH = 256;
const MAX_FRAME_CHAIN_DEPTH = 8;
// At most this many visible fragments are interior hit-tested, five probes
// each — a fixed probe budget independent of document size.
const MAX_OCCLUSION_FRAGMENTS = 8;
const OCCLUSION_PROBE_FRACTIONS = [
  [0.5, 0.5],
  [0.25, 0.25],
  [0.75, 0.25],
  [0.25, 0.75],
  [0.75, 0.75],
];

function rectIsUsable(rect) {
  return (
    Number.isFinite(rect.left) &&
    Number.isFinite(rect.top) &&
    Number.isFinite(rect.right) &&
    Number.isFinite(rect.bottom) &&
    rect.width > 0 &&
    rect.height > 0
  );
}

// `document.documentElement.clientWidth/clientHeight` (the CSS layout viewport) rather
// than `window.innerWidth/innerHeight`: the latter reflects WebKit's visual viewport,
// which can transiently read 0 immediately after a resource transition even though the
// layout viewport — the same coordinate space `Range.getClientRects()` reports in — is
// already correctly sized. Comparing against the layout viewport keeps this check
// self-consistent with the geometry it is inspecting.
function effectiveRootViewportSize() {
  return {
    width: document.documentElement.clientWidth,
    height: document.documentElement.clientHeight,
  };
}

function nearestElement(node) {
  return node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
}

function rectComponentsFinite(rect) {
  return (
    Number.isFinite(rect.left) &&
    Number.isFinite(rect.top) &&
    Number.isFinite(rect.right) &&
    Number.isFinite(rect.bottom)
  );
}

function intersectRects(a, b) {
  return {
    left: Math.max(a.left, b.left),
    top: Math.max(a.top, b.top),
    right: Math.min(a.right, b.right),
    bottom: Math.min(a.bottom, b.bottom),
  };
}

function rectIsNonEmpty(rect) {
  return rect.right > rect.left && rect.bottom > rect.top;
}

// Counts the nodes the range actually spans, pruning non-intersecting subtrees,
// and stops as soon as the budget is exceeded — so the walk itself is bounded by
// the budget, not by document size. Fail closed on any DOM API throw.
function rangeSpanExceedsBudget(range) {
  const common = range.commonAncestorContainer;
  const root =
    common.nodeType === Node.ELEMENT_NODE ||
    common.nodeType === Node.DOCUMENT_NODE
      ? common
      : common.parentNode;
  if (!root) {
    return false;
  }
  let walker;
  try {
    walker = document.createTreeWalker(
      root,
      NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          try {
            return range.intersectsNode(node)
              ? NodeFilter.FILTER_ACCEPT
              : NodeFilter.FILTER_REJECT;
          } catch (_) {
            return NodeFilter.FILTER_REJECT;
          }
        },
      }
    );
  } catch (_) {
    return true;
  }
  let count = 0;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    count += 1;
    if (count > MAX_VISIBILITY_NODE_SPAN) {
      return true;
    }
  }
  return false;
}

// Computed `visibility` on the nearest element is inheritance-correct on its own
// (a descendant `visibility: visible` overrides a hidden ancestor and computes
// visible), so no ancestor walk is needed for it. Opacity does NOT inherit — it
// composites multiplicatively, so an ancestor with computed opacity 0 blanks the
// subtree while the descendant still computes 1 — that one needs a bounded
// ancestor walk. `display: none` and `content-visibility: hidden` subtrees
// produce no client rects at all and surface as `rangeNotVisible` downstream.
function endpointCSSSuppression(node) {
  const element = nearestElement(node);
  if (!element) {
    return "suppressed";
  }
  let style;
  try {
    style = globalThis.getComputedStyle(element);
  } catch (_) {
    return "unverifiable";
  }
  if (style.visibility === "hidden" || style.visibility === "collapse") {
    return "suppressed";
  }
  let ancestor = element;
  let depth = 0;
  while (ancestor) {
    depth += 1;
    if (depth > MAX_CLIP_ANCESTOR_DEPTH) {
      return "unverifiable";
    }
    let ancestorStyle;
    try {
      ancestorStyle = globalThis.getComputedStyle(ancestor);
    } catch (_) {
      return "unverifiable";
    }
    if (Number.parseFloat(ancestorStyle.opacity) === 0) {
      return "suppressed";
    }
    ancestor = ancestor.parentElement;
  }
  return "visible";
}

// Collects the clip boxes of every overflow-clipping ancestor of the range's
// common ancestor. `html`/`body` are excluded: the root clip is the layout
// viewport (applied separately), and the pagination engine's own multicolumn
// boxes on the root elements would over-clip every fragment.
function ancestorClipChain(range) {
  const start = nearestElement(range.commonAncestorContainer);
  if (!start) {
    return { status: "unverifiable" };
  }
  const clips = [];
  let element = start;
  let depth = 0;
  while (
    element &&
    element !== document.body &&
    element !== document.documentElement
  ) {
    depth += 1;
    if (depth > MAX_CLIP_ANCESTOR_DEPTH) {
      return { status: "unverifiable" };
    }
    let style;
    try {
      style = globalThis.getComputedStyle(element);
    } catch (_) {
      return { status: "unverifiable" };
    }
    if (style.overflowX !== "visible" || style.overflowY !== "visible") {
      const box = element.getBoundingClientRect();
      if (!rectComponentsFinite(box)) {
        return { status: "unverifiable" };
      }
      clips.push(box);
    }
    element = element.parentElement;
  }
  return { status: "ok", clips };
}

// Intersects a fragment rect with the root layout viewport and every ancestor
// clip box; null when nothing of the fragment survives.
function effectivelyVisibleSubRect(rect, clips) {
  const viewport = effectiveRootViewportSize();
  let visible = intersectRects(rect, {
    left: 0,
    top: 0,
    right: viewport.width,
    bottom: viewport.height,
  });
  if (!rectIsNonEmpty(visible)) {
    return null;
  }
  for (const clip of clips) {
    visible = intersectRects(visible, clip);
    if (!rectIsNonEmpty(visible)) {
      return null;
    }
  }
  return visible;
}

// Decoration overlays are `pointer-events: none`, so `elementFromPoint` never
// reports them as occluders. A probe confirms the target when the topmost
// element at an interior point of a visible fragment is the range's own content
// (intersects the range) or one of its ancestors — the topmost paintable at a
// glyph point when nothing covers it.
function probeConfirmsRange(range, subRect) {
  for (const [fractionX, fractionY] of OCCLUSION_PROBE_FRACTIONS) {
    const x = subRect.left + (subRect.right - subRect.left) * fractionX;
    const y = subRect.top + (subRect.bottom - subRect.top) * fractionY;
    let hit;
    try {
      hit = document.elementFromPoint(x, y);
    } catch (_) {
      continue;
    }
    if (!hit) {
      continue;
    }
    try {
      if (
        range.intersectsNode(hit) ||
        hit.contains(range.commonAncestorContainer)
      ) {
        return true;
      }
    } catch (_) {
      continue;
    }
  }
  return false;
}

// Capped same-origin ancestor-frame chain: transforms a locally visible
// sub-rect into each parent frame (offset plus uniform scale — a rotated frame
// is unverifiable), intersects it with that frame's layout viewport, and probes
// its center so a parent-document overlay covering the frame is rejected.
// Dormant today: fixed layout is command-ineligible and reflowable resources
// load in the main frame, so this returns "visible" at depth 0.
function frameChainVerdict(localSubRect) {
  let rect = {
    left: localSubRect.left,
    top: localSubRect.top,
    right: localSubRect.right,
    bottom: localSubRect.bottom,
  };
  let currentWindow = globalThis;
  let currentDocument = document;
  let depth = 0;
  const visited = [];
  for (;;) {
    let frameElement;
    try {
      frameElement = currentWindow.frameElement;
    } catch (_) {
      return "unverifiable";
    }
    if (!frameElement) {
      return "visible";
    }
    depth += 1;
    if (depth > MAX_FRAME_CHAIN_DEPTH || visited.includes(currentWindow)) {
      return "unverifiable";
    }
    visited.push(currentWindow);
    const parentDocument = frameElement.ownerDocument;
    const parentWindow = parentDocument ? parentDocument.defaultView : null;
    if (!parentWindow || !parentDocument.documentElement) {
      return "unverifiable";
    }
    const frameBox = frameElement.getBoundingClientRect();
    const childWidth = currentDocument.documentElement.clientWidth;
    const childHeight = currentDocument.documentElement.clientHeight;
    if (
      !rectComponentsFinite(frameBox) ||
      !(childWidth > 0) ||
      !(childHeight > 0)
    ) {
      return "unverifiable";
    }
    const scaleX = frameBox.width / childWidth;
    const scaleY = frameBox.height / childHeight;
    if (
      !Number.isFinite(scaleX) ||
      !Number.isFinite(scaleY) ||
      scaleX <= 0 ||
      scaleY <= 0
    ) {
      return "unverifiable";
    }
    rect = {
      left: frameBox.left + rect.left * scaleX,
      top: frameBox.top + rect.top * scaleY,
      right: frameBox.left + rect.right * scaleX,
      bottom: frameBox.top + rect.bottom * scaleY,
    };
    rect = intersectRects(rect, {
      left: 0,
      top: 0,
      right: parentDocument.documentElement.clientWidth,
      bottom: parentDocument.documentElement.clientHeight,
    });
    if (!rectIsNonEmpty(rect)) {
      return "clipped";
    }
    let hit;
    try {
      hit = parentDocument.elementFromPoint(
        (rect.left + rect.right) / 2,
        (rect.top + rect.bottom) / 2
      );
    } catch (_) {
      return "unverifiable";
    }
    if (
      !hit ||
      (hit !== frameElement &&
        !frameElement.contains(hit) &&
        !hit.contains(frameElement))
    ) {
      return "obscured";
    }
    currentWindow = parentWindow;
    currentDocument = parentDocument;
  }
}

// Waits, bounded, for the document to have a usable (non-zero) layout
// viewport before any viewport-relative work runs. Returns "usable",
// "notReady" (budget exhausted while still 0-sized), "timeout" (a frame
// never arrived), or "stale".
async function awaitUsableViewport(token, signal, deadlineAt) {
  for (let frame = 0; frame <= VIEWPORT_READY_FRAMES; frame += 1) {
    const viewport = effectiveRootViewportSize();
    if (viewport.width > 0 && viewport.height > 0) {
      return "usable";
    }
    if (frame === VIEWPORT_READY_FRAMES) {
      return "notReady";
    }
    if (signal?.aborted || !isCurrent(token)) {
      return "stale";
    }
    const frameStatus = await nextFrame(token, signal, deadlineAt);
    if (frameStatus !== "current" || signal?.aborted || !isCurrent(token)) {
      return frameStatus === "timeout" ? "timeout" : "stale";
    }
  }
  return "notReady";
}

async function awaitOffsetStability(token, maximumFrames, signal, deadlineAt) {
  let previousX = globalThis.scrollX;
  let previousY = globalThis.scrollY;
  let stableFrames = 0;
  for (let frame = 0; frame < maximumFrames; frame += 1) {
    if (signal?.aborted || !isCurrent(token)) {
      return "stale";
    }
    const frameStatus = await nextFrame(token, signal, deadlineAt);
    if (frameStatus !== "current" || signal?.aborted || !isCurrent(token)) {
      return frameStatus === "timeout" ? "timeout" : "stale";
    }
    const currentX = globalThis.scrollX;
    const currentY = globalThis.scrollY;
    if (currentX === previousX && currentY === previousY) {
      stableFrames += 1;
      if (stableFrames >= 2) {
        return "stable";
      }
    } else {
      stableFrames = 0;
      previousX = currentX;
      previousY = currentY;
    }
  }
  return "timeout";
}

// Re-resolves the locator against the CURRENT DOM/layout rather than trusting a
// previously resolved Range object, then proves the resolved range is EFFECTIVELY
// visible: not collapsed, still attached, within the node-span budget (checked
// BEFORE getClientRects materializes geometry), not CSS-suppressed, with usable
// (finite, positive-area) fragments below the hostile-document cap of which at
// least one survives the ancestor clip chain plus the root layout viewport, is
// not completely occluded under bounded interior hit-testing, and stays visible
// through the capped same-origin ancestor-frame chain. Returns only closed
// reason codes — never text, locators, hrefs, or geometry.
function verifyEffectiveVisibility(locator) {
  const range = resolveLocator(locator);
  if (!range) {
    return { status: "miss", reason: "notFound", range: null };
  }
  if (range.collapsed) {
    return { status: "miss", reason: "rangeCollapsed", range };
  }
  if (!range.startContainer.isConnected || !range.endContainer.isConnected) {
    return { status: "miss", reason: "rangeDetached", range };
  }
  if (rangeSpanExceedsBudget(range)) {
    return { status: "miss", reason: "rangeTooComplex", range };
  }
  const startSuppression = endpointCSSSuppression(range.startContainer);
  const endSuppression = endpointCSSSuppression(range.endContainer);
  if (
    startSuppression === "unverifiable" ||
    endSuppression === "unverifiable"
  ) {
    return { status: "miss", reason: "geometryUnverifiable", range };
  }
  if (startSuppression === "suppressed" && endSuppression === "suppressed") {
    return { status: "miss", reason: "rangeSuppressed", range };
  }
  const rects = Array.from(range.getClientRects()).filter(rectIsUsable);
  if (rects.length > MAX_VISIBILITY_FRAGMENTS) {
    return { status: "miss", reason: "rangeTooComplex", range };
  }
  if (rects.length === 0) {
    return { status: "miss", reason: "rangeNotVisible", range };
  }
  const chain = ancestorClipChain(range);
  if (chain.status !== "ok") {
    return { status: "miss", reason: "geometryUnverifiable", range };
  }
  const visibleSubRects = [];
  for (const rect of rects) {
    const subRect = effectivelyVisibleSubRect(rect, chain.clips);
    if (subRect) {
      visibleSubRects.push(subRect);
    }
  }
  if (visibleSubRects.length === 0) {
    return { status: "miss", reason: "rangeNotVisible", range };
  }
  let confirmed = null;
  for (const subRect of visibleSubRects.slice(0, MAX_OCCLUSION_FRAGMENTS)) {
    if (probeConfirmsRange(range, subRect)) {
      confirmed = subRect;
      break;
    }
  }
  if (!confirmed) {
    return { status: "miss", reason: "rangeObscured", range };
  }
  const frameVerdict = frameChainVerdict(confirmed);
  if (frameVerdict === "clipped") {
    return { status: "miss", reason: "rangeNotVisible", range };
  }
  if (frameVerdict === "obscured") {
    return { status: "miss", reason: "rangeObscured", range };
  }
  if (frameVerdict !== "visible") {
    return { status: "miss", reason: "geometryUnverifiable", range };
  }
  return { status: "visible", range };
}

// Scrolls toward the target, waits for the scroll offset itself to settle (preserving
// the caller's single smooth animation when requested), then re-resolves and verifies
// the target is actually visible — correcting, at most twice and always without
// animation, if a late reflow moved it after the offset settled.
async function landAndVerify(
  locator,
  initialRange,
  token,
  animated,
  signal,
  deadlineAt
) {
  const viewportStatus = await awaitUsableViewport(token, signal, deadlineAt);
  if (viewportStatus === "stale") {
    return { status: "cancelled" };
  }
  if (viewportStatus === "timeout") {
    return { status: "miss", reason: "paintTimeout" };
  }
  if (viewportStatus === "notReady") {
    return { status: "miss", reason: "viewportNotReady" };
  }

  if (rangeSpanExceedsBudget(initialRange)) {
    return { status: "miss", reason: "rangeTooComplex" };
  }
  if (!scrollToRange(initialRange, animated)) {
    return { status: "miss", reason: "notScrollable" };
  }
  if (!isCurrent(token)) {
    return { status: "cancelled" };
  }

  let settleOutcome = await awaitOffsetStability(
    token,
    animated ? 120 : 2,
    signal,
    deadlineAt
  );
  for (
    let correction = 0;
    correction <= MAX_VISIBILITY_CORRECTIONS;
    correction += 1
  ) {
    if (settleOutcome === "stale") {
      return { status: "cancelled" };
    }
    if (settleOutcome === "timeout") {
      return { status: "miss", reason: "paintTimeout" };
    }
    if (!isCurrent(token)) {
      return { status: "cancelled" };
    }

    const verification = verifyEffectiveVisibility(locator);
    if (verification.status === "visible") {
      return { status: "visible" };
    }
    if (verification.reason !== "rangeNotVisible" || !verification.range) {
      return { status: "miss", reason: verification.reason };
    }
    if (correction === MAX_VISIBILITY_CORRECTIONS) {
      return { status: "miss", reason: "rangeNotVisible" };
    }

    if (!scrollToRange(verification.range, false)) {
      return { status: "miss", reason: "notScrollable" };
    }
    if (!isCurrent(token)) {
      return { status: "cancelled" };
    }
    settleOutcome = await awaitOffsetStability(
      token,
      CORRECTION_SETTLE_FRAMES,
      signal,
      deadlineAt
    );
  }
  return { status: "miss", reason: "rangeNotVisible" };
}

async function navigateLocator(command, token, signal, deadlineAt) {
  requireOnlyKeys(command, NAVIGATE_KEYS);
  if (
    command.kind !== "navigateLocator" ||
    typeof command.animated !== "boolean"
  ) {
    reject("invalidCommand");
  }
  if (token.operationKind !== "navigation") {
    reject("invalidToken");
  }
  const locator = decodeLocator(command.payload);
  if (signal?.aborted || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  const range = resolveLocator(locator);
  if (!range) {
    return commandResult(token, "miss", "notFound");
  }
  if (signal?.aborted || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  const preScrollFrame = await nextFrame(token, signal, deadlineAt);
  if (preScrollFrame === "timeout") {
    return commandResult(token, "miss", "paintTimeout");
  }
  if (preScrollFrame !== "current" || signal?.aborted || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  const landing = await landAndVerify(
    locator,
    range,
    token,
    command.animated,
    signal,
    deadlineAt
  );
  if (landing.status === "cancelled") {
    return commandResult(token, "cancelled", "staleToken");
  }
  if (landing.status === "miss") {
    return commandResult(token, "miss", landing.reason);
  }
  return commandResult(token, "applied", "none");
}

async function replaceDecorationGroup(command, token, signal, deadlineAt) {
  const value = validateReplaceDecorations(command, token);
  if (signal?.aborted || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }

  const previous = decorationGroups.get(value.groupID);
  const built = buildDecorationGroup(value, token, previous);
  if (built.status === "stale") {
    return commandResult(token, "cancelled", "staleToken");
  }
  if (built.status === "notFound") {
    return commandResult(token, "miss", "notFound");
  }
  if (built.status !== "ready") {
    return commandResult(token, "miss", "invalidField");
  }

  const prePaintFrame = await nextFrame(token, signal, deadlineAt);
  if (prePaintFrame === "timeout") {
    return commandResult(token, "miss", "paintTimeout");
  }
  if (prePaintFrame !== "current" || signal?.aborted || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }

  previous?.container?.remove();
  document.body.append(built.container);
  const state = {
    token,
    command,
    container: built.container,
    items: built.items,
    activable: value.activable,
  };
  decorationGroups.set(value.groupID, state);

  for (let frame = 0; frame < 2; frame += 1) {
    const paintFrame = await nextFrame(token, signal, deadlineAt);
    if (paintFrame !== "current" || signal?.aborted || !isCurrent(token)) {
      if (decorationGroups.get(value.groupID) === state) {
        restoreDecorationGroup(value.groupID, previous);
      }
      return commandResult(
        token,
        paintFrame === "timeout" ? "miss" : "cancelled",
        paintFrame === "timeout" ? "paintTimeout" : "staleToken"
      );
    }
  }
  return commandResult(token, "applied", "none");
}

async function execute(commandValue, tokenValue) {
  let token;
  let key;
  let controller;
  try {
    token = validateToken(tokenValue);
    if (!acceptToken(token)) {
      return commandResult(token, "cancelled", "staleToken");
    }
    // Register the cancellation channel SYNCHRONOUSLY, before the first
    // suspension, so a relay `invalidate(token)` issued in the next JS turn —
    // while this command is parked at a frame/settle await — finds and aborts
    // it. A newer command for the same key overwrites this entry and owns its
    // own teardown; the `finally` below only clears its own registration.
    key = tokenKey(token);
    controller = new AbortController();
    inFlightCommands.set(key, { sequence: token.sequence, controller });
    // The ONE absolute deadline for this command, converted from the remaining
    // budget the native side derived from its own monotonic deadline at
    // operation start. Everything downstream reads what is LEFT of this instant;
    // nothing re-derives, extends, or resets it per frame, resource, or rung.
    const deadlineAt = performance.now() + token.budgetMilliseconds;
    if (!isObject(commandValue)) {
      reject("invalidCommand");
    }
    switch (commandValue.kind) {
      case "navigateLocator":
        return await navigateLocator(
          commandValue,
          token,
          controller.signal,
          deadlineAt
        );
      case "replaceDecorationGroup":
        return await replaceDecorationGroup(
          commandValue,
          token,
          controller.signal,
          deadlineAt
        );
      case "validateUniqueTextMatch":
        return await validateUniqueTextMatch(
          commandValue,
          token,
          controller.signal
        );
      default:
        reject("invalidCommand");
    }
  } catch (error) {
    // Cancellation and receipt currency take precedence over classifying a
    // current-document WebKit/DOM failure as a miss: a command aborted mid-flight
    // (or superseded) reports `cancelled`, never a spurious `miss` that would let
    // a consumer fall back and fight the newer navigation.
    if (token && (controller?.signal.aborted || !isCurrent(token))) {
      return commandResult(token, "cancelled", "staleToken");
    }
    const reasonCode =
      error instanceof CommandRejection ? error.reasonCode : "internalError";
    return commandResult(token ?? null, "miss", reasonCode);
  } finally {
    // Teardown on every terminal path (success, miss, cancellation, timeout,
    // document invalidation): abort the controller so any listener registered
    // with its signal is released, and clear our own registry entry. Per-await
    // timers/rAF ids self-clean in their own `finish`; aborting here is the
    // single teardown point future stylesheet/font/scrollend/visibility/pagehide
    // listeners must register against.
    if (controller) {
      controller.abort();
    }
    if (key !== undefined && token !== undefined) {
      const entry = inFlightCommands.get(key);
      if (entry && entry.sequence === token.sequence) {
        inFlightCommands.delete(key);
      }
    }
  }
}

// The fixed-source entry point the native cancellation relay calls. Positively
// aborts the in-flight command registered under `token`'s key when the sequence
// matches, returning a benign `invalidated: false` acknowledgement when no such
// live command exists (already completed, superseded, an older/stale sequence,
// or never started) rather than throwing. Never mutates `latestSequences` —
// supersession is the caller's channel; this is orthogonal.
function invalidate(tokenValue) {
  let token;
  try {
    token = validateToken(tokenValue);
  } catch (_) {
    return { token: null, invalidated: false };
  }
  const entry = inFlightCommands.get(tokenKey(token));
  if (entry && entry.sequence === token.sequence) {
    entry.controller.abort();
    return { token, invalidated: true };
  }
  return { token, invalidated: false };
}

function decorationAtPoint(x, y) {
  const groups = Array.from(decorationGroups.entries()).reverse();
  for (const [groupID, state] of groups) {
    if (!state.activable || !isCurrent(state.token)) {
      continue;
    }
    for (const item of [...state.items].reverse()) {
      for (const element of item.clickableElements) {
        const rect = element.getBoundingClientRect();
        if (
          x >= rect.left - 1 &&
          x <= rect.right + 1 &&
          y >= rect.top - 1 &&
          y <= rect.bottom + 1
        ) {
          return { groupID, item, rect };
        }
      }
    }
  }
  return null;
}

document.addEventListener(
  "click",
  (event) => {
    if (!event.isTrusted || !globalThis.getSelection()?.isCollapsed) {
      return;
    }
    const target = decorationAtPoint(event.clientX, event.clientY);
    if (!target) {
      return;
    }
    try {
      globalThis.webkit?.messageHandlers?.readerLocatorDecorationActivated?.postMessage(
        {
          id: target.item.id,
          group: target.groupID,
          token: decorationGroups.get(target.groupID)?.token,
          rect: {
            left: target.rect.left,
            top: target.rect.top,
            width: target.rect.width,
            height: target.rect.height,
          },
          click: {
            defaultPrevented: event.defaultPrevented,
            x: event.clientX,
            y: event.clientY,
            targetElement: "",
          },
        }
      );
    } catch (_) {
      // Activation delivery is best-effort. Painting state is independent of
      // native callback availability.
    }
  },
  true
);

// The unforgeable per-document capability the native side issues to THIS document
// instance (via callAsyncJavaScript into the frame's current document). It starts
// null: the document does not register as a command target until it has received a
// capability, so a bare document-start href announcement can never register.
let frameCapability = null;

// The postMessage discriminator for a wrapper->child capability hand-off. Fixed
// layout loads the resource inside a child iframe, which native cannot reach with
// `callAsyncJavaScript(in: nil)` (that runs in the wrapper's main frame). The
// wrapper forwards the capability one hop to its direct child; the child accepts
// it but never re-forwards, so a nested/self-navigated grandchild can never
// obtain it.
const FRAME_CAPABILITY_MESSAGE_TYPE = "readium.locator.frameCapability";

function postFrameReady() {
  if (frameCapability === null) {
    return;
  }
  try {
    globalThis.webkit?.messageHandlers?.readerLocatorFrameReady?.postMessage({
      href: document.location.href,
      capability: frameCapability,
    });
  } catch (_) {
    // Native frame registration is best-effort. The native registry rejects a
    // command unless it can select exactly one eligible frame for the document.
  }
}

// Forwards the capability to every DIRECT child iframe of this document, once,
// same-origin. Only the frame the native side injected into (the wrapper's main
// frame) forwards; a frame that accepted a forwarded capability never re-forwards.
// The child validates that the message came from its parent, that its parent is
// the top frame, and that the origin matches, so nothing but the wrapper's direct
// resource child can consume it.
function forwardCapabilityToChildFrames(token) {
  const targetOrigin = globalThis.location.origin;
  for (const frame of document.querySelectorAll("iframe")) {
    try {
      frame.contentWindow?.postMessage(
        { type: FRAME_CAPABILITY_MESSAGE_TYPE, capability: token },
        targetOrigin
      );
    } catch (_) {
      // A cross-origin or detached child cannot be the eligible resource frame,
      // so a failed forward is not an error.
    }
  }
}

// Called by the native side, once per document generation, with the capability it
// minted for this document instance. Only the document that receives the current
// capability can register: a delayed old document, a same-URL reload, or a
// nested/self-navigated frame never received it, so their announcements never
// present the current capability and are rejected. Reflowable content is the main
// frame and registers directly; a fixed-layout wrapper is the main frame and
// forwards the capability to its child resource frame.
function acceptFrameCapability(token) {
  if (typeof token !== "string" || token.length === 0) {
    return;
  }
  frameCapability = token;
  postFrameReady();
  forwardCapabilityToChildFrames(token);
}

// Receives a capability forwarded by the parent wrapper frame. Accepts it only
// from a direct child of the top frame, over the same origin, and never
// re-forwards it — so the resource frame registers while a nested grandchild or a
// self-navigated frame (whose parent is not the top frame) can never consume it.
globalThis.addEventListener("message", (event) => {
  if (
    globalThis.self === globalThis.top ||
    globalThis.parent !== globalThis.top ||
    event.source !== globalThis.parent ||
    event.origin !== globalThis.location.origin
  ) {
    return;
  }
  const data = event.data;
  if (
    !data ||
    data.type !== FRAME_CAPABILITY_MESSAGE_TYPE ||
    typeof data.capability !== "string" ||
    data.capability.length === 0
  ) {
    return;
  }
  frameCapability = data.capability;
  postFrameReady();
});

// A document being unloaded — navigated away, reloaded, terminated, or moved
// into the back/forward cache — self-revokes its capability so a queued or
// bfcache-restored frameReady can never present a stale capability after the
// document has stopped being the current target. The native side clears its own
// currentFrameCapability on teardown (EPUBSpreadView.clear()); this is the
// document-side half, covering a child self-navigation or reload the native
// spread load never observes.
globalThis.addEventListener("pagehide", () => {
  frameCapability = null;
});

Object.defineProperty(globalThis, "readerLocatorCommands", {
  configurable: false,
  enumerable: false,
  writable: false,
  value: Object.freeze({ execute, invalidate, acceptFrameCapability }),
});
