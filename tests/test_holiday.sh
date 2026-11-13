#!/usr/bin/env bash
. "$(dirname "$0")/helper.sh"
lib()   { ( . "$BIN/lib.sh"; "$@" ); }
sync()  { bash "$BIN/holiday-sync.sh"; }
start() { bash "$BIN/pod-start.sh" "$@"; }
# 경로는 setup 이후에 정해지므로 함수로 계산한다
api()    { echo "$VOC_HOME/holidays-api.txt"; }
marker() { echo "$VOC_HOME/state/holiday_sync_failed"; }

t_sync_ok_this_and_next_year() {
  sync || fail "sync should succeed"
  assert_eq "$(events)" "HOLIDAY_SYNC:ok" "events"
  assert_eq "$(last .count)" 30 "15 + 15 dates"
  assert_eq "$(last .next_year_count)" 15 "next year"
  assert_file_has "$(api)" "2026-12-25"
  assert_file_has "$(api)" "2027-01-01"
  grep -qx 2026-04-02 "$(api)" && fail "isHoliday=N must be excluded"
  assert_no_file "$(marker)"
}

t_sync_next_year_missing_is_ok() {
  FAKE_HOLIDAY_MAX_YEAR=2026 sync || fail "next year empty is not a failure"
  assert_eq "$(last .count)" 15 "this year only"
  assert_eq "$(last .next_year_count)" 0 "next year 0"
}

t_sync_retries_then_ok() {
  FAKE_HOLIDAY_FAILS=2 sync || fail "3rd attempt succeeds"
  assert_eq "$(last .result)" ok "result"
  assert_eq "$(calls_count 'HOLIDAY_API 2026')" 3 "3 attempts this year"
  assert_eq "$(calls_count 'SLEEP 600')" 2 "2 waits"
}

t_sync_fail_sets_marker_and_notifies() {
  FAKE_HOLIDAY_MODE=fail sync && fail "should fail"
  assert_eq "$(events)" "HOLIDAY_SYNC:failed" "events"
  assert_eq "$(last .attempts)" 3 "attempts"
  [ -f "$(marker)" ] || fail "marker must exist"
  assert_eq "$(calls_count 'NOTIFY Holiday sync failed')" 1 "notify"
}

t_sync_bad_responses_fail() {
  local m
  for m in badcode xml few; do
    rm -f "$(marker)" "$T/hapi_n"
    FAKE_HOLIDAY_MODE=$m sync && fail "$m should fail"
    [ -f "$(marker)" ] || fail "$m: marker must exist"
  done
  true
}

t_sync_fail_keeps_old_file() {
  echo 2026-11-16 > "$(api)"
  FAKE_HOLIDAY_MODE=fail sync || true
  assert_eq "$(cat "$(api)")" 2026-11-16 "old api file kept"
}

t_sync_success_clears_marker() {
  touch "$(marker)"
  sync
  assert_no_file "$(marker)"
}

t_api_holiday_skips_start() {
  sync
  VOC_TODAY=2026-12-25 start
  assert_eq "$(last .result)" skipped_holiday "API holiday skips"
}

t_failed_week_runs_on_api_holiday() {
  echo 2026-11-16 > "$(api)"
  touch "$(marker)"
  start || fail "should start on weekday when sync failed"
  assert_eq "$(last .result)" ok "runs despite API holiday"
}

t_manual_holiday_applies_even_when_failed() {
  echo 2026-11-16 >> "$VOC_HOME/holidays.txt"
  touch "$(marker)"
  start
  assert_eq "$(last .result)" skipped_holiday "manual holiday always applies"
}

t_holiday_dates_single_object_item() {
  local j='{"response":{"header":{"resultCode":"00"},"body":{"items":{"item":{"isHoliday":"Y","locdate":20261225}}}}}'
  assert_eq "$(lib holiday_dates "$j")" 2026-12-25 "single item object"
}

t_holiday_dates_empty_items_string() {
  local j='{"response":{"header":{"resultCode":"00"},"body":{"items":"","totalCount":0}}}'
  lib holiday_dates "$j" && fail "empty must return non-zero"
  true
}

t_sync_next_year_fetch_error_keeps_old_next_year() {
  echo 2027-01-01 > "$(api)"
  FAKE_HOLIDAY_FAIL_YEAR=2027 sync || fail "this year ok -> sync ok"
  assert_file_has "$(api)" "2027-01-01"
  assert_eq "$(last .next_year_count)" 1 "carried count"
}

run_tests t_sync_next_year_fetch_error_keeps_old_next_year t_sync_ok_this_and_next_year t_sync_next_year_missing_is_ok t_sync_retries_then_ok \
  t_sync_fail_sets_marker_and_notifies t_sync_bad_responses_fail t_sync_fail_keeps_old_file \
  t_sync_success_clears_marker t_api_holiday_skips_start t_failed_week_runs_on_api_holiday \
  t_manual_holiday_applies_even_when_failed t_holiday_dates_single_object_item t_holiday_dates_empty_items_string
