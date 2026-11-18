function strip(s) {
  gsub(/^[ \t]+/, "", s)
  gsub(/[ \t]+$/, "", s)
  if (length(s) >= 2) {
    if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") || (substr(s, 1, 1) == "'" && substr(s, length(s), 1) == "'")) {
      s = substr(s, 2, length(s) - 2)
    }
  }
  return s
}

function clean(s) {
  gsub(/[^ -~]/, "?", s)
  return s
}

function decode(s,   out, i, h, c) {
  out = ""
  while ((i = index(s, "%")) > 0) {
    h = toupper(substr(s, i + 1, 2))
    c = ""
    if (h == "3A") c = ":"
    else if (h == "2F") c = "/"
    else if (h == "40") c = "@"
    else if (h == "23") c = "#"
    else if (h == "3D") c = "="
    else if (h == "26") c = "&"
    else if (h == "2E") c = "."
    else if (h == "5C") c = "\\"
    else if (h == "25") c = "%"
    else if (h == "7E") c = "~"
    else if (h == "21") c = "!"
    else if (h == "3C") c = "<"
    else if (h == "3E") c = ">"
    if (c == "") {
      out = out substr(s, 1, i)
      s = substr(s, i + 1)
    } else {
      out = out substr(s, 1, i - 1) c
      s = substr(s, i + 3)
    }
  }
  return out s
}

function approved(s,   i) {
  for (i = 1; i <= nreg; i++) {
    if (index(s, reg[i]) == 1) return 1
  }
  return 0
}

function walk(path,   n, parts, i, seg) {
  n = split(path, parts, "/")
  for (i = 1; i <= n; i++) {
    seg = parts[i]
    if (seg == "" || seg == ".") continue
    if (seg == "..") {
      if (wtop == 0) return 0
      wtop--
    } else {
      wtop++
      wstack[wtop] = seg
    }
  }
  return 1
}

function path_reason(root, p) {
  p = decode(p)
  gsub(/\\/, "/", p)
  if (p == "") return "empty path"
  if (substr(p, 1, 1) == "/") return "absolute path"
  if (substr(p, 1, 1) == "~") return "home directory path"
  if (index(p, ":") > 0) return "path with a scheme or drive"
  wtop = 0
  if (!walk(root)) return "path outside the repository"
  if (!walk(p)) return "path outside the repository"
  return ""
}

function range_of(x,   i) {
  i = index(substr(x, 2), "@")
  if (i == 0) return x
  return substr(x, i + 2)
}

function patch_reason(rest, root,   hash, inner, paths, cut, np, parr, i, pth, r) {
  hash = index(rest, "#")
  if (hash == 0) {
    inner = rest
    paths = ""
  } else {
    inner = substr(rest, 1, hash - 1)
    paths = substr(rest, hash + 1)
  }
  cut = index(paths, "::")
  if (cut > 0) paths = substr(paths, 1, cut - 1)
  cut = index(inner, "::")
  if (cut > 0) inner = substr(inner, 1, cut - 1)
  inner = decode(inner)
  r = verdict(range_of(inner), root)
  if (r != "") return "patched source: " r
  np = split(paths, parr, "&")
  for (i = 1; i <= np; i++) {
    pth = parr[i]
    if (pth == "") continue
    sub(/^optional!/, "", pth)
    if (index(pth, "builtin<") == 1) continue
    if (index(pth, "~/") == 1) r = path_reason(".", substr(pth, 3))
    else r = path_reason(root, pth)
    if (r != "") return "patch file: " r
  }
  return ""
}

function locator_root(params, root,   at, ws, cut) {
  at = index(params, "locator=")
  if (at == 0) return root
  ws = decode(substr(params, at + 8))
  cut = index(ws, "&")
  if (cut > 0) ws = substr(ws, 1, cut - 1)
  at = index(ws, "@workspace:")
  if (at == 0) return root
  return substr(ws, at + 11)
}

function verdict(s, root,   colon, kind, rest, cut, params, au, e, r) {
  s = strip(s)
  if (s == "") return ""
  if (index(s, ":") == 0 && index(s, "/") == 0 && index(s, "\\") == 0) return ""
  if (approved(s)) return ""
  colon = index(s, ":")
  if (colon == 0) {
    if (index(s, "./") == 1 || index(s, "../") == 1 || substr(s, 1, 1) == "/" || index(s, "~/") == 1) return path_reason(root, s)
    return "git shorthand or unrecognised source"
  }
  kind = tolower(substr(s, 1, colon - 1))
  rest = substr(s, colon + 1)
  if (kind == "npm") {
    params = ""
    cut = index(rest, "::")
    if (cut > 0) {
      params = substr(rest, cut + 2)
      rest = substr(rest, 1, cut - 1)
    }
    if (index(rest, ":") > 0) return "unexpected source inside npm: alias"
    au = index(params, "__archiveUrl=")
    if (au > 0) {
      e = decode(substr(params, au + 13))
      cut = index(e, "&")
      if (cut > 0) e = substr(e, 1, cut - 1)
      if (!approved(e)) return "archive URL outside approved registries"
    }
    return ""
  }
  if (kind == "workspace" || kind == "link" || kind == "portal" || kind == "file") {
    cut = index(rest, "::")
    if (cut > 0) {
      params = substr(rest, cut + 2)
      rest = substr(rest, 1, cut - 1)
      root = locator_root(params, root)
    }
    cut = index(rest, "#")
    if (cut > 0) rest = substr(rest, 1, cut - 1)
    return path_reason(root, rest)
  }
  if (kind == "patch") return patch_reason(rest, root)
  if (kind == "https") return "tarball outside approved registries"
  if (kind == "http") return "insecure http source"
  if (index(kind, "git") == 1 || kind == "github" || kind == "gitlab" || kind == "bitbucket" || kind == "gist" || kind == "ssh") return "git source"
  if (kind == "exec") return "exec source"
  return "unrecognised source protocol"
}

BEGIN {
  FS = "\t"
  nreg = split(ENVIRON["LOCKCHECK_REGISTRIES"], reg, " ")
  root = ENVIRON["LOCKCHECK_BASE"]
  label = clean(ENVIRON["LOCKCHECK_LABEL"])
  records = 0
  bad = 0
}

{
  name = clean($1)
  src = clean($2)
  records++
  key = name SUBSEP src
  if (key in seen) next
  seen[key] = 1
  reason = verdict($2, root)
  if (reason != "") {
    bad++
    printf "FAIL %s: %s %s (%s)\n", label, name, src, reason
  }
}

END {
  if (records == 0) {
    printf "ERROR %s: no records parsed\n", label
    exit 2
  }
  if (bad > 0) exit 1
}
