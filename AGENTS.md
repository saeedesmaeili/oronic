# OroCommerce Setup Agent

## Purpose and scope

Maintain a practical, production-oriented installation guide and Bash installer for OroCommerce Community Edition on a fresh Ubuntu Server 26.04 LTS host. These instructions apply throughout this repository.

## Repository files

- `README.md`: numbered manual setup steps, automated usage, recovery, verification and maintenance.
- `setup.sh`: interactive, single-server installer; not an upgrade or resume tool.
- `tests/setup_test.sh`: non-provisioning tests for validation and safety guards.
- `.gitattributes`: preserve LF line endings for shell scripts.

Read the affected files before editing. Keep documented commands, defaults, paths and script behavior consistent. Make the smallest complete change requested; avoid unrelated rewrites.

## Platform and release selection

- Keep Ubuntu 26.04 as the target. Do not silently substitute another distribution or release.
- When selecting or changing versions, verify the latest stable patch of the current supported OroCommerce LTS line using the official [releases](https://github.com/oroinc/orocommerce-application/releases), [release policy](https://doc.oroinc.com/community/release-process/) and [system requirements](https://doc.oroinc.com/backend/setup/system-requirements/).
- Pin an exact application release and install its committed dependency lock file. Do not use development branches, prereleases or an unreviewed production `composer update`.
- Check dependency versions, package availability and configuration against that release and Ubuntu's package archive. Explain any compatibility gap; do not invent package names or bypass platform checks.
- Update related version references together. Do not change the selected release during unrelated edits.

## Required setup coverage

Keep both installation paths complete and in execution order:

1. Server sizing, DNS, network access and required inputs.
2. Package index refresh and upgrades (`apt update` / `apt upgrade`, or `apt-get` in scripts), including reboot handling.
3. Prerequisites and supported PHP, database, Node.js, pnpm and Composer versions.
4. Administrator and deployment users, sudo access, user switching and working directories.
5. Database creation, generated secrets and production application configuration.
6. Pinned release download, dependency installation, application installation and OAuth keys.
7. Ownership, directory traversal, runtime write access and secret permissions.
8. Nginx, trusted HTTPS, certificate renewal, WebSockets and firewall rules that preserve SSH access.
9. Persistent queue and WebSocket workers, cron and log rotation.
10. Service and application verification, SMTP setup, backups, restore testing and maintenance.

Clearly identify manual follow-up work. Never imply that SMTP, off-server backups or a restore test are configured when they are not.

## Script and security rules

- Use Bash with `set -Eeuo pipefail`, quoted expansions, validated inputs and useful failure messages. Keep `--help` free of provisioning side effects.
- Check the OS, privileges, terminal requirements and conflicting resources before provisioning. Refuse existing installation resources; preserve partial work and document recovery.
- Never drop an existing database, replace secrets or OAuth keys, or remove application data as automatic recovery.
- Run system configuration as root, deployment commands as `oro`, and runtime commands as `www-data`. Give sudo access only to the administrator account.
- Grant runtime write access only where required. Never use `chmod -R 777` or make application code writable by the web user.
- Generate unique secrets and restrict their files. Keep secrets out of version control, command examples, tracing and logs.
- Keep PostgreSQL and the internal WebSocket listener on loopback. Serve only the public directory and intended PHP front controller.
- Validate generated service configuration before reloads. Check each required service individually; do not treat one active service as proof that all are healthy.

## Documentation style

- Use concise, numbered steps and copyable fenced commands.
- State which user runs each command, the working directory when relevant, and how to switch back.
- Use clearly marked example hostnames and placeholders; never include real credentials.
- Include brief explanations only for prerequisites, decisions, recovery or operational risks. Avoid unnecessary comments and repeated descriptions.
- Link official sources near version and compatibility claims.

## Validation and delivery

For shell changes, run from the repository root:

```bash
bash -n setup.sh
bash -n tests/setup_test.sh
bash tests/setup_test.sh
shellcheck setup.sh tests/setup_test.sh
```

- Add focused tests when changing input validation, failure handling or overwrite guards. Tests must not provision or modify the host.
- Review documentation-only changes for accuracy and consistency; shell tests are unnecessary unless commands or script behavior change.
- Do not run provisioning as a local smoke test. Use a disposable Ubuntu 26.04 server for integration testing when provisioning is within the requested scope.
- Report what changed, which checks passed, and any checks unavailable or not run. Distinguish static validation from a completed server installation; never claim production readiness solely from lint results.
