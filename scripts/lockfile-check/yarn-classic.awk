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

function at_index(x,   i) {
  i = index(substr(x, 2), "@")
  if (i == 0) return 0
  return i + 1
}

function finish() {
  if (entry_open && resolved == 0 && !local_only) {
    emit(entry, "resolution:missing")
  }
}

{
  line = $0
  sub(/\r$/, "", line)
}

line ~ /^[ \t]*(#|$)/ {
  next
}

line ~ /^[^ \t]/ {
  finish()
  entry_open = 1
  headers++
  header = line
  resolved = 0
  local_only = 1
  head = line
  sub(/:[ \t]*$/, "", head)
  count = split(head, descriptors, ",")
  entry = ""
  for (i = 1; i <= count; i++) {
    d = strip(descriptors[i])
    at = at_index(d)
    if (at == 0) continue
    if (entry == "") entry = substr(d, 1, at - 1)
    source = substr(d, at + 1)
    if (source !~ /^(link|file):/) local_only = 0
    emit(substr(d, 1, at - 1), source)
  }
  next
}

line ~ /^  resolved / {
  value = line
  sub(/^  resolved +/, "", value)
  resolved++
  seen_resolved++
  if (resolved > 1) {
    printf "entry %s has more than one resolved line\n", header > "/dev/stderr"
    bad = 1
  }
  emit(entry, strip(value))
  next
}

line ~ /^  [^ \t]/ {
  in_block = (line ~ /:[ \t]*$/)
}

line ~ /^[ \t]+"?resolved"?[ \t:]/ && !(in_block && line ~ /^    [^ \t]/) {
  printf "entry %s has a resolved line the check can't read\n", header > "/dev/stderr"
  bad = 1
}

END {
  finish()
  if (bad) exit 1
}
