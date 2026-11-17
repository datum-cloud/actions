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

{
  line = $0
  sub(/\r$/, "", line)
}

line ~ /^[ \t]*(#|$)/ {
  next
}

line ~ /^[^ \t]/ {
  head = line
  sub(/:[ \t]*$/, "", head)
  count = split(head, descriptors, ",")
  entry = ""
  for (i = 1; i <= count; i++) {
    d = strip(descriptors[i])
    at = at_index(d)
    if (at == 0) continue
    if (entry == "") entry = substr(d, 1, at - 1)
    emit(substr(d, 1, at - 1), substr(d, at + 1))
  }
  next
}

line ~ /^  resolved / {
  value = line
  sub(/^  resolved +/, "", value)
  emit(entry, strip(value))
}
