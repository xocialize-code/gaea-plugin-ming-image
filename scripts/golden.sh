#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded jobs called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through ming-inproc with the
# lane configuration and request the worker builds, on this package's dependency resolution. Each pair must be byte
# for byte the same, or pixel for pixel when the bytes differ.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh and `swift build -c release --product ming-inproc`)
#
# Cases: int8 (the default lane) at 1024², int8 at 1280×720 (a bucket size), int8 at 768×512 (drawn at the 1024² bucket's
# 1248×832), and int4 at 1024².
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/ming-image.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
BIN=$(xcrun swift build -c release --show-bin-path)
CHECK=$BIN/gaea-plugin-check; INPROC=$BIN/ming-inproc
PIXDIFF=$OUT/pixdiff; swiftc -O -o $PIXDIFF $ROOT/scripts/pixdiff.swift
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# Ming-Image golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"

# compare <name> <lane> <width> <height>
compare() {
  local name=$1 lane=$2 w=$3 h=$4
  $CHECK $B --operation image.generate --model ming-image --lane $lane --params '{"size":{"width":'$w',"height":'$h'}}' --seed 7 \
    --text "prompt=$PROMPT" --models-root "$MODELS" --budget 64000000000 --timeout 1800 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(grep -o '"path":"[^"]*"' $OUT/$name-gpp.log | tail -1 | sed 's/"path":"//; s/"$//; s/\\\//\//g')
  [[ -n $file && -f $file ]] && cp $file $OUT/$name-gpp.png
  $INPROC --lane $lane --prompt "$PROMPT" --width $w --height $h --seed 7 --models-root "$MODELS" --out $OUT/$name-inproc.png \
    > $OUT/$name-inproc.json 2>> $LOG
  if [[ ! -f $OUT/$name-gpp.png ]]; then fail=$((fail+1)); say "FAIL  $name: no output over GPP ($(grep -E 'FAIL|error' $OUT/$name-gpp.log | tail -1))"; return; fi
  if [[ ! -f $OUT/$name-inproc.png ]]; then fail=$((fail+1)); say "FAIL  $name: no in-process output"; return; fi
  local a=$(shasum -a 256 $OUT/$name-gpp.png | cut -c1-16) b=$(shasum -a 256 $OUT/$name-inproc.png | cut -c1-16)
  local ran=$(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1)
  local effective=$(grep -o '"effective":{[^}]*}[^}]*}' $OUT/$name-gpp.log | head -1)
  if [[ $a == $b ]]; then pass=$((pass+1)); say "PASS  $name ($lane ${w}×$h): byte-identical, sha256 $a…; over GPP $ran, $effective; in-process $(cat $OUT/$name-inproc.json)"
  elif $PIXDIFF $OUT/$name-gpp.png $OUT/$name-inproc.png >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  $name: pixel-identical (bytes $a… / $b…)"
  else fail=$((fail+1)); say "FAIL  $name: differs ($a… / $b…): $(tail -1 $LOG)"; fi
}

PROMPT='a minimalist poster for a jazz festival, deep blue background, a gold saxophone, the words "BLUE NOTE NIGHTS" in bold white type at the top'
compare square int8 1024 1024
compare wide int8 1280 720
compare snapped int8 768 512
compare int4 int4 1024 1024

say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
