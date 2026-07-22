// Copyright 2026 Readium Foundation. All rights reserved.
// Use of this source code is governed by the BSD-style license
// available in the top-level LICENSE file of the project.

import { TextQuoteAnchor } from "./vendor/hypothesis/anchoring/types";

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
const OPERATION_KINDS = new Set(["navigation", "decoration"]);

const utf8Encoder = new TextEncoder();
const requestFrame = globalThis.requestAnimationFrame.bind(globalThis);
const scheduleTimeout = globalThis.setTimeout.bind(globalThis);
const cancelTimeout = globalThis.clearTimeout.bind(globalThis);
const FRAME_DEADLINE_MILLISECONDS = 250;
const latestSequences = new Map();
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

async function execute(commandValue, tokenValue) {
  let token;
  try {
    token = validateToken(tokenValue);
    if (!acceptToken(token)) {
      return commandResult(token, "cancelled", "staleToken");
    }
    if (!isObject(commandValue) || commandValue.kind !== "navigateLocator") {
      reject("invalidCommand");
    }
    return await navigateLocator(commandValue, token);
  } catch (error) {
    const reasonCode =
      error instanceof CommandRejection ? error.reasonCode : "internalError";
    return commandResult(token ?? null, "miss", reasonCode);
  }
}

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
