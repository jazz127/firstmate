# Troubleshooting

## Task cleanup warns that it left a VM process running

Start a shared VM through its service manager, for example `brew services start colima`, rather than from a task worktree.
Task cleanup stops the processes whose working directory is inside the task's directories, and a Lima-based VM keeps the directory it was started from as the working directory of its long-running `limactl` processes.

The warning `leaving VM process <pid> running` names a `limactl hostagent` or `usernet` process whose state path is outside the task's directories.
Cleanup left that process running and completed, so the VM is still available, but restart it through its service manager because its working directory has now been removed.
Only those `limactl` processes are exempt: any other process the VM started from the same directory, such as an SSH connection helper or a QEMU process, is still stopped.
A `limactl` process is also still stopped when its state path is inside the task's directories or cannot be determined.
