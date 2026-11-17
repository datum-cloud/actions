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

{
  line = $0
  sub(/\r$/, "", line)
}

line ~ /^  resolution: / {
  value = line
  sub(/^  resolution: +/, "", value)
  value = strip(value)
  i = index(substr(value, 2), "@")
  if (i == 0) printf "%s\t%s\n", value, value
  else printf "%s\t%s\n", substr(value, 1, i), substr(value, i + 2)
}
