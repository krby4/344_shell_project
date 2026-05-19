#!/usr/bin/env bash
# test my script by creating files, running the different modes, and generating log files
set -euo pipefail

working_dir=$(pwd)
test_dir="$working_dir/backup_tests"
log_dir="$working_dir/logs"
out_dir="$working_dir/backup_out"
restore_dir="$working_dir/restore"
#cleans up previous tests
rm -rf "$test_dir" "$log_dir" "$out_dir" "$restore_dir"
# make files to backup and csv for use with batch mode
mkdir -p "$test_dir" "$log_dir" "$out_dir" "$restore_dir"
test_csv="$working_dir/test_csv.csv"
echo filename,usage,filetype > "$test_csv"
( cd "$test_dir"
    for i in {1..5}; do
        touch "test_$i.txt"
        echo test $i >> "test_$i.txt"
        if [[ $i == 4 ]]; then
            echo "     $working_dir/test_$i.txt" >> $test_csv
        elif [[ $i == 5 ]]; then
            echo "$test_dir/test_$i.txt     " >> $test_csv
        else
            echo "$test_dir/test_$i.txt" >> $test_csv
        fi
    done
    echo >> "$test_csv"
)
#make a csv out of generated files
#test single file
bash ./backup_344.sh single --file "$test_dir/test_1.txt" -o "$out_dir" --dry-run -v -l "$log_dir/single_file_backup_dry__test1.log"
bash ./backup_344.sh single --file "$test_dir/test_1.txt" -o "$out_dir" -v -l "$log_dir/single_file_backup_test1.log"
bash ./backup_344.sh verify --archive "$out_dir/test_1.txt.bak" -v -l "$log_dir/single_file_backup_verify.log"
bash ./backup_344.sh restore --archive "$out_dir/test_1.txt.bak" -o "$restore_dir" -v -l "$log_dir/single_file_backup_restore.log"
bash ./backup_344.sh restore --archive "$out_dir/test_1.txt.bak" -o "$restore_dir" -v -l "$log_dir/single_file_backup_overwriteoff_restore.log"
bash ./backup_344.sh restore --archive "$out_dir/test_1.txt.bak" -o "$restore_dir" -v --overwrite -l "$log_dir/single_file_backup_overwriteon_restore.log"
#test single dir
bash ./backup_344.sh single --dir "$test_dir" -o "$out_dir" --dry-run -v -l "$log_dir/single_dir_backup_dry__test1.log"
bash ./backup_344.sh single --dir "$test_dir" -o "$out_dir" -v -l "$log_dir/single_dir_backup_test1.log"
bash ./backup_344.sh verify --archive "$out_dir/test_1.txt.bak" -v -l "$log_dir/single_dir_backup_verify.log"
bash ./backup_344.sh restore --archive "$out_dir/test_1.txt.bak" -o "$restore_dir" -v -l "$log_dir/single_dir_backup_restore.log"
bash ./backup_344.sh restore --archive "$out_dir/test_1.txt.bak" -o "$restore_dir" -v -l "$log_dir/single_dir_backup_overwriteoff_restore.log"
bash ./backup_344.sh restore --archive "$out_dir/test_1.txt.bak" -o "$restore_dir" -v --overwrite -l "$log_dir/single_dir_backup_overwriteon_restore.log"
#test batch
bash ./backup_344.sh batch --generate -o "$out_dir"
bash ./backup_344.sh batch --csv "$test_csv" -o "$out_dir" -v --dry-run -l "$log_dir/batch_backup_dry_verify.log"
bash ./backup_344.sh batch --csv "$test_csv" -o "$out_dir" -n batch_test -v -l "$log_dir/batch_backup_verify.log"
bash ./backup_344.sh verify --archive "$out_dir/batch_test.tar.gz" -v -l "$log_dir/batch_backup_verify.log"
bash ./backup_344.sh restore --archive "$out_dir/batch_test.tar.gz" -o "$restore_dir" -v -l "$log_dir/batch_backup_restore.log"
bash ./backup_344.sh restore --archive "$out_dir/batch_test.tar.gz" -o "$restore_dir" -v -l "$log_dir/batch_backup_overwriteoff_restore.log"
bash ./backup_344.sh restore --archive "$out_dir/batch_test.tar.gz" -o "$restore_dir" -v --overwrite -l "$log_dir/batch_backup_overwriteon_restore.log"
# help and usage
bash ./backup_344.sh
bash ./backup_344.sh -h
# some bad input to test
echo "single bad input, cant have --file and --dir" > badinput.txt
bash ./backup_344.sh single --file test --dir test2 -o test >> badinput.txt 2>&1
echo "batch bad input, no csv file" > badinput.txt
bash ./backup_344.sh batch -o test3 >> badinput.txt 2>&1
echo "verify bad input, no input archive" > badinput.txt
bash ./backup_344.sh verify -l >> badinput.txt 2>&1
echo "restore bad input, no archive"
bash ./backup_344.sh restore -l >> badinput.txt 2>&1