# The block extractor the credential-free harnesses share, so what they run is
# the text a skill's callers paste rather than a copy of it.

# section <file> <heading title> -> the first bash block under that heading, at any level.
section() {
  awk -v title="$2" '
    /^#/ {
      h = $0; sub(/^#+[ \t]+/, "", h)
      if (insec) exit
      if (h == title) insec = 1
      next
    }
    insec && /^```bash/ { inblk = 1; next }
    inblk && /^```/ { exit }
    inblk { print }
  ' "$1"
}
