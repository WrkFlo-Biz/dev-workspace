# `.bashrc` install snippet

For the canonical VM checkout at `~/projects/dev-workspace`, add this to
`~/.bashrc` (adjust the path if you cloned the repo elsewhere):

```bash
if [ -f "$HOME/projects/dev-workspace/scripts/dws-bashrc.sh" ]; then
  . "$HOME/projects/dev-workspace/scripts/dws-bashrc.sh"
fi
```

This only loads the interactive shell helpers from
`scripts/dws-bashrc.sh`. It does not install the repo-managed user
services (`dws-sessions-init.service` and `dws-task-monitor.service`);
install those separately with
`~/projects/dev-workspace/bin/dws-systemd-user-setup.sh install`.
