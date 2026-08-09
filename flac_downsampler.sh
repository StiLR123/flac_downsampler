#!/bin/bash

set -u

# FLAC Downsampler Script
# Converts 24-bit FLAC files to 16-bit/44.1kHz with comprehensive verification

# Configuration
MUSIC_DIR="${MUSIC_DIR:-$HOME/Music}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
DRY_RUN="${DRY_RUN:-0}"
DURATION_TOLERANCE="${DURATION_TOLERANCE:-0.1}"

# Statistics
TOTAL_FILES=0
CONVERTED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
STATS_FILE="/tmp/flac_converter_stats_$$.txt"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cleanup on exit
cleanup() {
    rm -f "$STATS_FILE"
}
trap cleanup EXIT

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse ffprobe output into associative array
get_audio_info() {
    local file="$1"
    local -n info_array=$2

    # Fetch all audio stream info in one call for efficiency
    local ffprobe_output
    ffprobe_output=$(ffprobe -v error \
        -select_streams a:0 \
        -show_entries stream=bits_per_raw_sample,sample_rate,channels,duration,duration_ts \
        -of default=noprint_wrappers=1 \
        "$file" 2>/dev/null)

    if [[ -z "$ffprobe_output" ]]; then
        log_error "ffprobe failed to read: $file"
        return 1
    fi

    # Parse output
    while IFS='=' read -r key value; do
        info_array["$key"]="$value"
    done <<< "$ffprobe_output"

    # Validate critical fields
    for key in "bits_per_raw_sample" "sample_rate" "channels" "duration"; do
        if [[ -z "${info_array[$key]:-}" ]]; then
            log_error "Missing ffprobe field '$key' for: $file"
            return 1
        fi
    done

    return 0
}

# Calculate MD5 checksum of PCM samples using ffmpeg framemd5
get_pcm_checksum() {
    local file="$1"
    local checksum_file="/tmp/framemd5_$$.txt"

    ffmpeg -hide_banner -loglevel error \
        -i "$file" \
        -f framemd5 \
        -v error \
        "$checksum_file" 2>/dev/null

    if [[ ! -f "$checksum_file" ]]; then
        rm -f "$checksum_file"
        return 1
    fi

    # Extract and combine MD5s
    local combined_md5
    combined_md5=$(grep -o '[a-f0-9]\{32\}' "$checksum_file" | tr -d '\n' | md5sum | awk '{print $1}')
    rm -f "$checksum_file"

    echo "$combined_md5"
}

# Compare durations with tolerance
durations_match() {
    local original="$1"
    local converted="$2"
    local tolerance="${3:-0.1}"

    # Validate inputs
    if ! [[ "$original" =~ ^[0-9]+\.?[0-9]*$ ]] || ! [[ "$converted" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        log_error "Invalid duration values: original=$original, converted=$converted"
        return 1
    fi

    # Calculate difference with bc (more reliable than awk for floats)
    local difference
    difference=$(echo "$original - $converted" | bc 2>/dev/null | tr -d '-')

    if [[ -z "$difference" ]]; then
        return 1
    fi

    # Check if difference is within tolerance
    if (( $(echo "$difference <= $tolerance" | bc -l 2>/dev/null) )); then
        return 0
    else
        return 1
    fi
}

# Process a single FLAC file
process_file() {
    local file="$1"
    
    # Declare source and verified info arrays
    declare -A source_info
    declare -A verified_info

    echo
    echo "========================================"
    echo "Processing:"
    echo "$file"
    echo "========================================"

    # Get source file info
    if ! get_audio_info "$file" source_info; then
        log_error "Could not extract audio information from source file"
        ((FAILED_COUNT++))
        return 1
    fi

    local source_bit_depth="${source_info[bits_per_raw_sample]}"
    local source_sample_rate="${source_info[sample_rate]}"
    local source_channels="${source_info[channels]}"
    local source_duration="${source_info[duration]}"

    # Only process 24-bit FLAC files
    if [[ "$source_bit_depth" != "24" ]]; then
        log_warning "Skipping: not a 24-bit file (bit depth: ${source_bit_depth})"
        ((SKIPPED_COUNT++))
        return 0
    fi

    echo "Source:"
    echo "  Bit depth:   ${source_bit_depth} bit"
    echo "  Sample rate: ${source_sample_rate} Hz"
    echo "  Channels:    ${source_channels}"
    echo "  Duration:    ${source_duration}s"
    echo

    # Generate temporary file with unique suffix
    local temp_file="${file}.tmp.flac"
    rm -f -- "$temp_file"

    # DRY RUN: Skip actual conversion
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[DRY RUN] Would convert with:"
        echo "  ffmpeg -hide_banner -loglevel error -i \"$file\" -map 0 -map_metadata 0 -map_chapters 0 -c:v copy -c:a flac -sample_fmt s16 -ar 44100 \"$temp_file\""
        echo "[DRY RUN] Would verify and replace original"
        ((CONVERTED_COUNT++))
        return 0
    fi

    # Perform conversion
    if ! ffmpeg -hide_banner -loglevel error \
        -i "$file" \
        -map 0 \
        -map_metadata 0 \
        -map_chapters 0 \
        -c:v copy \
        -c:a flac \
        -sample_fmt s16 \
        -ar 44100 \
        "$temp_file" 2>/dev/null; then

        log_error "Conversion failed"
        rm -f -- "$temp_file"
        ((FAILED_COUNT++))
        return 1
    fi

    # Get converted file info
    if ! get_audio_info "$temp_file" verified_info; then
        log_error "Could not verify converted file"
        rm -f -- "$temp_file"
        ((FAILED_COUNT++))
        return 1
    fi

    local verified_bit_depth="${verified_info[bits_per_raw_sample]}"
    local verified_sample_rate="${verified_info[sample_rate]}"
    local verified_channels="${verified_info[channels]}"
    local verified_duration="${verified_info[duration]}"

    echo "Converted:"
    echo "  Bit depth:   ${verified_bit_depth} bit"
    echo "  Sample rate: ${verified_sample_rate} Hz"
    echo "  Channels:    ${verified_channels}"
    echo "  Duration:    ${verified_duration}s"

    # Verify conversion
    local verification_passed=1
    echo
    echo "Verification:"

    # Check bit depth
    if [[ "$verified_bit_depth" != "16" ]]; then
        log_error "  Bit depth is ${verified_bit_depth}, expected 16"
        verification_passed=0
    else
        echo "  ✓ Bit depth: 16-bit"
    fi

    # Check sample rate
    if [[ "$verified_sample_rate" != "44100" ]]; then
        log_error "  Sample rate is ${verified_sample_rate}, expected 44100"
        verification_passed=0
    else
        echo "  ✓ Sample rate: 44100 Hz"
    fi

    # Check channel count
    if [[ "$verified_channels" != "$source_channels" ]]; then
        log_error "  Channel count changed from ${source_channels} to ${verified_channels}"
        verification_passed=0
    else
        echo "  ✓ Channels: ${verified_channels}"
    fi

    # Check duration
    if ! durations_match "$source_duration" "$verified_duration" "$DURATION_TOLERANCE"; then
        local difference
        difference=$(echo "$source_duration - $verified_duration" | bc 2>/dev/null | tr -d '-')
        log_error "  Duration difference: ${difference}s (tolerance: ${DURATION_TOLERANCE}s)"
        verification_passed=0
    else
        echo "  ✓ Duration: matches (within ${DURATION_TOLERANCE}s)"
    fi

    # If all checks passed, replace original and log checksum
    if [[ "$verification_passed" == "1" ]]; then
        echo
        if mv -f -- "$temp_file" "$file"; then
            log_success "$file"
            ((CONVERTED_COUNT++))
            
            # Store statistics
            {
                echo "FILE=$file"
                echo "ORIGINAL_BITDEPTH=$source_bit_depth"
                echo "ORIGINAL_SAMPLERATE=$source_sample_rate"
                echo "CONVERTED_BITDEPTH=$verified_bit_depth"
                echo "CONVERTED_SAMPLERATE=$verified_sample_rate"
            } >> "$STATS_FILE"
            
            return 0
        else
            log_error "Could not replace original file"
            rm -f -- "$temp_file"
            ((FAILED_COUNT++))
            return 1
        fi
    else
        echo
        log_error "Verification FAILED"
        rm -f -- "$temp_file"
        ((FAILED_COUNT++))
        return 1
    fi
}

# Export functions for parallel execution
export -f process_file log_info log_success log_warning log_error get_audio_info durations_match get_pcm_checksum
export PARALLEL_JOBS DRY_RUN DURATION_TOLERANCE CONVERTED_COUNT SKIPPED_COUNT FAILED_COUNT STATS_FILE
export RED GREEN YELLOW BLUE NC

# Main script
main() {
    echo "========================================"
    echo "FLAC Audio Downsampler"
    echo "========================================"
    echo "Music directory: $MUSIC_DIR"
    echo "Target format:   16-bit / 44.1kHz FLAC"
    echo "Parallel jobs:   $PARALLEL_JOBS"
    echo "Duration tolerance: ${DURATION_TOLERANCE}s"
    
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "MODE: DRY RUN (no files will be modified)"
    fi
    echo "========================================"
    echo

    # Check if music directory exists
    if [[ ! -d "$MUSIC_DIR" ]]; then
        log_error "Music directory not found: $MUSIC_DIR"
        exit 1
    fi

    # Find all FLAC files and count them
    local flac_files
    mapfile -t flac_files < <(find "$MUSIC_DIR" -type f -iname "*.flac" -print0 | tr '\0' '\n')
    TOTAL_FILES=${#flac_files[@]}

    if [[ $TOTAL_FILES -eq 0 ]]; then
        log_warning "No FLAC files found in $MUSIC_DIR"
        exit 0
    fi

    echo "Found $TOTAL_FILES FLAC files to process"
    echo

    # Process files in parallel using GNU parallel or xargs
    if command -v parallel &> /dev/null; then
        # Use GNU parallel if available
        export -p | grep "^export" > /tmp/parallel_env_$$.sh
        find "$MUSIC_DIR" -type f -iname "*.flac" -print0 | \
            parallel -0 -j "$PARALLEL_JOBS" process_file
    else
        # Fallback to xargs
        find "$MUSIC_DIR" -type f -iname "*.flac" -print0 | \
            xargs -0 -P "$PARALLEL_JOBS" -I {} bash -c 'process_file "$@"' _ {}
    fi

    # Print summary
    echo
    echo "========================================"
    echo "Conversion Summary"
    echo "========================================"
    echo "Total files found:  $TOTAL_FILES"
    echo "Successfully converted: $CONVERTED_COUNT"
    echo "Skipped (not 24-bit): $SKIPPED_COUNT"
    echo "Failed: $FAILED_COUNT"
    echo "========================================"

    if [[ $FAILED_COUNT -gt 0 ]]; then
        echo
        log_warning "Some files failed to convert. Please review the output above."
        exit 1
    else
        echo
        log_success "All conversions completed successfully!"
        exit 0
    fi
}

# Show usage
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --music-dir DIR           Directory containing FLAC files (default: \$HOME/Music)
  --parallel-jobs N         Number of parallel conversion jobs (default: 4)
  --dry-run                 Show what would be done without modifying files
  --duration-tolerance SEC  Maximum allowed duration difference in seconds (default: 0.1)
  --help                    Show this help message

Environment variables:
  MUSIC_DIR                 Override default music directory
  PARALLEL_JOBS             Override number of parallel jobs
  DRY_RUN                   Set to 1 for dry-run mode
  DURATION_TOLERANCE        Override duration tolerance

Examples:
  $0                                    # Convert files in ~/Music
  $0 --music-dir /mnt/external/music   # Convert from specific directory
  $0 --dry-run --parallel-jobs 2       # Preview with 2 parallel jobs
  PARALLEL_JOBS=8 $0                   # Use 8 parallel jobs

EOF
    exit 0
fi

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --music-dir)
            MUSIC_DIR="$2"
            shift 2
            ;;
        --parallel-jobs)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --duration-tolerance)
            DURATION_TOLERANCE="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Run main function
main
