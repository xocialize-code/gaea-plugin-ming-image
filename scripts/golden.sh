#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded jobs called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through ming-inproc with the
# lane configuration and request the worker builds, on this package's dependency resolution. Each pair must be byte
# for byte the same, or pixel for pixel when the bytes differ.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh and `swift build -c release --product ming-inproc`)
#
# Cases: int8 (the default lane) at 1024², int8 at 1280×720 (a bucket size), int8 at 768×512 (drawn at the 1024² bucket's
# 1248×832), int4 at 1024², and x-ming.background: transparent at 1024² and 1280×720, on a glass subject, and on a
# full-bleed scene (which comes back opaque). A transparent case also checks the worker warns background_opaque exactly
# when the in-process image has no alpha.
#
# Decompose cases (ming-image-layer): the 1024² poster into 4 layers at 1024 and at 512 (draft) on int8 and at 512 on
# int4, with a 3-layer plan, and the 1280×720 poster at its aspect; every layer and the composite compared file by file.
# A decompose takes minutes (about 6 at 1024, 2 at 512), so the in-process side runs once.
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

# compare <name> <lane> <width> <height> [opaque|transparent]
compare() {
  local name=$1 lane=$2 w=$3 h=$4 bg=${5:-opaque}
  $CHECK $B --operation image.generate --model ming-image --lane $lane --params '{"size":{"width":'$w',"height":'$h'}}' --seed 7 \
    --model-params '{"x-ming.background":"'$bg'"}' \
    --text "prompt=$PROMPT" --models-root "$MODELS" --budget 64000000000 --timeout 1800 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(grep -o '"path":"[^"]*"' $OUT/$name-gpp.log | tail -1 | sed 's/"path":"//; s/"$//; s/\\\//\//g')
  [[ -n $file && -f $file ]] && cp $file $OUT/$name-gpp.png
  $INPROC --lane $lane --prompt "$PROMPT" --width $w --height $h --seed 7 --background $bg --models-root "$MODELS" \
    --out $OUT/$name-inproc.png 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  if [[ ! -f $OUT/$name-gpp.png ]]; then fail=$((fail+1)); say "FAIL  $name: no output over GPP ($(grep -E 'FAIL|error' $OUT/$name-gpp.log | tail -1))"; return; fi
  if [[ ! -f $OUT/$name-inproc.png ]]; then fail=$((fail+1)); say "FAIL  $name: no in-process output"; return; fi
  local a=$(shasum -a 256 $OUT/$name-gpp.png | cut -c1-16) b=$(shasum -a 256 $OUT/$name-inproc.png | cut -c1-16)
  local ran=$(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1)
  if [[ $bg == transparent ]]; then
    local alpha=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['transparent'])" $OUT/$name-inproc.json)
    local warned=False; grep -q background_opaque $OUT/$name-gpp.log && warned=True
    if [[ $alpha == $warned ]]; then fail=$((fail+1)); say "FAIL  $name: in-process alpha $alpha, worker warned background_opaque $warned"; return; fi
    say "      $name: native alpha $alpha, background_opaque warned $warned"
  fi
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

PROMPT='a cute cartoon fox mascot sticker with a thick white outline, the word "FOXY" below it, isolated'
compare alpha-square int8 1024 1024 transparent
compare alpha-wide int8 1280 720 transparent
PROMPT='a clear glass perfume bottle with a silver cap, product shot'
compare alpha-glass int8 1024 1024 transparent
PROMPT='a full-bleed landscape photograph of a mountain lake at sunrise, the scene filling the whole frame edge to edge'
compare alpha-scene int8 1024 1024 transparent

# layers <name> <lane> <fixture> <layer_count|-> <resolution> [plan]: every layer and the composite, over GPP and in-process.
layers() {
  local name=$1 lane=$2 fixture=$3 count=$4 res=$5 plan=${6:-}
  local params='{"outputs":["layers","composite"],"resolution":'$res
  [[ $count != - ]] && params+=',"layer_count":'$count
  params+='}'
  local text=(); [[ -n $plan ]] && text=(--text "prompt=$plan")
  $CHECK $B --operation image.decompose --model ming-image-layer --lane $lane --input image=$ROOT/fixtures/$fixture \
    --params "$params" --seed 7 $text --models-root "$MODELS" --budget 64000000000 --timeout 1800 --session $OUT/$name.gpp \
    > $OUT/$name-gpp.log 2>&1
  mkdir -p $OUT/$name-gpp $OUT/$name-inproc
  for f in $(grep -o '"path":"[^"]*"' $OUT/$name-gpp.log | sed 's/"path":"//; s/"$//; s/\\\//\//g' | sort -u); do cp $f $OUT/$name-gpp/; done
  local args=(--decompose $ROOT/fixtures/$fixture --lane $lane --resolution $res --seed 7 --once --models-root "$MODELS" --out-dir $OUT/$name-inproc)
  [[ $count != - ]] && args+=(--layers $count)
  [[ -n $plan ]] && args+=(--plan "$plan")
  $INPROC $args 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  local files=($OUT/$name-inproc/*.png(N:t)) bad=0 note=""
  if (( ${#files} == 0 )) || [[ ! -f $OUT/$name-gpp/composite-0.png ]]; then
    fail=$((fail+1)); say "FAIL  $name: missing outputs ($(ls $OUT/$name-gpp | tr '\n' ' ') / $(ls $OUT/$name-inproc | tr '\n' ' '))"; return
  fi
  [[ $(ls $OUT/$name-gpp | wc -l) -eq ${#files} ]] || { bad=1; note="file counts differ"; }
  for f in $files; do
    if ! cmp -s $OUT/$name-gpp/$f $OUT/$name-inproc/$f && ! $PIXDIFF $OUT/$name-gpp/$f $OUT/$name-inproc/$f >> $LOG 2>&1; then bad=1; note+=" $f differs"; fi
  done
  local effective=$(grep -o '"effective":{[^}]*}[^}]*}' $OUT/$name-gpp.log | head -1)
  if (( bad )); then fail=$((fail+1)); say "FAIL  $name: $note"
  else pass=$((pass+1)); say "PASS  $name ($lane, $fixture, layer_count $count, $res): ${#files} files byte- or pixel-identical; over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1), $effective; in-process $(cat $OUT/$name-inproc.json)"; fi
}

layers decompose-4 int8 poster-1024.png 4 1024
layers decompose-int4 int4 poster-1024.png 4 512
layers decompose-plan int8 poster-1024.png - 1024 'Decompose this image into 3 layers. Layer 1: the words "BLUE NOTE NIGHTS". Layer 2: the gold saxophone. Layer 3: the deep blue background.'
layers decompose-draft int8 poster-1024.png 4 512
layers decompose-wide int8 poster-1280x720.png 4 1024

say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
