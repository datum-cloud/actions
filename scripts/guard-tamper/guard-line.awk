function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
{ t[NR] = $0 }
END {
  g = "^[[:space:]]*(} else )?(if|case|default|switch|select|for)([[:space:]]|:|$)"
  if (t[L] ~ g) { print L; exit }
  want = indent(t[L])
  for (k = L - 1; k >= 1; k--) {
    if (t[k] ~ /^[[:space:]]*$/) continue
    if (indent(t[k]) < want) { print k; exit }
  }
  print L
}
