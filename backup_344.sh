#!/usr/bin/env bash
# global variables
mode=""
path=""
file=""
dest="."
log_file=""
manifest=""
verbose=false
generate=false
overwrite=false
dry_run=false
warn_count=0
error_count=0
name=""

# set -x
# functions
usage() {
    echo "Usage: MODE [OPTIONS]"
    echo "Try 'backup.sh --help' for more detailed information"
    echo "Valid Modes: batch single verify restore or --help"
}
show_help() {
    cat <<EOF
Backup.sh                   Backs up and restores files, batch jobs, and verifies integrity of backups
Usage: MODE [OPTIONS]

Modes:
    batch                   Back up multiple paths that are read from a csv file
    single                  Back up a single directory or file
    verify                  Verify the integrity of a backup
    restore                 Restore files from a backup

Batch Mode Options:
    --csv file              Path to csv file containing paths to backup targets
    --generate              Generates a preformatted CSV file with headers to use
    -n, --name              Optional name of the archive

Single Mode Options:
    --file PATH             Path to a single file, will not tar up result
    --dir PATH              Path to a single directory, will tar result
    -n, --name              Optional name of the archive

Verify Mode Options: 
    --archive file          Backup file to verify integrity of

Restore Mode Options:
    --archive file          Archive to restore
    --overwrite             Overwrite files in place, recommended to use after dry-run

Global Options:
    -o, --out dir           Output directory for backups and restores, defaults to ./
    -l, --log file          Log file path. If no filename given, defaults to backup_date.log
    -v, --verbose           Enable verbose logging, by default off
    -h, --help              Displays this message
    --dry-run               Shows actions to be taken without copying, taring, extracting, or overwriting

Exit Codes:
    0   PASS                Operations completed successfully
    2   WARN                Non-fatal issue encountered
    1   FAIL                Fatal error occurred, generally bad inputs or no inputs

Examples:
    backup.sh single --file /etc/hosts --out /tmp/backups
    backup.sh batch --csv file.csv --out /tmp/backups --log
    backup.sh verify --archive backup_date.tar.gz
    backup.sh restore --archive backup_date.tar.gz -o /restore/staging
EOF
}
log_msg () {
    local level=$1
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="$*"
    local output="[$timestamp] [$level] $message"
    case "$level" in
        ERROR)
            if [[ -n "$log_file" ]]; then
                echo "$output" >> "$log_file"
            fi
            # always log error to the console
            echo "$output" >&2
            ((error_count++))
        ;;
        WARN)
            if [[ -n "$log_file" ]]; then
                    echo "$output" >> "$log_file"
                else
                    echo "$output"
                fi
            ((warn_count++))
        ;;
        INFO|DEBUG)
            if [[ "$verbose" == true ]]; then
                if [[ -n "$log_file" ]]; then
                    echo "$output" >> "$log_file"
                else
                    echo "$output"
                fi
            fi
        ;;
    esac
}
validate_file() {
    [[ -f "$file" && -r "$file" ]] || return 1
}
validate_path() {
    [[ -n "$path" && -d "$path" && -r "$path" && -x "$path" ]] || return 1
}
validate_dest() {
    [[ -n "$dest" && -d "$dest" && -w "$dest" && -x "$dest" ]] || return 1
}
validate_mode() {
    case "$mode" in
        batch|single|verify|restore)
            return 0
        ;;
        *)
            return 1
        ;;
    esac
}
validate_options() {
    [[ $# -eq 1 ]] || return 1
    local option="$1"
    case "$mode:$option" in
        # ----- Global options (valid in any mode) -----
        *:-o|*:-l|*:-v|*:-h|*:--out|*:--log|*:--verbose|*:--help|*:--dry-run)
            return 0
        ;;
        # ----- Mode-specific options -----
        batch:--csv|batch:--generate|batch:-n|batch:--name)
            return 0
        ;;
        single:--file|single:--dir|single:-n|single:--name)
            return 0
        ;;
        verify:--archive)
            return 0
        ;;
        restore:--archive|restore:--overwrite)
            return 0
        ;;
        # ----- Everything else is invalid -----
        *)
            return 1
        ;;
    esac
}
validate_required_options() {
    log_msg INFO "Validating required options for mode=$mode"
    case $mode in
        single)
            validate_dest || { log_msg ERROR "Output directory not valid, $dest"; return 1; }
            if [[ -n "$file" && -n "$path" ]]; then
                log_msg ERROR "Can't use both --file and --dir"
                return 1
            fi
            if [[ -n $file ]]; then
                validate_file || { log_msg ERROR "File not readable: $file"; return 1; }
                return 0
            fi
            if [[ -n $path ]]; then
                validate_path || { log_msg ERROR "Directory not readble or traversable"; return 1; }
                return 0
            fi
            log_msg ERROR "single mode requires use of either --file FILE or --dir PATH"
            return 1
        ;;
        batch)
            validate_dest || { log_msg ERROR "Output directory not valid, $dest"; return 1; }
            if [[ "$generate" == true ]]; then
                [[ -z "$file" ]] || { log_msg ERROR "batch mode cannot use --generate with --csv"; return 1; }
                file="generate"
                return 0
            fi
            [[ -n "$file" ]] || { log_msg ERROR "Batch mode requires --csv FILE"; return 1; }
            validate_file || { log_msg ERROR "Batch mode can't read the CSV file"; return 1; }
            return 0
        ;;
        verify)
            [[ -n $file ]] || { log_msg ERROR "Verify mode requires --archive FILE"; return 1; }
            validate_file || { log_msg ERROR "Verify mode cannot read the archive $file"; return 1; }
            [[ -r "$file.sha256" ]] || { log_msg ERROR "Missing checksum file, $file.sha256"; return 1; }
            return 0
        ;;
        restore)
            [[ -n "$file" ]] || { log_msg ERROR "Restore mode requires --archive FILE"; return 1; }
            validate_file || { log_msg ERROR "Restore mode can't read the archive $file"; return 1; }
            validate_dest || { log_msg ERROR "Restore mode can't read or traverse the destination $dest"; return 1; }
            return 0
        ;;
    esac
}
validate_writable() {
    [ -w "$path" ] || return 1
}
run_make_manifest() {
    local date=$(date '+%Y%m%d')
    manifest="$dest/tar_manifest_$date.manifest"
    : > "$manifest" || { log_msg ERROR "Can't write to manifest: $manifest"; return 1; }
    [[ -r $file ]] || { log_msg ERROR "CSV Not Readable: $file"; return 1; }
    counter=2 # starting at line 2 of the CSV
    skipped=0
    log_msg INFO "Starting manifest generation from $file into $manifest"
    while IFS="," read -r filename usage filetype; do
        #skip first line, should start with filename
        [[ "$filename" ==  filename ]] && continue
        #trim leading and trailing whitespace
        filename="$(printf '%s' "$filename" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        #require absolute paths
        if [[ $filename != /* ]]; then
            log_msg WARN "Skipped line $counter, not an absolute path"
            ((counter++))
            ((skipped++))
            continue
        fi
        #skip if file/dir not readable
        if [[ -f $filename ]]; then
            [[ -r "$filename" ]] || { log_msg WARN "Skipped line $counter of CSV, file not readable"; ((skipped++)); ((counter++)); continue; }
        elif [[ -d $filename ]]; then
            [[ -r $filename && -x $filename ]] || { log_msg WARN "Skipped line $counter of CSV, path not r or x"; ((skipped++)); ((counter++)); continue; }
        else
            log_msg WARN "Skipped line $counter, path does not exist: $filename"
            ((skipped++))
            ((counter++))
            continue
        fi
        printf '%s\n' "$filename" | sed 's#^/##' >> "$manifest"
        ((counter++))
    done < $file
    # If no information actually got sent to the manifest because it was all garbage
    [[ -s $manifest ]] || { log_msg ERROR "No valid paths in $file, exiting"; return 1; }
    log_msg INFO "Tar manifest created at $manifest" >&2
    log_msg INFO "Total skipped entries: $skipped"
    sed -i -e 's/\r$//' -e '/^[[:space:]]*$/d' "$manifest"
    printf '%s\n' "$manifest"
    return 0
}
run_copy() {
    local input=$1
    local dest=$2
    if [[ "$dry_run" == true ]]; then
        log_msg INFO "Dry-Run: cp $input $dest"
        return 0
    fi
    log_msg INFO "Copying $input to $dest"
    run_silent_log_verbose cp -- "$input" "$dest"
}
run_tar_single() {
    local parent=$1
    local archive_name=$2
    local base=$3
    if [[ "$dry_run" == true ]]; then
        log_msg INFO "Dry-Run: tar -C $parent -czf $archive_name $base"
        return 0
    fi
    local start_time=$(date +'%Y%m%d%H%M%S')
    local start_seconds=$(date +%s)
    log_msg INFO "Started tar at $start_time"
    run_silent_log_verbose tar -C "$parent" -czf "$archive_name" "$base"
    local end_time=$(date +'%Y%m%d%H%M%S')
    local end_seconds=$(date +%s)
    log_msg INFO "Ended tar at $end_time. Total time is $(($end_seconds-$start_seconds))"
}
run_tar_batch() {
    local date
    local archive_name="$dest/$name.tar.gz"
    if [[ "$dry_run" == true ]]; then
        log_msg INFO "tar -C / -cvf $archive_name -T $manifest"
        return 0
    fi
    local start_time=$(date +'%Y%m%d%H%M%S')
    local start_seconds=$(date +%s)
    log_msg INFO "Started tar at $start_time"
    run_silent_log_verbose tar -C / -czvf "$archive_name" -T "$manifest" || return 1
    local end_time=$(date +'%Y%m%d%H%M%S')
    local end_seconds=$(date +%s)
    log_msg INFO "Ended tar at $end_time. Total time is $(($end_seconds-$start_seconds))"
    log_msg INFO "Generating checksum for $archive_name"
    run_checksum "$archive_name" || { log_msg WARN "Checksum generation failed for $archive_name"; return 1; } 
}
run_backup_single() {
    if [[ -n "$file" ]]; then
        local new_file
        if [[ -n "$name" ]]; then
            new_file=$name
        else
            local base="$(basename -- "$file")"
            local new_file="$base.bak"
        fi
        run_copy "$file" "$dest/$new_file" || return 1
        log_msg INFO "Generating checksum for $dest/$new_file"
        run_checksum "$dest/$new_file" || { log_msg WARN "Checksum generation failed for $file"; return 1; }
        return 0
    fi
    local dir_parent dir_base archive_name
    if [[ -n "$name" ]]; then
        archive_name="$dest/$name.tar.gz"
    else
        dir_parent="$(dirname -- "$path")"
        dir_base="$(basename -- "$path")"
        archive_name="$dest/$dir_base.tar.gz"
    fi
    run_tar_single "$dir_parent" "$archive_name" "$dir_base" || { log_msg ERROR "Tar failed to complete"; return 1; }
    log_msg INFO "Generating checksum for $archive_name"
    run_checksum "$archive_name" || { log_msg WARN "Checksum generation failed for $archive_name"; return 1; }
    return 0
}
run_silent_log_verbose() {
    if [[ $verbose == true ]]; then
        if [[ -n "$log_file" ]]; then
            "$@" >> "$log_file" 2>&1
        else
        "$@"
        fi
    else
        "$@" > /dev/null 2>&1
    fi
}
run_batch() {
    case $1 in
        generate)
            echo "filename,usage,filetype" > "$dest/example.csv"
            log_msg INFO "only filename is used right now" 
            return 0
        ;;
        *)
            manifest=$(run_make_manifest) || return 1
            run_tar_batch
            log_msg INFO "Tar generated"
            return 0
        ;;
    esac
}
run_verify() {
    local dir="$(dirname -- "$file")"
    local base="$(basename -- "$file")"
    log_msg INFO "Starting verification"
    ( cd "$dir" && run_silent_log_verbose sha256sum -c -- "$base.sha256" && log_msg INFO "Verify OK: $file" ) || log_msg INFO "Verify FAILED: $file" && return 1 
}
run_checksum() {
    local input_file="$1"
    local dir="$(dirname -- "$input_file")"
    local base="$(basename -- "$input_file")"
    if [[ "$dry_run" == true ]]; then
        log_msg INFO "cd $dir && sha256sum -- $base > $base.sha256"
    else
        { (cd "$dir" && sha256sum -- "$base" > "$base.sha256" ) && log_msg INFO "SHA256 checksum generated to $base.sha256"; } || { log_msg WARN "Checksum not generated"; return 1; }
    fi
}
run_restore() {
    # single file restore
    if [[ $file == *.bak ]]; then
        local base="$(basename $file)"
        local stripped="${base%.bak}"
        local target="$dest/$stripped"
        if [[ $dry_run == true ]]; then
            log_msg INFO "cp -- $file $target"
            return 0
        fi
        if [[ "$overwrite" != true && -e $target ]]; then
                log_msg ERROR "File already exists and --overwrite not set"
                return 1
        fi
        log_msg INFO "Restoring $file to $target"
        run_silent_log_verbose cp -- "$file" "$target" || return 1
        return 0
    fi
    # anything that is a tar
    if [[ $file == *.tar.gz ]]; then
        if [[ $dry_run == true ]]; then
            log_msg INFO "tar -xzf $file -C $dest"
            run_silent_log_verbose tar -tzf "$file"
            return 0
        fi
    fi
    log_msg INFO "Restoring archive $file to $dest"
    if [[ "$overwrite" == true ]]; then
        run_silent_log_verbose tar -xzf "$file" -C "$dest" --overwrite || return 1
        return 0
    else
        run_silent_log_verbose tar -xzf "$file" -C "$dest" --keep-old-files || return 1
        return 0
    fi
    log_msg ERROR "Unknown filetype, this only supports .bak and .tar.gz"
    return 1
}
finalize_exit() {
    log_msg INFO "Done: errors=$error_count warns=$warn_count"
    if (( error_count > 0 )); then
        exit 1
    elif (( warn_count > 0 )); then
        exit 2
    else
        exit 0
    fi
}
main() {
    [ $# -gt 0 ] || { usage; exit 1; }
    case "${1-}" in
        -h|--help|"")
            show_help
            exit 0
        ;;
    esac
    mode="$1"
    validate_mode || { echo "Invalid mode"; usage; exit 1; }
    shift
    while [ $# -gt 0 ]; do
        validate_options "$1" || { echo "Invalid option"; show_help; exit 1; }
        log_msg INFO "Mode: $mode file=$file path=$path dest=$dest name=$name dry_run=$dry_run verbose=$verbose"
        case "$1" in
            # Batch Mode
            --csv)
                file="$2"
                shift 2
            ;;
            --generate)
                generate=true
                shift
            ;;
            # Single Mode
            --file)
                file="$2"
                shift 2
            ;;
            --dir)
                path="$2"
                shift 2
            ;;
            # Single / Batch
            -n|--name)
                name="$2"
                # strip .tar.gz and .tar from name since i add them
                name="${name%tar.gz}"
                name="${name%tar}"
                shift 2
            ;;
            # Verify / Restore
            --archive)
                file="$2"
                shift 2
            ;;
            --overwrite)
                overwrite=true
                shift
            ;;
            # Global Options
            -o|--out)
                dest="$2"
                #if destination not root, strip the trailing /
                [[ $dest != / ]] && dest="${dest%/}"
                shift 2
            ;;
            -l|--log)
                if [[ -n "${2-}" && "$2" != -* ]]; then
                    log_file="$2"
                    shift 2
                else
                    log_file="backup_$(date +%F).log"
                    shift
                fi
            ;;
            -v|--verbose)
                verbose=true
                shift
            ;;
            -h|--help)
                show_help
                exit 0
            ;;
            --dry-run)
                dry_run=true
                verbose=true
                shift
            ;;
            *)
                echo "Unknown option: "$1"" >&2
                exit 1
            ;;
        esac
    done
    validate_required_options || { show_help; exit 1; }
    case "$mode" in
        batch)
            log_msg INFO "Starting Batch processing: "
            run_batch "$file" || { log_msg ERROR "Batch failed"; exit 1; }
            log_msg INFO "Batch completed"
        ;;
        single)
            log_msg INFO "Starting single backup"
            run_backup_single || { log_msg ERROR "Single backup failed"; exit 1; }
            log_msg INFO "Single backup finished"
        ;;
        verify)
            { run_verify && log_msg INFO "Checksums are the same"; } || { log_msg ERROR "Checksums did NOT match"; exit 1; }
        ;;
        restore)
            run_restore
        ;;
    esac
    finalize_exit
}
main "$@"
