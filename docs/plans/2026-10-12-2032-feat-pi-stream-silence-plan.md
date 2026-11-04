# Pi worker model-stream observation

The stream-silence plan is implemented.
[Configuration](../configuration.md#environment-variables) owns activation, supported limits, and operator behavior.
[The busy-state library](../../bin/fm-busy-lib.sh) owns the generation and request-ordering contract; [the watcher](../../bin/fm-watch.sh) owns guarded inspection publication.
[Runtime backend verification](../verification/runtime-backends.md#pi-worker-model-stream-observation) owns current vendor evidence and the live regression entry point.
