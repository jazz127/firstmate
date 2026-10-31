# Troubleshooting

## Task cleanup refuses because a shared VM is running

Start a shared VM through its service manager, for example `brew services start colima`, rather than from a task worktree.
Task cleanup stops the processes whose working directory is inside the task's directories, and a Lima-based VM keeps the directory it was started from as the working directory of its long-running `limactl` processes.

The refusal `leaving VM process <pid> running` names a `limactl hostagent` or `usernet` process whose state path is outside the task's directories.
Cleanup leaves that process and its descendants running, stops other reapable processes, and refuses before releasing the worktree or removing task records.
Restart that VM through its service manager, then rerun cleanup; no `--force` is needed or offered to bypass this refusal.
Treehouse's release operation also kills processes rooted in the worktree, so cleanup cannot safely release it while the shared VM remains there.
Descendants are identified by walking parent pids, which protects a QEMU child but does not protect a daemonised helper with no such ancestry, such as an SSH mux.

A `limactl` process is still stopped when its state path is inside the task's directories or cannot be determined.
Cleanup recognises only Lima's generated argument forms: `hostagent --pidfile VALUE --socket` and `usernet -p VALUE -e`.
Because `ps` does not preserve argument boundaries, the value must be a single whitespace-free token immediately followed by that next flag, and the state flag and next flag must each occur exactly once.
State paths containing spaces, including ` - `, are undeterminable and stay reapable.
