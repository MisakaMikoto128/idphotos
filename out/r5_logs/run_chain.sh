#!/usr/bin/env bash
# qa-batch：r5 host 侧 P0 车道（11 步）+ 3 次来源绑定，逐步记退出码。
# 与 r4 的链条逐字相同（口径见 out/QA_r4.md §1）。
# 每一步的 stdout+stderr 落 out/r5_logs/<步名>.log；退出码落 exit_codes.txt。
cd /c/Users/liuyu/Desktop/WorkPlace/idPhotos || exit 99
L=out/r5_logs
: > "$L/exit_codes.txt"

run() {
  name="$1"; shift
  "$@" > "$L/$name.log" 2>&1
  code=$?
  echo "$code $name" >> "$L/exit_codes.txt"
  echo "[$code] $name"
}

run 01_resolve              dart run test/batch/p0_resolve_check.dart
run 02_compose              flutter test test/batch/p0_compose_test.dart
run 02b_prov_after_compose  python test/batch/p0_provenance_check.py after-compose
run 03_alpha_dump           flutter test test/batch/p0_alpha_dump_test.dart
run 04_residual             python test/batch/p0_output_residual.py
run 05_alpha_scan           flutter test test/batch/p0_alpha_scan_test.dart
run 06_alpha_holes          python test/batch/p0_alpha_holes.py
run 07_selfcheck            dart run test/batch/p0_selfcheck_run.dart
run 08_coverage             flutter test test/batch/p0_coverage_test.dart
run 08b_prov_after_coverage python test/batch/p0_provenance_check.py after-coverage
run 09_verify_geo           python test/batch/p0_verify_geo.py
run 10_finalize             python test/batch/p0_finalize_v1.py --strict
run 10b_prov_final          python test/batch/p0_provenance_check.py final
run 11_resolve_recheck      dart run test/batch/p0_resolve_check.dart
echo "DONE" >> "$L/exit_codes.txt"
