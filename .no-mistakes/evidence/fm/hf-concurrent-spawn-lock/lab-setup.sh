#!/usr/bin/env bash
# Disposable live lab: marked lab homes, private tmux socket, real treehouse
# with a pool root inside the lab, stand-in crew CLI (sleep) so no model runs.
set -u
WT=${WT:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
export LAB
"$WT/bin/fm-lab-home.sh" create "$LAB/home-root" >/dev/null
"$WT/bin/fm-lab-home.sh" create "$LAB/home-child" >/dev/null
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB/home-root" > "$LAB/home-child/.fm-secondmate-parent"
for h in home-root home-child; do echo claude > "$LAB/$h/config/crew-harness"; touch "$LAB/$h/state/.last-watcher-beat"; done
mkdir -p "$LAB/tmux" "$LAB/user-home" "$LAB/bin" "$LAB/pool"
cat > "$LAB/bin/claude" <<'SH'
#!/usr/bin/env bash
exec sleep 600
SH
chmod +x "$LAB/bin/claude"
P="$LAB/project"; mkdir -p "$P"; git -C "$P" init -q -b main
printf 'max_trees = 4\nroot = "%s"\n' "$LAB/pool" > "$P/treehouse.toml"
echo hi > "$P/README.md"; git -C "$P" add -A; git -C "$P" -c user.name=lab -c user.email=lab@x commit -qm init
echo "$LAB"
