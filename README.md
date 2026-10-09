# remotecheck

**remotecheck** is an open-source Bash utility for remotely collecting Linux host inventory and performing a small set of basic security checks over SSH.

It is designed to provide a quick, readable snapshot of a server while continuing to collect information when sudo is unavailable.

## Features

- Connects to a remote Linux host over SSH.
- Collects host identity, OS and kernel information, uptime, network interfaces, listening sockets, systemd services, failed units, and a process sample.
- Runs basic checks related to SSH configuration, package updates, and world-writable files in temporary directories where possible.
- Tries passwordless sudo first; if unavailable, offers a hidden password prompt. Press **Enter** to continue without sudo.
- Produces a colored, bordered terminal report.
- Supports JSON output for scripting and automation.
- Allows a custom SSH port and identity file.

## Requirements

On the local machine:

- Bash
- OpenSSH client (`ssh`)
- `base64`

On the remote host, the script uses common Linux utilities when available, including `hostname`, `id`, `uname`, `uptime`, `ip`, `ss`, `systemctl`, `ps`, `awk`, `find`, and a supported package manager. Some checks may be skipped if a utility is unavailable.

## Installation

Clone or download this repository, then make the script executable:

```bash
chmod +x remotecheck
```

You can run it from the repository directory or place it somewhere in your `PATH`.

## Usage

Basic scan using the default SSH port (22):

```bash
./remotecheck user@server
```

Use a custom SSH port:

```bash
./remotecheck -p 2222 user@server
```

Specify an SSH identity file:

```bash
./remotecheck -i ~/.ssh/id_ed25519 user@server
```

Use both options together:

```bash
./remotecheck -p 2222 -i ~/.ssh/id_ed25519 user@server
```

Output JSON:

```bash
./remotecheck --json user@server
```

JSON output with a custom port:

```bash
./remotecheck --json -p 2222 user@server
```

Show help or version:

```bash
./remotecheck --help
./remotecheck --version
```

## Sudo behavior

`remotecheck` first attempts to validate passwordless sudo on the remote host.

- If passwordless sudo works, the scan uses it for supported privileged checks.
- Otherwise, the script prompts for a sudo password without echoing it.
- Press **Enter** at the prompt to skip sudo and continue with unprivileged checks.
- If the supplied password is rejected, the scan continues without sudo.

When sudo is unavailable, the report indicates that coverage may be incomplete. A check that could not be performed should not be interpreted as proof that the system is secure.

## JSON output

With `--json`, the script emits a JSON object containing:

- `sudo_available`: whether sudo was available for the scan.
- `report`: an array of human-readable report lines without the terminal table borders.

For pretty-printing, install [`jq`](https://jqlang.github.io/jq/) and pipe the output through it:

```bash
./remotecheck --json user@server | jq .
```

`jq` is optional; `remotecheck` does not require it.

## Security and scope

Use this tool only on systems you own or are explicitly authorized to assess.

`remotecheck` is a lightweight inventory and triage aid, not a comprehensive vulnerability scanner, penetration-testing framework, or guarantee of system security. Its checks are intentionally limited, and results depend on the remote user's permissions, installed utilities, distribution, and configuration.

The script connects using SSH and relies on your SSH configuration, credentials, and host-key verification. Review the code before running it in sensitive environments.

## Development checks

Check Bash syntax:

```bash
bash -n remotecheck
```

Run [ShellCheck](https://www.shellcheck.net/) if it is installed:

```bash
shellcheck remotecheck
```

## Contributing

Issues, bug reports, and pull requests are welcome. When submitting a change:

1. Describe the problem or enhancement.
2. Keep the script compatible with the Bash versions and standard utilities targeted by the project.
3. Run `bash -n remotecheck` and `shellcheck remotecheck` when available.
4. Include reproduction steps for bugs and examples for behavior changes.

## Creator

Created by **Pavlos**.

## License

No license has been selected yet. Before publishing the repository as open source, add a license file (for example, MIT, Apache-2.0, or GPL-3.0) that matches how you want others to use, modify, and redistribute the project.
