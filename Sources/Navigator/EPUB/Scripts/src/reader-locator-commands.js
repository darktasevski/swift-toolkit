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
  quoteContextUTF16: 64,
  highlightUTF16: 16384,
});

const TOKEN_KEYS = new Set([
  "webViewInstanceID",
  "documentEpoch",
  "operationKind",
  "sequence",
  "groupID",
]);
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
const OPERATION_KINDS = new Set(["navigation", "decoration"]);
const DECORATION_LAYOUTS = new Set(["bounds", "boxes"]);
const DECORATION_WIDTHS = new Set(["wrap", "bounds", "viewport", "page"]);

const utf8Encoder = new TextEncoder();
const requestFrame = globalThis.requestAnimationFrame.bind(globalThis);
const scheduleTimeout = globalThis.setTimeout.bind(globalThis);
const cancelTimeout = globalThis.clearTimeout.bind(globalThis);
const FRAME_DEADLINE_MILLISECONDS = 250;
const latestSequences = new Map();
const decorationGroups = new Map();
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
  return {
    webViewInstanceID,
    documentEpoch: value.documentEpoch,
    operationKind,
    sequence: value.sequence,
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
    reject("invalidDOMRange");
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
    return { id, locator, style };
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
  const viewportWidth = isVertical
    ? globalThis.innerHeight
    : globalThis.innerWidth;
  const viewportHeight = isVertical
    ? globalThis.innerWidth
    : globalThis.innerHeight;
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

function buildDecorationGroup(value, token) {
  if (!document.body) {
    reject("notFound");
  }
  const container = document.createElement("div");
  container.dataset.readerDecorationGroup = value.groupID;
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
  for (const decoration of value.decorations) {
    if (!isCurrent(token)) {
      return { status: "stale" };
    }
    const range = resolveLocator(decoration.locator);
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
    itemContainer.dataset.readerDecorationID = decoration.id;
    itemContainer.style.pointerEvents = "none";
    const clickableElements = [];
    for (const rect of rects) {
      const element = elementTemplate.cloneNode(true);
      positionDecorationElement(element, rect, bounds, decoration.style);
      itemContainer.append(element);
      clickableElements.push(element);
    }
    container.append(itemContainer);
    items.push({ id: decoration.id, range, clickableElements });
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
  const viewportWidth = globalThis.innerWidth;
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

function nextFrame(token) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (status) => {
      if (settled) {
        return;
      }
      settled = true;
      cancelTimeout(timeoutID);
      resolve(status);
    };
    const timeoutID = scheduleTimeout(
      () => finish("timeout"),
      FRAME_DEADLINE_MILLISECONDS
    );
    try {
      requestFrame(() => finish(isCurrent(token) ? "current" : "stale"));
    } catch (_) {
      finish("timeout");
    }
  });
}

async function awaitFinalPaint(token, animated) {
  let previousX = globalThis.scrollX;
  let previousY = globalThis.scrollY;
  let stableFrames = 0;
  const maximumFrames = animated ? 120 : 2;
  for (let frame = 0; frame < maximumFrames; frame += 1) {
    if (!isCurrent(token)) {
      return "stale";
    }
    const frameStatus = await nextFrame(token);
    if (frameStatus !== "current" || !isCurrent(token)) {
      return frameStatus === "timeout" ? "timeout" : "stale";
    }
    const currentX = globalThis.scrollX;
    const currentY = globalThis.scrollY;
    if (currentX === previousX && currentY === previousY) {
      stableFrames += 1;
      if (stableFrames >= 2) {
        return "painted";
      }
    } else {
      stableFrames = 0;
      previousX = currentX;
      previousY = currentY;
    }
  }
  return "timeout";
}

async function navigateLocator(command, token) {
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
  if (!isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  const range = resolveLocator(locator);
  if (!range) {
    return commandResult(token, "miss", "notFound");
  }
  if (!isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  const preScrollFrame = await nextFrame(token);
  if (preScrollFrame === "timeout") {
    return commandResult(token, "miss", "paintTimeout");
  }
  if (preScrollFrame !== "current" || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  if (!scrollToRange(range, command.animated)) {
    return commandResult(token, "miss", "notScrollable");
  }
  if (!isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  const finalPaint = await awaitFinalPaint(token, command.animated);
  if (finalPaint === "timeout") {
    return commandResult(token, "miss", "paintTimeout");
  }
  if (finalPaint !== "painted" || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }
  return commandResult(token, "applied", "none");
}

async function replaceDecorationGroup(command, token) {
  const value = validateReplaceDecorations(command, token);
  if (!isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }

  const built = buildDecorationGroup(value, token);
  if (built.status === "stale") {
    return commandResult(token, "cancelled", "staleToken");
  }
  if (built.status === "notFound") {
    return commandResult(token, "miss", "notFound");
  }
  if (built.status !== "ready") {
    return commandResult(token, "miss", "invalidField");
  }

  const prePaintFrame = await nextFrame(token);
  if (prePaintFrame === "timeout") {
    return commandResult(token, "miss", "paintTimeout");
  }
  if (prePaintFrame !== "current" || !isCurrent(token)) {
    return commandResult(token, "cancelled", "staleToken");
  }

  const previous = decorationGroups.get(value.groupID);
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
    const paintFrame = await nextFrame(token);
    if (paintFrame !== "current" || !isCurrent(token)) {
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
  try {
    token = validateToken(tokenValue);
    if (!acceptToken(token)) {
      return commandResult(token, "cancelled", "staleToken");
    }
    if (!isObject(commandValue)) {
      reject("invalidCommand");
    }
    switch (commandValue.kind) {
      case "navigateLocator":
        return await navigateLocator(commandValue, token);
      case "replaceDecorationGroup":
        return await replaceDecorationGroup(commandValue, token);
      default:
        reject("invalidCommand");
    }
  } catch (error) {
    const reasonCode =
      error instanceof CommandRejection ? error.reasonCode : "internalError";
    return commandResult(token ?? null, "miss", reasonCode);
  }
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
    if (!globalThis.getSelection()?.isCollapsed) {
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

Object.defineProperty(globalThis, "readerLocatorCommands", {
  configurable: false,
  enumerable: false,
  writable: false,
  value: Object.freeze({ execute }),
});

try {
  globalThis.webkit?.messageHandlers?.readerLocatorFrameReady?.postMessage({
    href: document.location.href,
  });
} catch (_) {
  // Native frame registration is best-effort. The native registry rejects a
  // command unless it can select exactly one eligible frame for the document.
}
