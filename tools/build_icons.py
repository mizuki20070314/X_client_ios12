#!/usr/bin/env python3
"""Build the app's icon data from tools/icons (Lucide SVGs plus our own shapes).

Reads tools/icons/icons.json and the SVG files in tools/icons/svg/. Every drawable
element becomes absolute M/L/C/Z path data (quadratics and arcs become cubics), so
the Swift side needs only a tiny parser. Writes:
  ios/XRelayClient/UI/Foundation/IconData.swift  (committed, generated)
  tools/icons/preview.html                        (local check only, do not commit)
Standard library only.
"""

import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICONS_DIR = ROOT / "tools" / "icons"
SVG_DIR = ICONS_DIR / "svg"
SPEC_PATH = ICONS_DIR / "icons.json"
SWIFT_PATH = ROOT / "ios" / "XRelayClient" / "UI" / "Foundation" / "IconData.swift"
PREVIEW_PATH = ICONS_DIR / "preview.html"

# The names of docs/ios-design.md section 5.2. icons.json must define exactly these.
EXPECTED_NAMES = [
    "home", "homeFill", "search", "searchBold", "bell", "bellFill", "message", "messageFill",
    "reply", "repost", "heart", "heartFill", "views", "bookmark", "bookmarkFill", "share",
    "overflow", "more", "verified", "logo", "plus", "close", "back", "chevronRight",
    "chevronDown", "settings", "person", "personFill", "userPlus", "userMinus", "history",
    "pin", "lock", "link", "mapPin", "calendar", "mail", "image", "trash", "volumeOff", "ban",
    "flag", "copy", "external", "sun", "moon", "pencil", "play", "refresh", "check", "star",
    "alert", "info", "trending", "at", "send",
]
MODES = ["stroke", "fill", "fillAndStroke", "clearStroke", "clearFill"]
SHAPE_TAGS = {"path", "line", "polyline", "polygon", "circle", "ellipse", "rect"}
# Attributes that would change the drawing and that we do not support: fail loudly.
ALLOWED_SVG_ATTRIBUTES = {
    "d", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "x2", "y1", "y2",
    "width", "height", "points", "id", "class", "fill", "stroke",
}

SEPARATORS = " \t\r\n,"
NUMBER = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
PATH_COMMANDS = "MmLlHhVvCcSsQqTtAaZz"
ARGUMENT_COUNT = {"M": 2, "L": 2, "T": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "A": 7}


# ---------------------------------------------------------------- path data

class PathScanner:
    """Reads SVG path data left to right. Arc flags are single characters."""

    def __init__(self, text):
        self.text = text
        self.pos = 0

    def skip_separators(self):
        while self.pos < len(self.text) and self.text[self.pos] in SEPARATORS:
            self.pos += 1

    def at_end(self):
        self.skip_separators()
        return self.pos >= len(self.text)

    def number(self):
        self.skip_separators()
        match = NUMBER.match(self.text, self.pos)
        if match is None:
            raise ValueError(f"expected a number at {self.pos} in path data {self.text!r}")
        self.pos = match.end()
        return float(match.group(0))

    def flag(self):
        # "a1 1 0 011 1" is legal: the flags are "0" and "1" with no separator.
        self.skip_separators()
        char = self.text[self.pos:self.pos + 1]
        if char not in ("0", "1"):
            raise ValueError(f"expected an arc flag at {self.pos} in path data {self.text!r}")
        self.pos += 1
        return float(char)


def parse_path_data(text):
    """Return [(command, [numbers])] with implicit repetitions made explicit."""
    scanner = PathScanner(text)
    segments = []
    command = None
    while not scanner.at_end():
        char = scanner.text[scanner.pos]
        if char in PATH_COMMANDS:
            scanner.pos += 1
            command = char
            if command in "Zz":
                segments.append((command, []))
                continue
        elif command is None or command in "Zz":
            raise ValueError(f"path data must start with a command: {text!r}")
        args = []
        for index in range(ARGUMENT_COUNT[command.upper()]):
            if command in "Aa" and index in (3, 4):
                args.append(scanner.flag())
            else:
                args.append(scanner.number())
        segments.append((command, args))
        # Pairs after a moveto are linetos (SVG 9.3.2).
        if command == "M":
            command = "L"
        elif command == "m":
            command = "l"
    return segments


def quad_to_cubic(x0, y0, qx, qy, x, y):
    """Exact degree elevation of a quadratic segment."""
    return (x0 + 2.0 / 3.0 * (qx - x0), y0 + 2.0 / 3.0 * (qy - y0),
            x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y), x, y)


def _angle(ux, uy, vx, vy):
    length = math.hypot(ux, uy) * math.hypot(vx, vy)
    if length == 0:
        return 0.0
    value = max(-1.0, min(1.0, (ux * vx + uy * vy) / length))
    angle = math.acos(value)
    return -angle if ux * vy - uy * vx < 0 else angle


def arc_to_cubics(x1, y1, rx, ry, angle_deg, large, sweep, x2, y2):
    """SVG endpoint arc to cubic segments (SVG 1.1 F.6.5 and F.6.6).

    Returns [("C", x1, y1, x2, y2, x, y)] pieces of at most 90 degrees, or
    [("L", x, y)] for a zero radius, or [] when both ends coincide.
    """
    if x1 == x2 and y1 == y2:
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        return [("L", x2, y2)]
    phi = math.radians(angle_deg)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2.0, (y1 - y2) / 2.0
    x1p = cos_phi * dx + sin_phi * dy
    y1p = -sin_phi * dx + cos_phi * dy
    lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
    if lam > 1.0:  # radii too small: scale them up (F.6.6.2)
        scale = math.sqrt(lam)
        rx *= scale
        ry *= scale
    rx2, ry2 = rx * rx, ry * ry
    numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
    denominator = rx2 * y1p * y1p + ry2 * x1p * x1p
    factor = math.sqrt(max(0.0, numerator / denominator)) if denominator > 0 else 0.0
    if bool(large) == bool(sweep):
        factor = -factor
    cxp = factor * rx * y1p / ry
    cyp = -factor * ry * x1p / rx
    cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2.0
    cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2.0
    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    theta = _angle(1.0, 0.0, ux, uy)
    delta = _angle(ux, uy, vx, vy)
    if not sweep and delta > 0:
        delta -= 2.0 * math.pi
    elif sweep and delta < 0:
        delta += 2.0 * math.pi

    count = max(1, int(math.ceil(abs(delta) / (math.pi / 2) - 1e-9)))
    step = delta / count
    alpha = 4.0 / 3.0 * math.tan(step / 4.0)

    def point(t):
        return (cx + rx * math.cos(t) * cos_phi - ry * math.sin(t) * sin_phi,
                cy + rx * math.cos(t) * sin_phi + ry * math.sin(t) * cos_phi)

    def tangent(t):
        return (-rx * math.sin(t) * cos_phi - ry * math.cos(t) * sin_phi,
                -rx * math.sin(t) * sin_phi + ry * math.cos(t) * cos_phi)

    pieces = []
    for index in range(count):
        t0 = theta + step * index
        t1 = t0 + step
        p0 = point(t0)
        d0 = tangent(t0)
        d1 = tangent(t1)
        p1 = point(t1) if index < count - 1 else (x2, y2)  # land exactly on the endpoint
        c1 = (p0[0] + alpha * d0[0], p0[1] + alpha * d0[1])
        c2 = (p1[0] - alpha * d1[0], p1[1] - alpha * d1[1])
        pieces.append(("C", c1[0], c1[1], c2[0], c2[1], p1[0], p1[1]))
    return pieces


class Pen:
    """Collects absolute M/L/C/Z operations and tracks the current point."""

    def __init__(self):
        self.ops = []
        self.x = 0.0
        self.y = 0.0
        self.start_x = 0.0
        self.start_y = 0.0
        self.needs_move = False

    def move(self, x, y):
        self.ops.append(("M", x, y))
        self.x, self.y = x, y
        self.start_x, self.start_y = x, y
        self.needs_move = False

    def _begin_segment(self):
        if not self.ops:
            raise ValueError("path data must start with a moveto")
        if self.needs_move:
            # Drawing after Z starts a new subpath at the old start point.
            self.move(self.start_x, self.start_y)

    def line(self, x, y):
        self._begin_segment()
        self.ops.append(("L", x, y))
        self.x, self.y = x, y

    def curve(self, x1, y1, x2, y2, x, y):
        self._begin_segment()
        self.ops.append(("C", x1, y1, x2, y2, x, y))
        self.x, self.y = x, y

    def close(self):
        if self.ops and not self.needs_move:
            self.ops.append(("Z",))
        self.x, self.y = self.start_x, self.start_y
        self.needs_move = True


def to_absolute(segments):
    """Convert parsed segments to absolute M/L/C/Z operations."""
    pen = Pen()
    last_cubic = None  # second control point of the previous C/S, read by S
    last_quad = None   # control point of the previous Q/T, read by T
    for command, args in segments:
        previous_cubic, previous_quad = last_cubic, last_quad
        last_cubic = last_quad = None
        relative = command.islower()
        kind = command.upper()
        base_x = pen.x if relative else 0.0
        base_y = pen.y if relative else 0.0
        if kind == "Z":
            pen.close()
        elif kind == "M":
            pen.move(args[0] + base_x, args[1] + base_y)
        elif kind == "L":
            pen.line(args[0] + base_x, args[1] + base_y)
        elif kind == "H":
            pen.line(args[0] + base_x, pen.y)
        elif kind == "V":
            pen.line(pen.x, args[0] + base_y)
        elif kind == "C":
            x2, y2 = args[2] + base_x, args[3] + base_y
            x, y = args[4] + base_x, args[5] + base_y
            pen.curve(args[0] + base_x, args[1] + base_y, x2, y2, x, y)
            last_cubic = (x2, y2)
        elif kind == "S":
            if previous_cubic is None:
                x1, y1 = pen.x, pen.y
            else:
                x1, y1 = 2.0 * pen.x - previous_cubic[0], 2.0 * pen.y - previous_cubic[1]
            x2, y2 = args[0] + base_x, args[1] + base_y
            x, y = args[2] + base_x, args[3] + base_y
            pen.curve(x1, y1, x2, y2, x, y)
            last_cubic = (x2, y2)
        elif kind == "Q":
            qx, qy = args[0] + base_x, args[1] + base_y
            x, y = args[2] + base_x, args[3] + base_y
            pen.curve(*quad_to_cubic(pen.x, pen.y, qx, qy, x, y))
            last_quad = (qx, qy)
        elif kind == "T":
            if previous_quad is None:
                qx, qy = pen.x, pen.y
            else:
                qx, qy = 2.0 * pen.x - previous_quad[0], 2.0 * pen.y - previous_quad[1]
            x, y = args[0] + base_x, args[1] + base_y
            pen.curve(*quad_to_cubic(pen.x, pen.y, qx, qy, x, y))
            last_quad = (qx, qy)
        elif kind == "A":
            x, y = args[5] + base_x, args[6] + base_y
            for piece in arc_to_cubics(pen.x, pen.y, args[0], args[1], args[2],
                                       args[3], args[4], x, y):
                if piece[0] == "L":
                    pen.line(piece[1], piece[2])
                else:
                    pen.curve(*piece[1:])
        else:
            raise ValueError(f"unsupported command {command!r}")
    return pen.ops


def fmt(value):
    """Three decimals, no trailing zeros, never a negative zero."""
    rounded = round(value, 3)
    if rounded == 0:
        return "0"
    return f"{rounded:.3f}".rstrip("0").rstrip(".")


def ops_to_string(ops):
    tokens = []
    for op in ops:
        if op[0] == "Z":
            tokens.append("Z")
        else:
            tokens.append(op[0] + " " + " ".join(fmt(value) for value in op[1:]))
    return " ".join(tokens)


# ---------------------------------------------------------------- elements

def _r(value):
    """Exact text for numbers handed to the path parser."""
    return repr(float(value))


def _num(tag, attrs, key, default=None):
    if key in attrs:
        return float(attrs[key])
    if default is None:
        raise ValueError(f"<{tag}> is missing {key}")
    return float(default)


def ellipse_d(cx, cy, rx, ry):
    if rx <= 0 or ry <= 0:
        return ""
    # Two half-turn arcs; the arc code makes the cubic pieces.
    return (f"M {_r(cx + rx)} {_r(cy)} A {_r(rx)} {_r(ry)} 0 1 0 {_r(cx - rx)} {_r(cy)} "
            f"A {_r(rx)} {_r(ry)} 0 1 0 {_r(cx + rx)} {_r(cy)} Z")


def rect_d(x, y, w, h, rx, ry):
    if w <= 0 or h <= 0:
        return ""
    # SVG: a missing radius takes the other one, and radii are at most half the sides.
    rx = min(rx, w / 2.0)
    ry = min(ry, h / 2.0)
    if rx <= 0 or ry <= 0:
        return f"M {_r(x)} {_r(y)} H {_r(x + w)} V {_r(y + h)} H {_r(x)} Z"
    return (f"M {_r(x + rx)} {_r(y)} H {_r(x + w - rx)} "
            f"A {_r(rx)} {_r(ry)} 0 0 1 {_r(x + w)} {_r(y + ry)} "
            f"V {_r(y + h - ry)} "
            f"A {_r(rx)} {_r(ry)} 0 0 1 {_r(x + w - rx)} {_r(y + h)} "
            f"H {_r(x + rx)} "
            f"A {_r(rx)} {_r(ry)} 0 0 1 {_r(x)} {_r(y + h - ry)} "
            f"V {_r(y + ry)} "
            f"A {_r(rx)} {_r(ry)} 0 0 1 {_r(x + rx)} {_r(y)} Z")


def element_d(tag, attrs):
    """Path data (any commands) for one element; attrs holds SVG strings or JSON numbers."""
    if tag == "path":
        return str(attrs["d"])
    if tag == "line":
        x1 = _num(tag, attrs, "x1", 0)
        y1 = _num(tag, attrs, "y1", 0)
        x2 = _num(tag, attrs, "x2", 0)
        y2 = _num(tag, attrs, "y2", 0)
        return f"M {_r(x1)} {_r(y1)} L {_r(x2)} {_r(y2)}"
    if tag in ("polyline", "polygon"):
        values = [float(v) for v in NUMBER.findall(str(attrs["points"]))]
        if len(values) < 4 or len(values) % 2:
            raise ValueError(f"<{tag}> needs at least two coordinate pairs")
        pieces = [f"M {_r(values[0])} {_r(values[1])}"]
        for index in range(2, len(values), 2):
            pieces.append(f"L {_r(values[index])} {_r(values[index + 1])}")
        if tag == "polygon":
            pieces.append("Z")
        return " ".join(pieces)
    if tag == "circle":
        cx = _num(tag, attrs, "cx", 0)
        cy = _num(tag, attrs, "cy", 0)
        radius = _num(tag, attrs, "r")
        return ellipse_d(cx, cy, radius, radius)
    if tag == "ellipse":
        cx = _num(tag, attrs, "cx", 0)
        cy = _num(tag, attrs, "cy", 0)
        return ellipse_d(cx, cy, _num(tag, attrs, "rx"), _num(tag, attrs, "ry"))
    if tag == "rect":
        x = _num(tag, attrs, "x", 0)
        y = _num(tag, attrs, "y", 0)
        w = _num(tag, attrs, "width")
        h = _num(tag, attrs, "height")
        rx_text = attrs.get("rx")
        ry_text = attrs.get("ry")
        if rx_text is not None:
            rx = float(rx_text)
        else:
            rx = float(ry_text) if ry_text is not None else 0.0
        ry = float(ry_text) if ry_text is not None else rx
        return rect_d(x, y, w, h, rx, ry)
    raise ValueError(f"unsupported element <{tag}>")


def element_path(tag, attrs):
    text = element_d(tag, attrs)
    if not text:
        return ""
    return ops_to_string(to_absolute(parse_path_data(text)))


def local_name(tag):
    return tag.rsplit("}", 1)[-1]


def svg_elements(path):
    """Drawable elements of one Lucide file, in document order."""
    root = ET.parse(path).getroot()
    if local_name(root.tag) != "svg":
        raise ValueError(f"{path.name}: root is not <svg>")
    if root.get("viewBox") != "0 0 24 24":
        raise ValueError(f"{path.name}: viewBox must be 0 0 24 24")
    # We draw with our own stroke width and caps; refuse a file that expects others.
    for attr, expected in (("stroke-width", "2"), ("stroke-linecap", "round"),
                           ("stroke-linejoin", "round")):
        value = root.get(attr)
        if value is not None and value != expected:
            raise ValueError(f"{path.name}: root {attr}={value!r}, expected {expected!r}")
    elements = []

    def walk(node):
        for child in node:
            tag = local_name(child.tag)
            if tag == "g":
                if "transform" in child.attrib:
                    raise ValueError(f"{path.name}: transform on <g> is not supported")
                walk(child)
            elif tag in SHAPE_TAGS:
                for key in child.attrib:
                    if key not in ALLOWED_SVG_ATTRIBUTES:
                        raise ValueError(f"{path.name}: attribute {key!r} on <{tag}> is not supported")
                for key in ("fill", "stroke"):
                    if child.get(key) not in (None, "none", "currentColor"):
                        raise ValueError(f"{path.name}: {key} on <{tag}> is not supported")
                elements.append((tag, dict(child.attrib)))
            elif tag not in ("title", "desc", "metadata"):
                raise ValueError(f"{path.name}: unsupported element <{tag}>")

    walk(root)
    return elements


# ---------------------------------------------------------------- icons

def load_spec():
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    icons = []
    for name, value in data.items():
        if name.startswith("_"):  # documentation key
            continue
        if isinstance(value, list):
            layers, stroke_width, source = value, None, None
        else:
            layers = value["layers"]
            stroke_width = value.get("strokeWidth")
            source = value.get("source")
        if stroke_width is not None:
            stroke_width = float(stroke_width)
        icons.append({"name": name, "layers": layers, "strokeWidth": stroke_width, "source": source})
    names = [icon["name"] for icon in icons]
    missing = sorted(set(EXPECTED_NAMES) - set(names))
    extra = sorted(set(names) - set(EXPECTED_NAMES))
    if missing or extra or len(names) != len(set(names)):
        raise ValueError(f"icon names differ from docs/ios-design.md: missing={missing} extra={extra}")
    return icons


def convert_layers(icon):
    """[(absolute path data, mode, source_label)] for one icon."""
    name = icon["name"]
    converted = []
    for layer in icon["layers"]:
        mode = layer.get("mode")
        if mode not in MODES:
            raise ValueError(f"{name}: unknown mode {mode!r}")
        sources = [key for key in ("svg", "d", "shapes") if key in layer]
        if len(sources) != 1:
            raise ValueError(f"{name}: a layer needs exactly one of svg, d, shapes")
        if "svg" in layer:
            elements = svg_elements(SVG_DIR / layer["svg"])
            label = layer["svg"]
        elif "d" in layer:
            elements = [("path", {"d": layer["d"]})]
            label = "d"
        else:
            elements = [(shape["type"], shape) for shape in layer["shapes"]]
            label = "shapes"
        pieces = [element_path(tag, attrs) for tag, attrs in elements]
        path = " ".join(piece for piece in pieces if piece)
        if not path:
            raise ValueError(f"{name}: a layer has no drawable data")
        converted.append((path, mode, label))
    return converted


# ---------------------------------------------------------------- output

def swift_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def swift_float(value):
    return repr(float(value))  # "2.75", "3.0": always a float literal


def swift_source(icons):
    names = [icon["name"] for icon in icons]
    lines = [
        "// Generated by tools/build_icons.py — do not edit.",
        "import CoreGraphics",
        "",
        "enum IconLayerMode { case stroke, fill, fillAndStroke, clearStroke, clearFill }",
        "struct IconLayer { let path: String; let mode: IconLayerMode }",
        "struct IconDefinition { let layers: [IconLayer]; let strokeWidth: CGFloat? }",
        "",
        "enum IconName: String, CaseIterable {",
    ]
    chunks = [names[i:i + 6] for i in range(0, len(names), 6)]
    for index, chunk in enumerate(chunks):
        last = index == len(chunks) - 1
        prefix = "    case " if index == 0 else "        "
        lines.append(prefix + ", ".join(chunk) + ("" if last else ","))
    lines += [
        "}",
        "",
        "enum IconData {",
        "    static func definition(for name: IconName) -> IconDefinition {",
        "        switch name {",
    ]
    for icon in icons:
        lines.append(f"        case .{icon['name']}:")
        lines.append("            return IconDefinition(layers: [")
        for path, mode, _label in icon["converted"]:
            lines.append(f"                IconLayer(path: {swift_string(path)}, mode: .{mode}),")
        width = "nil" if icon["strokeWidth"] is None else swift_float(icon["strokeWidth"])
        lines.append(f"            ], strokeWidth: {width})")
    lines += ["        }", "    }", "}", ""]
    return "\n".join(lines)


def svg_markup(path):
    text = path.read_text(encoding="utf-8")
    return text[text.index("<svg"):text.rindex("</svg>") + len("</svg>")]


PREVIEW_TEMPLATE = """<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>Icon preview (generated)</title>
<style>
body { margin: 16px; font: 13px sans-serif; background: #fff; color: #111; }
h2 { font-size: 15px; margin: 20px 0 8px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 10px; }
.card { border: 1px solid #ddd; border-radius: 6px; padding: 8px; }
.name { font: 12px monospace; margin-bottom: 6px; }
.pair { display: flex; gap: 10px; align-items: center; }
.orig, .conv { width: 96px; height: 96px; flex: none; }
.orig svg { width: 96px; height: 96px; color: #111; display: block; }
.own { display: flex; align-items: center; justify-content: center; width: 96px; height: 96px;
       box-sizing: border-box; border: 1px dashed #bbb; color: #888; font-size: 11px; text-align: center; }
.caption { font-size: 11px; color: #666; margin-top: 4px; }
.row { display: flex; flex-wrap: wrap; gap: 14px; padding: 12px; align-items: center; }
.row.dark { background: #000; }
</style>
</head>
<body>
<h2>Original (Lucide SVG, left) and converted layers (right), 96 px</h2>
<div class="grid" id="grid"></div>
<h2>24 px on white</h2>
<div class="row" id="white"></div>
<h2>24 px on black</h2>
<div class="row dark" id="black"></div>
<script>
const ICONS = __DATA__;

// Mirrors Icons.swift: clear modes erase what was drawn before them.
function paint(canvas, icon, color) {
  const size = canvas.width;
  const ctx = canvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, size, size);
  const k = size / 24;
  ctx.setTransform(k, 0, 0, k, 0, 0);
  ctx.lineWidth = icon.strokeWidth !== null ? icon.strokeWidth : 2;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  for (const layer of icon.layers) {
    const path = new Path2D(layer.path);
    const mode = layer.mode;
    const fills = mode === 'fill' || mode === 'fillAndStroke' || mode === 'clearFill';
    const strokes = mode === 'stroke' || mode === 'fillAndStroke' || mode === 'clearStroke';
    ctx.globalCompositeOperation = mode.indexOf('clear') === 0 ? 'destination-out' : 'source-over';
    if (fills) ctx.fill(path);
    if (strokes) ctx.stroke(path);
  }
  ctx.globalCompositeOperation = 'source-over';
}

const grid = document.getElementById('grid');
for (const icon of ICONS) {
  const card = document.createElement('div');
  card.className = 'card';
  const name = document.createElement('div');
  name.className = 'name';
  name.textContent = icon.name;
  const pair = document.createElement('div');
  pair.className = 'pair';
  const orig = document.createElement('div');
  if (icon.original) {
    orig.className = 'orig';
    orig.innerHTML = icon.original;
  } else {
    orig.className = 'own';
    orig.textContent = 'own shape: no Lucide original';
  }
  const canvas = document.createElement('canvas');
  canvas.className = 'conv';
  canvas.width = 96;
  canvas.height = 96;
  paint(canvas, icon, '#111');
  pair.append(orig, canvas);
  const caption = document.createElement('div');
  caption.className = 'caption';
  caption.textContent = icon.caption;
  card.append(name, pair, caption);
  grid.append(card);
}

for (const [id, color] of [['white', '#111'], ['black', '#fff']]) {
  const row = document.getElementById(id);
  for (const icon of ICONS) {
    const canvas = document.createElement('canvas');
    canvas.width = 24;
    canvas.height = 24;
    paint(canvas, icon, color);
    row.append(canvas);
  }
}
</script>
</body>
</html>
"""


def preview_html(icons):
    data = []
    for icon in icons:
        svg_files = []
        for layer in icon["layers"]:
            if "svg" in layer and layer["svg"] not in svg_files:
                svg_files.append(layer["svg"])
        if not svg_files and icon["source"]:
            svg_files = [icon["source"]]
        original = "".join(svg_markup(SVG_DIR / name) for name in svg_files) or None
        sources = [label for _path, _mode, label in icon["converted"]]
        caption = " + ".join(dict.fromkeys(sources))
        data.append({
            "name": icon["name"],
            "strokeWidth": icon["strokeWidth"],
            "layers": [{"path": path, "mode": mode} for path, mode, _label in icon["converted"]],
            "original": original,
            "caption": caption,
        })
    payload = json.dumps(data, ensure_ascii=False)
    return PREVIEW_TEMPLATE.replace("__DATA__", payload)


def main():
    icons = load_spec()
    for icon in icons:
        icon["converted"] = convert_layers(icon)
    SWIFT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(SWIFT_PATH, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(swift_source(icons))
    with open(PREVIEW_PATH, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(preview_html(icons))
    layer_count = sum(len(icon["converted"]) for icon in icons)
    print(f"icons: {len(icons)}, layers: {layer_count}")
    print(f"wrote {SWIFT_PATH}")
    print(f"wrote {PREVIEW_PATH}")


if __name__ == "__main__":
    main()
