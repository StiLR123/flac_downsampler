#!/usr/bin/env bash

# FLAC Downsampler
# Converts 24-bit FLAC files to 16-bit / 44.1 kHz FLAC.

# TODO: - Fix assign issue at Ln 140 & 492 -> (SC2154) & (SC2155)
#       - Fix unbound variable error for var $file_list
# Main at Ln 560
set -Eeuo pipefail

# Check bash ver
if ((BASH_VERSINFO[0] < 4)) || { ((BASH_VERSINFO[0] == 4)) && ((BASH_VERSINFO[1] < 3)); }; then
    printf '%s\n' "ERROR: This script requires bash 4.3+. Found bash ${BASH_VERSION}." >&2
    exit 1
fi


# Config

MUSIC_DIR="${MUSIC_DIR:-${HOME}/Music}"
PARALLEL_JOBS="${PARALLEL_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
# Limit ffmpeg threads per job (tune to your system)
FFMPEG_THREADS="${FFMPEG_THREADS:-1}"
# FLAC compression level (higher = smaller , but slower)
FLAC_COMPRESSION="${FLAC_COMPRESSION:-5}"
DRY_RUN="${DRY_RUN:-0}"
DURATION_TOLERANCE="${DURATION_TOLERANCE:-0.1}"
BACKUP_MODE="${BACKUP_MODE:-0}"
NICE_LEVEL="${NICE_LEVEL:-10}"
USE_IONICE="${USE_IONICE:-1}"


# Counters

TOTAL_FILES=0
CONVERTED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
DRY_RUN_COUNT=0
TOTAL_BYTES_ORIGINAL=0
TOTAL_BYTES_CONVERTED=0

RUN_ID="$$"
RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flac-downsampler.${RUN_ID}.XXXXXX")"
export RESULT_DIR RUN_ID

cleanup() {
    if [[ -n "${RESULT_DIR:-}" && -d "$RESULT_DIR" ]]; then
        rm -rf -- "$RESULT_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Logs & colours

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$GREEN" "$NC" "$*"; }
log_warning() { printf '%s[WARNING]%s %s\n' "$YELLOW" "$NC" "$*"; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }


# Validation checks

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        log_error "Required command not found: $command_name"
        exit 1
    fi
}

has_gnu_parallel() {
    command -v parallel >/dev/null 2>&1 || return 1
    parallel --version 2>/dev/null | head -n1 | grep -qi 'gnu parallel'
}

validate_configuration() {
    if [[ ! "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        log_error "PARALLEL_JOBS must be a positive integer"
        exit 1
    fi

    if [[ ! "$DURATION_TOLERANCE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_error "DURATION_TOLERANCE must be a non-negative number"
        exit 1
    fi

    if [[ ! -d "$MUSIC_DIR" ]]; then
        log_error "Music directory not found: $MUSIC_DIR"
        exit 1
    fi
}


# Audio info

get_audio_info() {
    local file="$1"
    local -n info="$2"

    info=()
    local output

    if ! output="$(
        ffprobe \
            -v error \
            -select_streams a:0 \
            -show_entries stream=bits_per_sample,bits_per_raw_sample,sample_rate,channels,duration \
            -of default=noprint_wrappers=1 \
            "$file" 2>/dev/null
    )"; then
        log_error "ffprobe failed: $file"
        return 1
    fi

    if [[ -z "$output" ]]; then
        log_error "No audio stream found: $file"
        return 1
    fi

    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        info["$key"]="$value"
    done <<< "$output"

    for key in sample_rate channels duration; do
        if [[ -z "${info[$key]:-}" || "${info[$key]}" == "N/A" ]]; then
            log_error "Missing ffprobe field '$key': $file"
            return 1
        fi
    done

    if [[ -n "${info[bits_per_raw_sample]:-}" && "${info[bits_per_raw_sample]}" != "N/A" ]]; then
        info[bit_depth]="${info[bits_per_raw_sample]}"
    elif [[ -n "${info[bits_per_sample]:-}" && "${info[bits_per_sample]}" != "N/A" ]]; then
        info[bit_depth]="${info[bits_per_sample]}"
    else
        log_error "Could not determine bit depth: $file"
        return 1
    fi

    return 0
}


# File info

get_file_size() {
    local file="$1"
    local size=""

    if [[ ! -f "$file" ]]; then
        echo 0
        return 0
    fi

    size="$(stat -f%z "$file" 2>/dev/null)" || size=""
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        size="$(stat -c%s "$file" 2>/dev/null)" || size=""
    fi

    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        log_warning "Could not determine file size for: $file"
        echo 0
        return 0
    fi

    echo "$size"
}

format_bytes() {
    local bytes=$1
    if (( bytes < 1024 )); then
        printf '%d B' "$bytes"
    elif (( bytes < 1024 * 1024 )); then
        printf '%s KiB' "$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $bytes / 1024}")"
    elif (( bytes < 1024 * 1024 * 1024 )); then
        printf '%s MiB' "$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $bytes / (1024 * 1024)}")"
    else
        printf '%s GiB' "$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $bytes / (1024 * 1024 * 1024)}")"
    fi
}

durations_match() {
    local original="$1"
    local converted="$2"
    local tolerance="$3"

    LC_ALL=C awk -v original="$original" -v converted="$converted" -v tolerance="$tolerance" \
        'BEGIN {
            difference = original - converted
            if (difference < 0) difference = -difference
            exit !(difference <= tolerance)
        }'
}

duration_difference() {
    local original="$1"
    local converted="$2"

    LC_ALL=C awk -v original="$original" -v converted="$converted" \
        'BEGIN {
            difference = original - converted
            if (difference < 0) difference = -difference
            printf "%.6f", difference
        }'
}


# Results

write_result() {
    local status="$1"
    local file="$2"
    local original_size="${3:-0}"
    local converted_size="${4:-0}"
    local result_file

    if [[ -z "${RESULT_DIR:-}" ]] || [[ ! -d "$RESULT_DIR" ]]; then
        log_error "Internal error: RESULT_DIR is invalid in worker process."
        exit 1
    fi

    result_file="$(mktemp "$RESULT_DIR/result.XXXXXX")"

    printf '%s\0%s\0%s\0%s\0' "$status" "$file" "$original_size" "$converted_size" > "$result_file"
}

# Aggreregate results (idk how to spell it)
aggregate_results() {
    CONVERTED_COUNT=0
    SKIPPED_COUNT=0
    FAILED_COUNT=0
    DRY_RUN_COUNT=0
    TOTAL_BYTES_ORIGINAL=0
    TOTAL_BYTES_CONVERTED=0

    local accounted_for=0

    # Hehe nullglob. Funny word
    local shopt_was_set=0
    if ! shopt -q nullglob; then
        shopt_was_set=1
        shopt -s nullglob
    fi

    for result_file in "$RESULT_DIR"/result.*; do
        [[ -f "$result_file" ]] || continue

        local status file original_size converted_size

        {
            read -r -d '' status || status=""
            read -r -d '' file || file=""
            read -r -d '' original_size || original_size="0"
            read -r -d '' converted_size || converted_size="0"
        } < "$result_file"

        original_size="${original_size:-0}"
        converted_size="${converted_size:-0}"

        case "${status:-UNKNOWN}" in
            CONVERTED)
                CONVERTED_COUNT=$((CONVERTED_COUNT + 1))
                TOTAL_BYTES_ORIGINAL=$((TOTAL_BYTES_ORIGINAL + original_size))
                TOTAL_BYTES_CONVERTED=$((TOTAL_BYTES_CONVERTED + converted_size))
                accounted_for=$((accounted_for + 1))
                ;;
            SKIPPED)
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                accounted_for=$((accounted_for + 1))
                ;;
            FAILED)
                FAILED_COUNT=$((FAILED_COUNT + 1))
                accounted_for=$((accounted_for + 1))
                ;;
            DRY_RUN)
                DRY_RUN_COUNT=$((DRY_RUN_COUNT + 1))
                accounted_for=$((accounted_for + 1))
                ;;
            *)
                log_warning "Unrecognized result record (status='${status:-}'), ignoring"
                ;;
        esac

        rm -f -- "$result_file"
    done

    if [[ $shopt_was_set -eq 1 ]]; then
        shopt -u nullglob
    fi

    if [[ "$accounted_for" -ne "$TOTAL_FILES" ]]; then
        log_warning "Accounted for $accounted_for of $TOTAL_FILES files — some workers may not have completed (killed, crashed, or OOM)."
    fi
}


# Process files

process_file() {
    local file="$1"
    declare -A source_info=()
    declare -A converted_info=()

    printf '%s\n' ""
    printf '%s\n' "Processing:"
    printf '%s\n' "$file"

    if ! get_audio_info "$file" source_info; then
        local original_size
        original_size=$(get_file_size "$file")
        write_result "FAILED" "$file" "$original_size" 0
        return 0
    fi

    local source_bit_depth="${source_info[bit_depth]}"
    local source_sample_rate="${source_info[sample_rate]}"
    local source_channels="${source_info[channels]}"
    local source_duration="${source_info[duration]}"

    if [[ "$source_bit_depth" != "24" ]]; then
        printf '%s' "Skipping: not a 24-bit file (${source_bit_depth}-bit)"
        local orig_sz
        orig_sz=$(get_file_size "$file")
        write_result "SKIPPED" "$file" "$orig_sz" 0
        return 0
    fi

    printf 'Source:\n'
    printf '  Bit depth:   %s bit\n' "$source_bit_depth"
    printf '  Sample rate: %s Hz\n' "$source_sample_rate"
    printf '  Channels:    %s\n' "$source_channels"
    printf '  Duration:    %ss\n' "$source_duration"

    local original_size
    original_size=$(get_file_size "$file")

    if [[ "$DRY_RUN" == "1" ]]; then
        printf '\n[DRY RUN] Would convert file to 16-bit / 44.1 kHz FLAC.\n'
        printf '[DRY RUN] Original size: %s\n' "$(format_bytes "$original_size")"
        printf '\n[DRY RUN] Command:\n'
        printf '  ffmpeg -nostdin -hide_banner -loglevel error -threads %s -i %s ' "$FFMPEG_THREADS" "$file"
        printf '%s\n' "-map 0 -map_metadata 0 -map_chapters 0 -c:v copy -c:a copy -c:a:0 flac -compression_level $FLAC_COMPRESSION -sample_fmt:a:0 s16 -dither_method:a:0 triangular -ar:a:0 44100 -y -f flac <tempfile>"
        printf '\n'

        write_result "DRY_RUN" "$file" "$original_size" 0
        return 0
    fi

    local file_dir file_base temp_file
    file_dir="$(dirname -- "$file")"
    file_base="$(basename -- "$file")"

    if ! temp_file="$(mktemp "${file_dir}/.${file_base}.converting.XXXXXX")"; then
        log_error "Failed to create temporary file next to: $file"
        write_result "FAILED" "$file" "$original_size" 0
        return 0
    fi

    cleanup_temp() {
        rm -f -- "$temp_file" 2>/dev/null || true
    }
    trap cleanup_temp EXIT
    trap 'cleanup_temp; exit 130' INT TERM

    printf '\n'
    log_info "Converting..."

    # Build nice wrapper
    local nicmd=()
    if [[ -n "${NICE_LEVEL:-}" ]]; then
        nicmd+=(nice -n "$NICE_LEVEL")
    fi
    if [[ "${USE_IONICE:-1}" == "1" ]] && command -v ionice >/dev/null 2>&1; then
        nicmd+=(ionice -c2 -n7)
    fi

    # Run ffmpeg with nice wrapper
    # Apply conversion to audio stream 0 (a:0); copy other streams unchanged
    if ((${#nicmd[@]} > 0)); then
        if ! "${nicmd[@]}" ffmpeg -nostdin -hide_banner -loglevel error -threads "$FFMPEG_THREADS" -i "$file" \
            -map 0 -map_metadata 0 -map_chapters 0 \
            -c:v copy -c:a copy -c:a:0 flac -compression_level "$FLAC_COMPRESSION" \
            -sample_fmt:a:0 s16 -dither_method:a:0 triangular -ar:a:0 44100 \
            -y -f flac "$temp_file" 2>/dev/null; then

            log_error "Conversion failed: $file"
            cleanup_temp
            write_result "FAILED" "$file" "$original_size" 0
            return 0
        fi
    else
        if ! ffmpeg -nostdin -hide_banner -loglevel error -threads "$FFMPEG_THREADS" -i "$file" \
            -map 0 -map_metadata 0 -map_chapters 0 \
            -c:v copy -c:a copy -c:a:0 flac -compression_level "$FLAC_COMPRESSION" \
            -sample_fmt:a:0 s16 -dither_method:a:0 triangular -ar:a:0 44100 \
            -y -f flac "$temp_file" 2>/dev/null; then

            log_error "Conversion failed: $file"
            cleanup_temp
            write_result "FAILED" "$file" "$original_size" 0
            return 0
        fi
    fi

    # More verification
    # TODO: Add unecessary age verification to steal data

    # Verify temp file
    if [[ ! -s "$temp_file" ]]; then
        log_error "Converted file is empty or missing: $file"
        cleanup_temp
        write_result "FAILED" "$file" "$original_size" 0
        return 0
    fi

    if ! get_audio_info "$temp_file" converted_info; then
        log_error "Could not read converted file: $file"
        cleanup_temp
        write_result "FAILED" "$file" "$original_size" 0
        return 0
    fi

    local converted_bit_depth="${converted_info[bit_depth]}"
    local converted_sample_rate="${converted_info[sample_rate]}"
    local converted_channels="${converted_info[channels]}"
    local converted_duration="${converted_info[duration]}"

    printf '\nConverted:\n'
    printf '  Bit depth:   %s bit\n' "$converted_bit_depth"
    printf '  Sample rate: %s Hz\n' "$converted_sample_rate"
    printf '  Channels:    %s\n' "$converted_channels"
    printf '  Duration:    %ss\n' "$converted_duration"

    local verification_passed=1
    printf '\nVerification:\n'


    if [[ "$converted_bit_depth" != "16" ]]; then
        log_error "  Bit depth is ${converted_bit_depth}, expected 16"
        verification_passed=0
    else
        printf '  ✓ Bit depth: 16-bit\n'
    fi


    if [[ "$converted_sample_rate" != "44100" ]]; then
        log_error "  Sample rate is ${converted_sample_rate}, expected 44100"
        verification_passed=0
    else
        printf '  ✓ Sample rate: 44100 Hz\n'
    fi


    if [[ "$converted_channels" != "$source_channels" ]]; then
        log_error "  Channel count changed from ${source_channels} to ${converted_channels}"
        verification_passed=0
    else
        printf '  ✓ Channels: %s\n' "$converted_channels"
    fi

    if ! durations_match "$source_duration" "$converted_duration" "$DURATION_TOLERANCE"; then
        local difference
        difference=$(duration_difference "$source_duration" "$converted_duration")
        log_error "  Duration difference: ${difference}s (tolerance: ${DURATION_TOLERANCE}s)"
        verification_passed=0
    else
        printf '  ✓ Duration: matches (within %ss)\n' "${DURATION_TOLERANCE}"
    fi

    local converted_size
    converted_size=$(get_file_size "$temp_file")


    printf '\n'
    printf '  Original size:  %s\n' "$(format_bytes "$original_size")"
    printf '  Converted size: %s\n' "$(format_bytes "$converted_size")"
    printf '  Space saved:    %s\n' "$(format_bytes "$((original_size - converted_size))")"

    # Replace/backup original

    if [[ "$verification_passed" == "1" ]]; then
        printf '\n'

        if [[ "$BACKUP_MODE" == "1" ]]; then
            local backup_file="${file}.backup.$(date +%s)"
            if [[ -e "$backup_file" ]]; then
                log_warning "Overwriting existing backup: $backup_file"
            fi
            if cp -p -- "$file" "$backup_file"; then
                log_info "Backup created: $backup_file"
            else
                log_error "Failed to create backup. Original file preserved."
                cleanup_temp
                write_result "FAILED" "$file" "$original_size" 0
                return 0
            fi
        fi

        touch -r -- "$file" "$temp_file" 2>/dev/null || true
        chmod --reference="$file" "$temp_file" 2>/dev/null || \
            chmod "$(stat -f%Lp "$file" 2>/dev/null || stat -c%a "$file" 2>/dev/null)" "$temp_file" 2>/dev/null || true

        if mv -f -- "$temp_file" "$file"; then
            log_success "$file"
            trap - EXIT INT TERM
            write_result "CONVERTED" "$file" "$original_size" "$converted_size"
            return 0
        else
            log_error "Could not replace original file"
            cleanup_temp
            write_result "FAILED" "$file" "$original_size" 0
            return 0
        fi
    else
        printf '\n'
        log_error "Verification FAILED — original file preserved"
        cleanup_temp
        write_result "FAILED" "$file" "$original_size" 0
        return 0
    fi
}



show_help() {
    cat << 'EOF'
FLAC Downsampler — Convert 24-bit FLAC files to 16-bit / 44.1 kHz

USAGE:
  flac_downsampler.sh [OPTIONS]

OPTIONS:
  --music-dir DIR                Directory containing FLAC files
                                 (default: $HOME/Music, current: $MUSIC_DIR)
  --jobs N                       Number of concurrent parallel jobs
                                 (default: number of CPU cores, current: $PARALLEL_JOBS)
  --threads N                    Number of threads per ffmpeg instance
                                 (default: 1, current: $FFMPEG_THREADS)
  --compression N                FLAC compression level (0-12, default: 5)
  --tolerance N                  Allowed duration difference in seconds (default: 0.1)
  --backup                       Create backup of original files (.backup.<timestamp>)
  --dry-run                      Show what would be converted without making changes
  --no-nice                      Run at normal priority (disables nice/ionice)
  --help                         Show this help message

ENVIRONMENT VARIABLES:
  You can also set the following variables before running:
  MUSIC_DIR, PARALLEL_JOBS, FFMPEG_THREADS, FLAC_COMPRESSION,
  DURATION_TOLERANCE, BACKUP_MODE, DRY_RUN, NICE_LEVEL, USE_IONICE
EOF
}


# ===========
#    Main
# ===========


main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --music-dir)
                MUSIC_DIR="$2"
                shift 2
                ;;
            --jobs)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --threads)
                FFMPEG_THREADS="$2"
                shift 2
                ;;
            --compression)
                FLAC_COMPRESSION="$2"
                shift 2
                ;;
            --tolerance)
                DURATION_TOLERANCE="$2"
                shift 2
                ;;
            --backup)
                BACKUP_MODE=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --no-nice)
                NICE_LEVEL=""
                USE_IONICE=0
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                echo "Use --help for usage."
                exit 1
                ;;
        esac
    done

    export MUSIC_DIR PARALLEL_JOBS FFMPEG_THREADS FLAC_COMPRESSION
    export DURATION_TOLERANCE BACKUP_MODE DRY_RUN
    export NICE_LEVEL USE_IONICE

    export PARALLEL_SHELL="/bin/bash"

    export -f process_file
    export -f get_audio_info
    export -f get_file_size
    export -f format_bytes
    export -f durations_match
    export -f duration_difference
    export -f write_result
    export -f log_info log_success log_warning log_error

    require_command ffmpeg
    require_command ffprobe
    require_command find
    require_command awk
    require_command stat

    validate_configuration



    local lockfile="${TMPDIR:-/tmp}/flac-downsampler.${USER:-unknown}.lock"
    exec 9>"$lockfile" || { log_error "Cannot open lockfile $lockfile"; exit 1; }
    if ! flock -n 9; then
        log_error "Another flac_downsampler instance is running (lock: $lockfile)"
        exit 1
    fi

    # Clean orphaned temp files
    find "$MUSIC_DIR" -type f -name ".*.converting.*" -delete 2>/dev/null || true

    log_info "Configuration:"
    printf '  Music Directory:    %s\n' "$MUSIC_DIR"
    printf '  Parallel Jobs:      %s\n' "$PARALLEL_JOBS"
    printf '  ffmpeg threads/job: %s\n' "$FFMPEG_THREADS"
    printf '  FLAC Compression:   %s\n' "$FLAC_COMPRESSION"
    printf '  Duration Tolerance: %s seconds\n' "$DURATION_TOLERANCE"
    printf '  Backup Mode:        %s\n' "$([[ "$BACKUP_MODE" == "1" ]] && echo "Enabled" || echo "Disabled")"
    printf '  Dry Run:            %s\n' "$([[ "$DRY_RUN" == "1" ]] && echo "Enabled" || echo "Disabled")"
    printf '  Niceness/IO-nice:   %s\n' "$([[ -n "$NICE_LEVEL" ]] && echo "Enabled" || echo "Disabled")"
    printf '\n'

    log_info "Scanning for FLAC files.."
    local file_list
    file_list="$(mktemp "${TMPDIR:-/tmp}/flac-downsampler.files.XXXXXX")"

    # Clean file list on exit
    trap 'rm -f -- "$file_list" 2>/dev/null || true; cleanup' EXIT
    trap 'rm -f -- "$file_list" 2>/dev/null || true; cleanup; exit 130' INT TERM

    find "$MUSIC_DIR" -type f -iname "*.flac" -print0 > "$file_list"



    TOTAL_FILES=$(tr -cd '\0' < "$file_list" | wc -c || echo 0)
    TOTAL_FILES="${TOTAL_FILES:-0}"

    if [[ "$TOTAL_FILES" == "0" ]]; then
        log_info "No FLAC files found in $MUSIC_DIR"
        exit 0
    fi

    log_info "Found $TOTAL_FILES FLAC file(s)"
    printf '\n'

    if has_gnu_parallel; then
        log_info "Using GNU Parallel for processing"
        # Export necessary env vars
        if ! parallel -0 -j "$PARALLEL_JOBS" \
            --env FFMPEG_THREADS --env FLAC_COMPRESSION --env NICE_LEVEL --env USE_IONICE \
            --env RESULT_DIR --env RUN_ID --env DURATION_TOLERANCE --env BACKUP_MODE --env DRY_RUN \
            process_file < "$file_list"; then
            log_warning "Some parallel jobs encountered errors"
        fi
    else
        log_info "GNU Parallel not found, falling back to xargs"
        if ! xargs -0 -P "$PARALLEL_JOBS" -I {} bash -c 'process_file "$@"' _ {} < "$file_list"; then
            log_warning "Some xargs jobs encountered errors"
        fi
    fi

    printf '\n'
    log_info "Gathering results..."
    aggregate_results

    printf '\n\n'
    printf 'SUMMARY\n'
    printf 'Total files scanned:  %d\n' "$TOTAL_FILES"

    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'Would convert:        %d\n' "$DRY_RUN_COUNT"
        printf 'Would skip:           %d (Already <= 16-bit)\n' "$SKIPPED_COUNT"
        printf 'Failed checks:        %d\n' "$FAILED_COUNT"
    else
        printf 'Successfully conv.:   %d\n' "$CONVERTED_COUNT"
        printf 'Skipped:              %d (Already <= 16-bit)\n' "$SKIPPED_COUNT"
        printf 'Failed:               %d\n' "$FAILED_COUNT"

        if [[ "$CONVERTED_COUNT" -gt 0 ]]; then
            local space_saved=$((TOTAL_BYTES_ORIGINAL - TOTAL_BYTES_CONVERTED))
            printf '\nStorage impact for converted files:\n'
            printf '  Original size:  %s\n' "$(format_bytes "$TOTAL_BYTES_ORIGINAL")"
            printf '  New size:       %s\n' "$(format_bytes "$TOTAL_BYTES_CONVERTED")"

            if (( space_saved > 0 )); then
                printf '  Space saved:    %s\n' "$(format_bytes "$space_saved")"
            else
                printf '  Space cost:     %s (converted files are larger)\n' "$(format_bytes "$((-space_saved))")"
            fi
        fi
    fi

    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        log_warning "WARNING: There were $FAILED_COUNT failures. Check logs above"
        exit 1
    fi
}

main "$@"