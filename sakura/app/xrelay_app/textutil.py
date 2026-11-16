"""Text helpers for normalize.py: UTF-16 lengths and X's HTML escaping (stdlib only)."""

import html
import re


_TAG = re.compile(r"<[^>]*>")


def utf16_len(text):
    """Length in UTF-16 code units, the unit of api-v2 offsets (NSString/NSRange)."""
    # Emoji and other characters outside the BMP count twice, as they do in the app.
    # surrogatepass keeps a lone surrogate from JSON from raising here.
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


def decode_escapes(text):
    """Undo X's escaping of tweet text; &amp; goes last so "&amp;lt;" becomes "&lt;"."""
    return text.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")


def strip_tags(markup):
    """Visible text of a small HTML fragment, such as the "source" anchor."""
    return html.unescape(_TAG.sub("", markup)).strip()
