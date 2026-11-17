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

function emit(name, source) {
  printf "%s\t%s\n", name, source
}

function parse_kv(t,   q, e, rest) {
  K = ""
  V = ""
  q = substr(t, 1, 1)
  if (q == "-") return 0
  if (q == "'" || q == "\"") {
    e = index(substr(t, 2), q)
    if (e == 0) return 0
    K = substr(t, 2, e - 1)
    rest = substr(t, e + 2)
    if (substr(rest, 1, 1) != ":") return 0
    V = strip(substr(rest, 2))
    return 1
  }
  e = index(t, ": ")
  if (e > 0) {
    K = substr(t, 1, e - 1)
    V = strip(substr(t, e + 2))
    return 1
  }
  if (substr(t, length(t), 1) == ":") {
    K = substr(t, 1, length(t) - 1)
    return 1
  }
  return 0
}

function flowval(s, key,   pat, rest, cut) {
  pat = "[{ ,]" key ": *"
  if (!match(s, pat)) return ""
  rest = substr(s, RSTART + RLENGTH)
  cut = index(rest, ",")
  if (cut > 0) rest = substr(rest, 1, cut - 1)
  cut = index(rest, "}")
  if (cut > 0) rest = substr(rest, 1, cut - 1)
  return strip(rest)
}

function anchor(v,   p, rest, lead) {
  if (section != "importers" || importer == "" || importer == ".") return v
  p = index(v, ":")
  if (p == 0) return v
  lead = substr(v, 1, p - 1)
  if (lead != "link" && lead != "file") return v
  rest = substr(v, p + 1)
  if (substr(rest, 1, 1) == "/" || substr(rest, 1, 1) == "~") return v
  return lead ":" importer "/" rest
}

function dep_value(v,   p) {
  if (substr(v, 1, 1) == "/") return ""
  p = index(v, "(")
  if (p > 0) v = substr(v, 1, p - 1)
  return v
}

function resolution_flow(name, v,   tarball, repo, dir, type) {
  tarball = flowval(v, "tarball")
  repo = flowval(v, "repo")
  dir = flowval(v, "directory")
  type = flowval(v, "type")
  if (tarball != "") emit(name, tarball)
  if (repo != "") emit(name, "git+" repo)
  if (dir != "") emit(name, "file:" dir)
  if (type == "git" && repo == "") emit(name, "git:")
  if (type != "" && type != "git" && type != "directory") emit(name, "resolution-type:" type)
  if (tarball == "" && repo == "" && dir == "" && type == "") emit(name, "")
}

{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^[ \t]*(#|$)/) next
  match(line, /^ */)
  ind = RLENGTH
  if (!parse_kv(substr(line, ind + 1))) next
  while (n > 0 && sind[n] >= ind) n--
  parent = (n > 0) ? skey[n] : ""
  grand = (n > 1) ? skey[n - 1] : ""
  if (V == "") {
    n++
    sind[n] = ind
    skey[n] = K
  }
  if (ind == 0) {
    section = K
    importer = ""
  }
  if (section == "importers" && ind == 2 && V == "") importer = K

  if (K == "resolution") {
    if (V == "") emit(parent, "")
    else resolution_flow(parent, V)
  } else if (parent == "resolution") {
    if (K == "tarball") emit(grand, V)
    else if (K == "repo") emit(grand, "git+" V)
    else if (K == "directory") emit(grand, "file:" V)
    else if (K == "type" && V == "git") emit(grand, "git:")
    else if (K == "type" && V != "directory") emit(grand, "resolution-type:" V)
  } else if (K == "version" && V != "") {
    emit(parent, dep_value(anchor(V)))
  } else if ((parent == "dependencies" || parent == "devDependencies" || parent == "optionalDependencies") && V != "") {
    emit(K, dep_value(anchor(V)))
  }
}
