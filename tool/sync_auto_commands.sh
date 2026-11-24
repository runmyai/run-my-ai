#!/usr/bin/env bash
# Writes lib/engine/auto_commands.dart from the engine's model presets, so the app's Auto commands never drift from them.
#
#   tool/sync_auto_commands.sh [--check] [FILE]
#
# For each model and each kind of machine (the presets' cases: 1 a large GPU, 2 a small GPU, 3 CPU-only) and every size in
# its PRESET_SIZES it takes the command `preset_command <size>` prints and keeps what the app stores: the environment settings first, then the engine's flags. The presets'
# memory-cap wrapper (systemd-run, for our own runs) is left out: the app runs the engine without a cap. The app supplies the
# rest itself when it starts the engine: the program, the model file (-m), the address and the port. A data file kept next to
# a model (Qwen's correction file and VRAM list, Inkling's vision projector and VRAM list) is written as {models}/<file>: the app puts its models folder there.
#
# --check writes nothing: it exits 1 and shows the difference when FILE (default: lib/engine/auto_commands.dart) is not
# what the presets give. A preset that uses something the app cannot store makes the script stop and say which.
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app=$(dirname "$here")
presets=${PRESETS_DIR:-$(dirname "$app")/presets}

check=0
target=$app/lib/engine/auto_commands.dart
for arg in "$@"; do
    case "$arg" in
        --check) check=1 ;;
        -*) echo "usage: $0 [--check] [FILE]" >&2; exit 2 ;;
        *) target=$arg ;;
    esac
done

die () { echo "sync_auto_commands: $*" >&2; exit 1; }

# The flags the app sets itself, and the settings it refuses (_suppliedByApp and _unsafeSetting in lib/engine/commands.dart).
supplied=" -m --model -mu --model-url -hf -hfr --hf-repo --host --port --cache-disk --cache-disk-gb --cache-disk-checkpoints "
unsafe='^(LD_|DYLD_|PATH=)'

# The words of a preset's command for one size, with a placeholder where the preset puts the folder it lives in.
preset_words () {   # preset file, size, case
    (
        unset KEEP_FREE PRESET_MEMCAP PRESET_BIN FLINT_CASE LING_CASE QWEN_CASE QWEN_QUANT QWEN_CORR QWEN_GS INKLING_CASE
        export ROOT=/__root__ FLINT_CASE=$3 LING_CASE=$3 QWEN_CASE=$3 INKLING_CASE=$3
        # shellcheck disable=SC1090
        source "$1"
        preset_command "$2"
    )
}

preset_sizes () {   # preset file
    ( unset FLINT_CASE INKLING_CASE; source "$1"; echo "$PRESET_SIZES" )
}

# The app's form of one command: environment settings, then flags. Prints the context length, a tab, the command.
app_command () {   # preset file, size, case
    local file=$1 size=$2 command
    command=$(preset_words "$file" "$size" "$3") || die "$file: preset_command $size (case $3) failed"
    case "$command" in *\'* | *\"*) die "$file $size: the command has a quote; the app splits flags at spaces and quotes" ;; esac
    local -a words
    read -ra words <<< "$command"
    local i=0 n=${#words[@]}
    if [ "${words[0]}" = systemd-run ]; then
        while [ "$i" -lt "$n" ] && [ "${words[i]}" != -- ]; do i=$((i + 1)); done
        [ "$i" -lt "$n" ] || die "$file $size: no -- after systemd-run"
        i=$((i + 1))
        local wrapper="${words[*]:0:i}"
        [[ $wrapper == "systemd-run --user --scope -q -p MemoryMax="*"K -p MemorySwapMax=0 --" ]] ||
            die "$file $size: the memory-cap wrapper is not the one this script knows ($wrapper)"
    fi
    [ "${words[i]:-}" = env ] && i=$((i + 1))
    local -a settings=() flags=()
    local no_gpu=0
    while [[ ${words[i]:-} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
        [[ ${words[i]} =~ $unsafe ]] && die "$file $size: ${words[i]%%=*} is a setting the app refuses"
        # a hidden GPU becomes --device none: no card of any backend (CUDA, ROCm, Vulkan) is used
        if [ "${words[i]}" = CUDA_VISIBLE_DEVICES= ]; then no_gpu=1; i=$((i + 1)); continue; fi
        settings+=("${words[i]}")
        i=$((i + 1))
    done
    [[ ${words[i]:-} == */llama-server ]] || die "$file $size: the program is not llama-server (${words[i]:-nothing})"
    i=$((i + 1))
    local model=0 context=""
    while [ "$i" -lt "$n" ]; do
        local word=${words[i]}
        case "$word" in
            -m) model=1; i=$((i + 2)) ;;
            --host) [ "${words[i + 1]:-}" = 127.0.0.1 ] || die "$file $size: --host is not 127.0.0.1, the app's address"; i=$((i + 2)) ;;
            --port) i=$((i + 2)) ;;
            # the preset's whole layers were picked for its own card: the engine fits as many as each machine's card holds
            --moe-stream-gpu-layers-list) i=$((i + 2)) ;;
            *)
                [[ $supplied == *" ${word%%=*} "* ]] && die "$file $size: $word is set by the app, a preset cannot use it"
                [ "$word" = -c ] && context=${words[i + 1]:-}
                flags+=("$word")
                i=$((i + 1))
                ;;
        esac
    done
    [ "$no_gpu" = 1 ] && flags+=(--device none)
    [ "$model" = 1 ] || die "$file $size: no -m model file"
    [[ $context =~ ^[0-9]+$ ]] || die "$file $size: no context length (-c N)"
    local text="${settings[*]:-} ${flags[*]}"
    text=${text//\/__root__\/traces\/qwen38wv\//\{models\}\/}
    text=${text//\/__root__\/traces\/inkling2wv\//\{models\}\/}
    case "$text" in *__root__*) die "$file $size: a path into the preset's folder is left in the flags" ;; esac
    case "$text" in *'$'* | *\\*) die "$file $size: a \$ or \\ cannot be written into the Dart file as it is" ;; esac
    printf '%s\t%s\n' "$context" "${text# }"
}

# One Dart map of the commands of one preset, the text wrapped like the lines of the file.
emit_map () {   # constant name, preset file, case
    local name=$1 file=$2 size
    echo "const $name = <int, String>{"
    for size in $(preset_sizes "$file"); do
        local entry context text line word
        entry=$(app_command "$file" "$size" "$3")
        context=${entry%%$'\t'*}
        text=${entry#*$'\t'}
        echo "  $context:"
        line=""
        for word in $text; do
            if [ -z "$line" ]; then
                line=$word
            elif [ $((${#line} + 1 + ${#word})) -gt 100 ]; then
                echo "      '$line '"
                line=$word
            else
                line="$line $word"
            fi
        done
        echo "      '$line',"
    done
    echo "};"
}

generate () {
    cat <<'EOF'
// GENERATED by tool/sync_auto_commands.sh from the engine's model presets (presets/ling.sh, flint.sh, qwen38.sh, inkling2.sh).
// Do not edit by hand: change the preset and run the script again. The unit tests fail while the two disagree.

/// The flags each model starts with, one command per context length (the Auto profile), for each kind of machine: a
/// large GPU (Auto), a small GPU (AutoSmall), no usable GPU (AutoCpu). Environment settings come first; the app adds the
/// engine's path, the model, the address and the port, and its models folder for {models}.
library;

EOF
    local model file first=1
    for model in ling:ling.sh flint:flint.sh qwen:qwen38.sh inkling:inkling2.sh; do
        file=$presets/${model#*:}
        for kind in 1: 2:Small 3:Cpu; do
            [ "$first" = 1 ] || echo
            first=0
            emit_map "${model%%:*}Auto${kind#*:}" "$file" "${kind%%:*}"
        done
    done
}

[ -f "$presets/ling.sh" ] && [ -f "$presets/flint.sh" ] && [ -f "$presets/qwen38.sh" ] && [ -f "$presets/inkling2.sh" ] || die "the presets are not in $presets"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
generate > "$out"

if [ "$check" = 1 ]; then
    if ! diff -u "$target" "$out" > "$out.diff"; then
        cat "$out.diff" >&2
        rm -f "$out.diff"
        die "$target does not match the presets: run tool/sync_auto_commands.sh"
    fi
    rm -f "$out.diff"
    echo "$target matches the presets"
else
    cp "$out" "$target"
    echo "wrote $target"
fi
