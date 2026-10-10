# remotecheck

**remotecheck** is an open-source Bash utility for remotely collecting Linux host inventory and performing a set of basic security checks over SSH, on one host or many.

It is designed to provide a quick, readable snapshot of a server while continuing to collect information when sudo is unavailable.

## Features

- Connects to remote Linux hosts over SSH, reusing a single shared connection per host.
- Scans one host or many, in parallel, from the command line or a hosts file, with a summary table at the end.
- Collects host identity, OS and kernel information, uptime, memory, swap, load and disk usage, network interfaces, listening sockets, systemd services, failed units, and a process sample.
- Runs basic security checks: SSH configuration, UID 0 and empty-password accounts, firewall, SELinux/AppArmor, pending reboot, time synchronization, exposed services, SUID/SGID files, world-writable directories, package updates, and automatic updates.
- Tries passwordless sudo first; if unavailable, offers a hidden password prompt. Press **Enter** to continue without sudo, or pass `--no-sudo` to skip sudo entirely.
- Produces a colored, bordered terminal report, or structured JSON for scripting and automation.
- Optional exit status based on findings (`--fail-on`) for CI and monitoring.
- Supports custom ports, identity files, jump hosts, and extra SSH options.

## Requirements

On the local machine:

- Bash
- OpenSSH client (`ssh`)
- `awk`, `mktemp`, `tr`
- `iconv` (optional; used to drop invalid UTF-8 so JSON output stays valid)

On the remote host:

- **Bash** (required; the collector runs as `bash -s`). The user's login shell can be anything.
- `awk`, plus common Linux utilities when available: `hostname`, `id`, `uname`, `uptime`, `df`, `ip`, `ss`, `systemctl`, `ps`, `find`, `stat`, `timeout`, and a supported package manager (`apt-get`, `dnf`, or `yum`). Checks are skipped or marked `INCONCLUSIVE` when a utility is unavailable.
- `sudo` (optional) for privileged checks.

## Installation

Clone or download this repository, then make the script executable:

```bash
chmod +x remotecheck
```

You can run it from the repository directory or place it somewhere in your `PATH`.

## Usage

```text
remotecheck [options] user@server [user@server ...]
remotecheck [options] -f HOSTS_FILE
```

| Option | Description |
| --- | --- |
| `--json` | Output structured JSON |
| `--out DIR` | Also write one report file per host into `DIR` |
| `--fail-on LEVEL` | Exit with status 3 if any finding is at `LEVEL` or worse (`review` or `warning`) |
| `-p PORT` | SSH port, 1–65535 (default: from your ssh config, else 22) |
| `-i FILE` | SSH identity/private-key file |
| `-J JUMP` | Jump host(s), passed to `ssh -J` |
| `-o OPTION` | Extra ssh option as `Key=Value` (repeatable) |
| `--no-sudo` | Do not try sudo and never prompt for a password |
| `--ask-sudo-pass` | Prompt once for a sudo password before scanning and use it where passwordless sudo is unavailable |
| `-f FILE` | Read targets from a file (repeatable) |
| `-j N` | Hosts scanned in parallel, 1–64 (default: 5) |
| `-h`, `--help` | Show help |
| `-V`, `--version` | Show version |

Basic scan:

```bash
./remotecheck user@server
```

Custom port and identity file:

```bash
./remotecheck -p 2222 -i ~/.ssh/id_ed25519 user@server
```

Through a jump host, with an extra SSH option:

```bash
./remotecheck -J bastion.example.com -o ConnectTimeout=5 user@10.0.0.12
```

Non-interactive JSON scan for scripts or cron (no sudo prompt):

```bash
./remotecheck --json --no-sudo user@server
```

Fail a CI job or monitoring check when anything rated `WARNING` is found:

```bash
./remotecheck --no-sudo --fail-on warning user@server
```

### SSH configuration

`remotecheck` uses your normal OpenSSH client, so everything in `~/.ssh/config` applies: host aliases, `User`, `Port`, `IdentityFile`, `ProxyJump`, and so on. With a `Host web1` entry you can simply run `./remotecheck web1`. `-p` is only passed to ssh when you give it, so ports set in your config are respected.

Options given with `-o` take precedence over the script's defaults (for example `-o ConnectTimeout=30`). `ControlMaster`, `ControlPath`, and `ControlPersist` are reserved: the script opens one shared connection per host in a private temporary directory and closes it on exit, so you authenticate only once per host.

Note that `-i` applies to the target host only. If a jump host needs its own key, configure it in `~/.ssh/config`.

## Scanning multiple hosts

Pass several targets, a hosts file, or both:

```bash
./remotecheck web1 web2 db1
./remotecheck -f hosts.txt -j 10 --out reports/
```

A hosts file has one target per line. Blank lines and anything after `#` are ignored, and duplicate targets are scanned once:

```text
# production
deploy@web1.example.com
deploy@web2.example.com
db1            # alias from ~/.ssh/config
```

In multi-host mode:

- Reports print one after another, followed by a **Host summary** table with each host's result and its warning and review counts. Progress messages go to stderr when it is a terminal.
- `--out DIR` also writes one file per host (`DIR/<target>.txt`, or `.json` with `--json`). Characters other than letters, digits, `.`, `_`, `@`, and `-` in file names are replaced with `_`.
- SSH runs in `BatchMode`, so hosts must accept key or agent authentication, and their host keys must already be in `known_hosts` (or pass `-o StrictHostKeyChecking=accept-new`).
- There is no per-host sudo prompt. Use `--ask-sudo-pass` to enter one password up front; it is tried on each host where passwordless sudo is unavailable.
- A host that cannot be scanned does not stop the others. It is listed as `FAILED` with the reason, and the exit status is 1.

## Example output

Excerpt from a terminal run (colors removed):

```text
remotecheck report: web1

System resources
+--------------+---------+------------------------------------------+
| CHECK        | STATUS  | DETAIL                                   |
+--------------+---------+------------------------------------------+
| Memory       | PASS    | 6120 MiB available of 7963 MiB (76%)     |
| Swap         | INFO    | no swap configured                       |
| Load average | INFO    | 0.21 0.12 0.09 (1/5/15 min) on 4 CPU(s)  |
| Disk /       | REVIEW  | 84% used of 40G (/dev/sda1)              |
+--------------+---------+------------------------------------------+

Basic security checks
+------------------------------+--------------+------------------------------------------------+
| CHECK                        | STATUS       | DETAIL                                         |
+------------------------------+--------------+------------------------------------------------+
| SSH root login               | PASS         | PermitRootLogin no                             |
| SSH password authentication  | REVIEW       | enabled                                        |
| SSH configuration source     | INFO         | sshd -T (Match blocks not evaluated)           |
| Accounts with UID 0          | PASS         | only root                                      |
| Accounts with empty password | PASS         | none                                           |
| Firewall                     | PASS         | ufw enabled                                    |
| Mandatory access control     | PASS         | AppArmor enabled, 32 profile(s) enforcing      |
| Reboot required              | REVIEW       | reboot-required flag set (3 package(s))        |
| Time synchronization         | PASS         | clock synchronized                             |
| Services on all interfaces   | INFO         | 2: tcp/22, tcp/443                             |
+------------------------------+--------------+------------------------------------------------+

Findings: 0 warning(s), 3 review item(s)
```

Values longer than a column are shortened and end with `...`. The JSON output always contains the full values.

## Checks

Each check reports one of these statuses:

| Status | Meaning |
| --- | --- |
| `PASS` | Looks fine |
| `INFO` | Informational, no judgement |
| `REVIEW` | Worth a look; may be intended |
| `WARNING` | Likely a problem |
| `INCONCLUSIVE` | Could not be determined (missing tool, missing privileges) |

| Section | Check | Notes |
| --- | --- | --- |
| System resources | Memory | `REVIEW` below 20% available, `WARNING` below 10% |
| | Swap | `REVIEW` at 80% used or more |
| | Load average | `REVIEW` when the 5-minute load is above 2× the CPU count |
| | Disk / Inodes | Per filesystem: `REVIEW` at 80%, `WARNING` at 90%. Inode rows appear only from 80%. Container and virtual filesystems are skipped. |
| Basic security checks | SSH root login, password authentication | Read with `sshd -T` when possible (usually needs sudo); global settings only, per-user or per-address `Match` blocks are not evaluated. Without sudo, `/etc/ssh/sshd_config.d/*.conf` and `/etc/ssh/sshd_config` are parsed as an approximation, and unset options are shown with OpenSSH defaults marked `(default)`. |
| | Accounts with UID 0 | `WARNING` for any UID 0 account other than root |
| | Accounts with empty password | Reads `/etc/shadow`; needs sudo |
| | Firewall | ufw (`/etc/ufw/ufw.conf`) or firewalld, else nftables/iptables rules (needs sudo). `PASS` when a firewall is enabled or the input policy is drop. |
| | Mandatory access control | SELinux mode, or AppArmor with the number of enforcing profiles (needs sudo) |
| | Reboot required | Debian/Ubuntu `reboot-required` flag, `needs-restarting -r` on RHEL-family systems, otherwise the running kernel compared with the newest installed one |
| | Time synchronization | `timedatectl`, or `chronyc tracking` |
| | Services on all interfaces | Listening sockets bound to all addresses (`0.0.0.0`, `[::]`, `*`). Each socket's scope is also shown in the socket table. |
| Filesystem permission checks | SUID/SGID outside system dirs | Files with setuid/setgid bits outside `/usr/bin`, `/usr/sbin`, `/usr/lib*` and similar |
| | World-writable dirs, no sticky bit | Directories anyone can write to where users can delete each other's files |
| Package updates | Pending updates | `apt-get -s dist-upgrade` (simulation, no root needed; packages held with `apt-mark hold` are excluded), or `dnf`/`yum check-update` using cached metadata only. Results reflect the last metadata refresh, so the age of the apt package lists is shown. |
| | Automatic updates | unattended-upgrades on Debian/Ubuntu; dnf-automatic or yum-cron on RHEL-family systems |
| World-writable temporary files | World-writable files | Regular files in `/tmp` and `/var/tmp` writable by everyone |

The filesystem permission checks walk local filesystems (`/`, `/home`, `/opt`, `/srv`, `/var`, `/tmp`, `/usr/local`, without crossing mount points, skipping container storage) once, with a 60-second limit. On very large trees the result is marked as partial. Without sudo, directories the user cannot read are skipped.

## Sudo behavior

`remotecheck` first checks whether passwordless sudo works on each host.

- If passwordless sudo works, the scan uses it for supported privileged checks.
- Single host: otherwise, the script prompts for a sudo password without echoing it (only when a terminal is available). Press **Enter** to skip sudo and continue with unprivileged checks.
- Multiple hosts: there is no per-host prompt. With `--ask-sudo-pass`, one password is asked up front and tried on each host that needs it.
- If a supplied password is rejected, the scan of that host continues without sudo.
- `--no-sudo` skips all of the above. Use it in scripts and scheduled jobs.

How the password is handled:

- It is never placed in command-line arguments or environment variables, and never written to disk.
- It is sent over the encrypted SSH channel on standard input, into the same remote session that runs the checks, and kept in a shell variable only for the duration of the scan.
- This matters because sudo's cached credentials are normally tied to a terminal or process and do not carry over between separate SSH sessions.

If sudo is configured with `Defaults requiretty`, sudo cannot be used without a terminal and the scan continues without it.

When sudo is unavailable, the report states that coverage may be incomplete. A check that could not be performed should not be interpreted as proof that the system is secure.

## JSON output

With `--json` and a single host, the script prints one JSON object:

```json
{
  "tool": "remotecheck",
  "version": "1.4.0",
  "target": "user@server",
  "sudo": {"state": "nopasswd", "privileged": true},
  "findings": {"warning": 0, "review": 3},
  "sections": [
    {
      "id": "host",
      "title": "Host",
      "data": {
        "host": "web1",
        "fqdn": "web1.example.com",
        "user": "deploy"
      }
    },
    {
      "id": "security_checks",
      "title": "Basic security checks",
      "columns": ["check", "status", "detail"],
      "rows": [
        {"check": "SSH root login", "status": "PASS", "detail": "PermitRootLogin no"}
      ]
    }
  ],
  "notes": ["Scan completed with sudo available."]
}
```

- Property sections (`host`, `os`, `summary`) have a `data` object.
- Table sections have `columns` and `rows`. When a section has no data (for example, a missing utility), it has an empty `rows` array and a `message` explaining why.
- Section IDs: `host`, `os`, `resources`, `network_interfaces`, `listening_sockets`, `running_services`, `failed_units`, `processes`, `security_checks`, `filesystem_checks`, `package_updates`, `temp_files`, `summary`.
- `sudo.state` is one of `nopasswd`, `password`, `rejected`, `skipped`, `disabled`, `missing`, or `failed`.
- `findings` counts `WARNING` and `REVIEW` statuses across all sections.

With several hosts, the output is one object containing every host report, the hosts that failed, and the combined finding counts:

```json
{
  "tool": "remotecheck",
  "version": "1.4.0",
  "hosts": [
    {"tool": "remotecheck", "target": "web1", "findings": {"warning": 0, "review": 3}, "sections": []}
  ],
  "failed": [
    {"target": "db1", "error": "Cannot connect over SSH: db1: Permission denied (publickey)."}
  ],
  "findings": {"warning": 0, "review": 3}
}
```

Example: list every check that needs attention on a single host.

```bash
./remotecheck --json --no-sudo user@server |
  jq -r '.sections[].rows[]? | select(.status == "REVIEW" or .status == "WARNING") | "\(.status): \(.check) - \(.detail)"'
```

Example: warning counts per host from a multi-host scan.

```bash
./remotecheck --json -f hosts.txt | jq -r '.hosts[] | "\(.target): \(.findings.warning) warning(s)"'
```

`jq` is optional; `remotecheck` does not require it.

> **Note:** the JSON format changed in version 1.3.0. Earlier versions emitted `sudo_available` and a `report` array of text lines. Version 1.4.0 adds sections and the `findings` object without removing anything.

## Color

Colors are used only when output goes to a terminal. Statuses are colored (`PASS` green, `REVIEW` yellow, `WARNING` red). Set `NO_COLOR` to disable colors:

```bash
NO_COLOR=1 ./remotecheck user@server
```

## Exit status

| Code | Meaning |
| --- | --- |
| `0` | Report(s) produced |
| `1` | Runtime error: SSH connection or remote collector failed (on any host, in multi-host mode) |
| `2` | Usage error (invalid option or argument) |
| `3` | Findings at or above the `--fail-on` level (only when `--fail-on` is given) |

If a host fails and findings are also present, the exit status is 1.

## Security and scope

Use this tool only on systems you own or are explicitly authorized to assess.

`remotecheck` is a lightweight inventory and triage aid, not a comprehensive vulnerability scanner, penetration-testing framework, or guarantee of system security. Its checks are intentionally limited, and results depend on the remote user's permissions, installed utilities, distribution, and configuration.

The script connects using SSH and relies on your SSH configuration, credentials, and host-key verification. Nothing is written to disk on the remote host. Review the code before running it in sensitive environments.

## Development

Check Bash syntax and run [ShellCheck](https://www.shellcheck.net/):

```bash
bash -n remotecheck
shellcheck remotecheck
```

The remote collector is embedded as a heredoc, which ShellCheck does not inspect. To lint it separately:

```bash
awk '/^  cat <<.REMOTE_COLLECTOR.$/{f=1;next} /^REMOTE_COLLECTOR$/{f=0} f' remotecheck |
  shellcheck -s bash -e SC2034 -
```

### Tests

Tests use [Bats](https://github.com/bats-core/bats-core). Unit tests need only Bash and `awk` (`jq` is used when installed); they cover argument handling, hosts files, the renderer, and the collector run locally without SSH:

```bash
bats test/
```

Integration tests scan a real host over SSH. They run only when `RC_TEST_TARGET` is set; the target must accept key-based logins. Extra arguments go in `RC_TEST_ARGS`:

```bash
RC_TEST_TARGET=user@localhost RC_TEST_ARGS="-p 2222 -i ~/.ssh/test_key" bats test/
```

The script can be sourced without running (`source remotecheck`), which is how the tests reach its functions.

### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request. It lints the script and the collector with ShellCheck, starts an SSH server on the runner, and runs the full Bats suite, integration tests included, against `localhost`.

## Contributing

Issues, bug reports, and pull requests are welcome. When submitting a change:

1. Describe the problem or enhancement.
2. Keep the script compatible with the Bash versions and standard utilities targeted by the project.
3. Run ShellCheck (including the collector) and `bats test/`, and add tests for new behavior.
4. Include reproduction steps for bugs and examples for behavior changes.

## License

Licensed under the [Apache License 2.0](LICENSE).
