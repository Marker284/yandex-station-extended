# Input: an Xray-JSON subscription cut into pieces by `fold -w 256` (any cut points; the scanner keeps
# its state across lines and never adds characters, so cuts inside strings are harmless).
# Prints each object inside a top-level config's "outbounds" array whose tag is "proxy", one per line.
BEGIN { d = 0; ins = 0; esc = 0; str = ""; k2 = ""; inout = 0; cap = 0; buf = "" }
{
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (cap && (ins || c !~ /[ \t\r]/)) buf = buf c
    if (ins) { if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") ins = 0; else if (d == 2) str = str c; continue }
    if (c == "\"") { ins = 1; str = ""; continue }
    if (c == ":" && d == 2) k2 = str
    if (c == "{" || c == "[") { d++; if (d == 3) inout = (c == "[" && k2 == "outbounds"); if (d == 4 && c == "{" && inout) { cap = 1; buf = "{" } continue }
    if (c == "}" || c == "]") { if (d == 4 && cap) { cap = 0; if (buf ~ /"tag":"proxy"/) print buf } if (d == 3) inout = 0; d-- }
  }
}
