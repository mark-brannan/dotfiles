{ out = ""; s = $0
  while ((j = index(s, old)) > 0) { out = out substr(s, 1, j - 1) new; s = substr(s, j + length(old)) }
  print out s }
