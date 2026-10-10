#!/usr/bin/env bats
# shellcheck disable=SC1090,SC1091,SC2034
#
# Tests for remotecheck.
#
#   bats test/
#
# Unit tests need only bash and awk (jq is used when available).
# Integration tests run only when RC_TEST_TARGET is set, for example:
#
#   RC_TEST_TARGET=user@localhost RC_TEST_ARGS="-p 2222 -i ~/.ssh/test_key" bats test/
#
# Set RC_TEST_CONTAINER to the name of a running privileged container on the
# target to also check the container findings.
#
# The integration target must accept key-based SSH logins (multi-host scans
# use BatchMode).

setup() {
  RC="$BATS_TEST_DIRNAME/../remotecheck"
  EXTRA=()
  if [[ -n ${RC_TEST_ARGS:-} ]]; then read -r -a EXTRA <<<"$RC_TEST_ARGS"; fi
}

need_jq() {
  command -v jq >/dev/null 2>&1 || skip 'jq not installed'
}

need_target() {
  [[ -n ${RC_TEST_TARGET:-} ]] || skip 'RC_TEST_TARGET not set'
}

# Run the collector locally, as the remote side would, without SSH.
# Usage: run_collector_locally [quick|full] [0|1]
run_collector_locally() {
  # shellcheck source=../remotecheck
  source "$RC"
  {
    printf '%s\n' 'IFS= read -r SUDO_PW || SUDO_PW='
    printf '\n'
    collector_script
  } | REMOTE_SUDO_STATE=disabled REMOTE_LEVEL="${1:-quick}" REMOTE_SECURITY="${2:-0}" bash -s
}

# Load the collector's helper functions into the test shell without running it.
load_collector_helpers() {
  source "$RC"
  source <(collector_script | sed '/^main <\/dev\/null$/d')
}

# Check that every record is well formed and data rows match their columns.
assert_records_well_formed() {
  run awk -F'\t' '
    $1 !~ /^[SKREMN]$/ { print "bad record: " $0; bad = 1 }
    $1 == "S" { cols = ($4 == "kv") ? 0 : NF - 4 }
    $1 == "R" && NF - 1 != cols { print "column mismatch: " $0; bad = 1 }
    END { exit bad }
  ' "$1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# assert_sections FILE id... : the record file has exactly these sections, in order.
assert_sections() {
  local file=$1 expected actual
  shift
  expected="$*"
  actual=$(awk -F'\t' '$1 == "S" {printf "%s%s", (n++ ? " " : ""), $2}' "$file")
  [ "$actual" = "$expected" ] || { echo "expected: $expected"; echo "actual:   $actual"; return 1; }
}

sample_records() {
  printf 'M\tsudo_state\tdisabled\n'
  printf 'M\tprivileged\t0\n'
  printf 'S\thost\tHost\tkv\n'
  printf 'K\thost\tHost\tweb1\n'
  printf 'S\tsecurity_checks\tBasic security checks\ttable\tcheck=CHECK\tstatus=STATUS\tdetail=DETAIL\n'
  printf 'R\tSSH root login\tWARNING\tPermitRootLogin yes\n'
  printf 'R\tFirewall\tREVIEW\tq"uo\\te\001x %s\n' "$(printf 'long%.0s' {1..30})"
  printf 'R\tUID 0\tPASS\tonly root\n'
  printf 'S\tempty\tEmpty section\ttable\ta=A\n'
  printf 'E\tnothing here\n'
  printf 'N\tclosing note\n'
}

# ---- Command line -----------------------------------------------------------

@test "--version prints the version" {
  run bash "$RC" --version
  [ "$status" -eq 0 ]
  [[ $output =~ ^remotecheck\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "--help exits 0 and shows usage" {
  run bash "$RC" --help
  [ "$status" -eq 0 ]
  [[ $output == *"Usage:"* ]]
  [[ $output == *"--fail-on"* ]]
}

@test "no target is a usage error" {
  run bash "$RC"
  [ "$status" -eq 2 ]
}

@test "invalid ports are rejected" {
  for port in 0 65536 abc 123456 -1; do
    run bash "$RC" -p "$port" user@host
    [ "$status" -eq 2 ]
  done
}

@test "missing identity file is rejected" {
  run bash "$RC" -i /nonexistent/key user@host
  [ "$status" -eq 2 ]
  [[ $output == *"Identity file"* ]]
}

@test "unknown option is rejected" {
  run bash "$RC" --bogus user@host
  [ "$status" -eq 2 ]
}

@test "-o requires Key=Value and refuses Control* options" {
  run bash "$RC" -o NoEquals user@host
  [ "$status" -eq 2 ]
  run bash "$RC" -o ControlPath=/tmp/x user@host
  [ "$status" -eq 2 ]
  run bash "$RC" -o controlmaster=no user@host
  [ "$status" -eq 2 ]
}

@test "--fail-on, -j and sudo flag combinations are validated" {
  run bash "$RC" --fail-on high user@host
  [ "$status" -eq 2 ]
  run bash "$RC" -j 0 user@host
  [ "$status" -eq 2 ]
  run bash "$RC" -j 65 user@host
  [ "$status" -eq 2 ]
  run bash "$RC" --no-sudo --ask-sudo-pass user@host
  [ "$status" -eq 2 ]
  run bash "$RC" --ask-sudo-pass user@host
  [ "$status" -eq 2 ]
  [[ $output == *"--full or --security"* ]]
  run bash "$RC" --quick --full user@host
  [ "$status" -eq 2 ]
}

@test "targets starting with - or containing spaces are rejected" {
  run bash "$RC" -- -oProxyCommand=x
  [ "$status" -eq 2 ]
  run bash "$RC" 'user@host name'
  [ "$status" -eq 2 ]
}

@test "missing hosts file is rejected" {
  run bash "$RC" -f /nonexistent/hosts
  [ "$status" -eq 2 ]
}

# ---- Helpers ------------------------------------------------------------------

@test "hosts file: comments, blank lines and duplicates are handled" {
  source "$RC"
  local file="$BATS_TEST_TMPDIR/hosts"
  printf '# comment\n\n  alice@web1  \nbob@db1 # trailing comment\nalice@web1\n\t\ncarol@cache1' >"$file"
  TARGETS=()
  read_hosts_file "$file"
  normalize_targets
  [ "${#TARGETS[@]}" -eq 3 ]
  [ "${TARGETS[0]}" = 'alice@web1' ]
  [ "${TARGETS[1]}" = 'bob@db1' ]
  [ "${TARGETS[2]}" = 'carol@cache1' ]
}

@test "count_findings counts WARNING and REVIEW in status columns only" {
  source "$RC"
  local file="$BATS_TEST_TMPDIR/rec"
  sample_records >"$file"
  printf 'S\tother\tOther\ttable\tname=NAME\nR\tWARNING\n' >>"$file"
  run count_findings "$file"
  [ "$output" = '1 1' ]
}

@test "report file names are sanitized" {
  source "$RC"
  JSON=0
  [ "$(report_file_name 'user@host:22/x')" = 'user@host_22_x.txt' ]
  JSON=1
  [ "$(report_file_name 'web1')" = 'web1.json' ]
}

# ---- Renderer -----------------------------------------------------------------

@test "table renderer draws sections, truncates long values and counts findings" {
  source "$RC"
  run render_report 'web1' 0 0 < <(sample_records)
  [ "$status" -eq 0 ]
  [[ $output == *"remotecheck report: web1"* ]]
  [[ $output == *"Basic security checks"* ]]
  [[ $output == *"..."* ]]
  [[ $output == *"| nothing here"* ]]
  [[ $output == *"Findings: 1 warning(s), 1 review item(s)"* ]]
  [[ $output == *"closing note"* ]]
  [[ $output != *$'\033['* ]]
}

@test "table renderer uses color only when asked" {
  source "$RC"
  run render_report 'web1' 0 1 < <(sample_records)
  [[ $output == *$'\033['* ]]
}

@test "JSON renderer produces valid, escaped, structured JSON" {
  need_jq
  source "$RC"
  local out="$BATS_TEST_TMPDIR/out.json"
  render_report 'web1' 1 0 < <(sample_records) >"$out"
  jq -e . "$out" >/dev/null
  [ "$(jq -r .target "$out")" = 'web1' ]
  [ "$(jq -r .findings.warning "$out")" = 1 ]
  [ "$(jq -r .findings.review "$out")" = 1 ]
  [ "$(jq -r '.sections[0].data.host' "$out")" = 'web1' ]
  [ "$(jq -r '.sections[1].rows[0].status' "$out")" = 'WARNING' ]
  [[ $(jq -r '.sections[1].rows[1].detail' "$out") == 'q"uo\te x long'* ]]
  [ "$(jq -r '.sections[2].message' "$out")" = 'nothing here' ]
  [ "$(jq -r '.sections[2].rows | length' "$out")" = 0 ]
}

# ---- Collector (runs locally, no SSH) -----------------------------------------

@test "addr_class classifies listening addresses" {
  load_collector_helpers
  [ "$(addr_class '0.0.0.0:22')" = all ]
  [ "$(addr_class '[::]:22')" = all ]
  [ "$(addr_class '*:68')" = all ]
  [ "$(addr_class '127.0.0.53%lo:53')" = loopback ]
  [ "$(addr_class '[::1]:631')" = loopback ]
  [ "$(addr_class '10.1.2.3:5432')" = private ]
  [ "$(addr_class '172.20.0.1:80')" = private ]
  [ "$(addr_class '192.168.1.10:443')" = private ]
  [ "$(addr_class '[fe80::1%eth0]:546')" = private ]
  [ "$(addr_class '172.32.0.1:80')" = public ]
  [ "$(addr_class '203.0.113.7:443')" = public ]
}

@test "port_service and exposure_risk know common ports" {
  load_collector_helpers
  [ "$(port_service tcp 22)" = SSH ]
  [ "$(port_service tcp 5984)" = CouchDB ]
  [ "$(port_service tcp 5901)" = VNC ]
  [ "$(port_service tcp 6379)" = Redis ]
  [ "$(port_service tcp 12345)" = - ]
  [[ $(exposure_risk tcp 6379) == WARNING\|* ]]
  [[ $(exposure_risk tcp 2375) == WARNING\|* ]]
  [[ $(exposure_risk tcp 5432) == REVIEW\|* ]]
  run exposure_risk tcp 22
  [ "$status" -eq 1 ]
  run exposure_risk tcp 443
  [ "$status" -eq 1 ]
}

@test "detect_roles uses process names and reachable ports" {
  load_collector_helpers
  local procs ports
  procs=$'nginx           nginx: master process /usr/sbin/nginx\npostgres        /usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql\njava            java -cp /opt/es org.elasticsearch.bootstrap.Elasticsearch\nsshd            sshd: /usr/sbin/sshd -D'
  ports='tcp/22 tcp/443 tcp/6379'
  run detect_roles "$procs" "$ports"
  [ "$status" -eq 0 ]
  [[ $output == *$'Web server\thigh\tprocess: nginx; port: tcp/443'* ]]
  [[ $output == *$'Database: PostgreSQL\thigh\tprocess: postgres'* ]]
  [[ $output == *$'Search: Elasticsearch/OpenSearch\thigh\tprocess: java'* ]]
  [[ $output == *$'Database: Redis\tmedium\tport: tcp/6379'* ]]
  [[ $output != *"Mail server"* ]]
}

@test "quick collector: inventory sections only, well formed" {
  local rec="$BATS_TEST_TMPDIR/quick.rec"
  run_collector_locally quick 0 >"$rec"
  assert_sections "$rec" host os roles services_offered network users processes summary
  assert_records_well_formed "$rec"
  grep -q $'^M\tscan_level\tquick$' "$rec"
  grep -q $'^M\tsecurity\t0$' "$rec"
}

@test "full collector with security checks: every section, well formed" {
  local rec="$BATS_TEST_TMPDIR/full.rec"
  run_collector_locally full 1 >"$rec"
  assert_sections "$rec" host os roles services_offered network users resources network_interfaces \
    listening_sockets running_services failed_units processes security_checks filesystem_checks \
    package_updates temp_files exposed_services containers container_list summary
  assert_records_well_formed "$rec"
  grep -q $'^M\tsudo_state\tdisabled$' "$rec"
}

@test "collector output renders as valid JSON with scan details" {
  need_jq
  source "$RC"
  local rec="$BATS_TEST_TMPDIR/local.rec" out="$BATS_TEST_TMPDIR/local.json"
  run_collector_locally full 1 >"$rec"
  render_report 'localhost' 1 0 <"$rec" >"$out"
  jq -e '.sections | length == 20' "$out" >/dev/null
  [ "$(jq -r .scan.level "$out")" = full ]
  [ "$(jq -r .scan.security "$out")" = true ]
}

# ---- Integration (real SSH) ---------------------------------------------------

@test "integration: default quick scan needs no sudo" {
  need_target
  need_jq
  local out="$BATS_TEST_TMPDIR/quick.json"
  run bash -c 'bash "$0" --json "${@}" > "'"$out"'"' "$RC" "${EXTRA[@]}" "$RC_TEST_TARGET"
  [ "$status" -eq 0 ]
  jq -e . "$out" >/dev/null
  [ "$(jq -r .target "$out")" = "$RC_TEST_TARGET" ]
  [ "$(jq -r .scan.level "$out")" = quick ]
  [ "$(jq -r .sudo.state "$out")" = unused ]
  [ "$(jq -r '[.sections[].id] | join(" ")' "$out")" = 'host os roles services_offered network users processes summary' ]
}

@test "integration: full scan with security checks" {
  need_target
  need_jq
  local out="$BATS_TEST_TMPDIR/full.json"
  run bash -c 'bash "$0" --json --full --security --no-sudo "${@}" > "'"$out"'"' "$RC" "${EXTRA[@]}" "$RC_TEST_TARGET"
  [ "$status" -eq 0 ]
  jq -e . "$out" >/dev/null
  [ "$(jq -r .sudo.state "$out")" = disabled ]
  [ "$(jq -r '.sections | length' "$out")" = 20 ]
}

@test "integration: container checks flag a privileged container" {
  need_target
  need_jq
  [[ -n ${RC_TEST_CONTAINER:-} ]] || skip 'RC_TEST_CONTAINER not set'
  local out="$BATS_TEST_TMPDIR/containers.json"
  run bash -c 'bash "$0" --json --security "${@}" > "'"$out"'"' "$RC" "${EXTRA[@]}" "$RC_TEST_TARGET"
  [ "$status" -eq 0 ]
  run jq -r '.sections[] | select(.id == "containers") | .rows[] | select(.check == "Privileged containers") | "\(.status) \(.detail)"' "$out"
  [[ $output == "WARNING "*"$RC_TEST_CONTAINER"* ]]
  run jq -r '.sections[] | select(.id == "container_list") | .rows[].name' "$out"
  [[ $output == *"$RC_TEST_CONTAINER"* ]]
}

@test "integration: table output and --fail-on exit status" {
  need_target
  run bash "$RC" --full --no-sudo --fail-on review "${EXTRA[@]}" "$RC_TEST_TARGET"
  [[ $status -eq 0 || $status -eq 3 ]]
  [[ $output == *"remotecheck report: $RC_TEST_TARGET (full scan)"* ]]
  [[ $output == *"Findings:"* ]]
}

@test "integration: --out writes one file per host" {
  need_target
  local dir="$BATS_TEST_TMPDIR/reports"
  run bash "$RC" --no-sudo --out "$dir" "${EXTRA[@]}" "$RC_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$(find "$dir" -name '*.txt' | wc -l)" -eq 1 ]
}

@test "integration: multi-host JSON with one failing host" {
  need_target
  need_jq
  local out="$BATS_TEST_TMPDIR/multi.json"
  local bad="rc-no-such-user-$$@${RC_TEST_TARGET#*@}"
  run bash -c 'bash "$0" --json --no-sudo -j 2 "${@}" > "'"$out"'"' "$RC" "${EXTRA[@]}" "$RC_TEST_TARGET" "$bad"
  [ "$status" -eq 1 ]
  jq -e . "$out" >/dev/null
  [ "$(jq -r '.hosts | length' "$out")" = 1 ]
  [ "$(jq -r '.failed | length' "$out")" = 1 ]
  [ "$(jq -r '.failed[0].target' "$out")" = "$bad" ]
}
