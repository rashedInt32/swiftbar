#!/bin/zsh
# <xbar.title>Dev servers</xbar.title>
# <xbar.desc>Node dev servers listening on a port: uptime, RAM, stop.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# Settings: env vars, all optional. Set them in ~/.config/devservers/env, a zsh file this
# script sources, or point DEVSERVERS_ENV at another file.
#   DEVSERVERS_IGNORE        regex on a listener's command line to skip, e.g. a package-manager proxy

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ENV_FILE=${DEVSERVERS_ENV:-$HOME/.config/devservers/env}
[[ -r $ENV_FILE ]] && source $ENV_FILE
IGNORE=${DEVSERVERS_IGNORE:-}
SELF=${0:A}
ICON=hexagon

# Menu actions call this script back with a verb.
case $1 in
  stop-group) kill -TERM -- "-$2" 2>/dev/null; exit 0 ;;
esac

etime_secs() { # ps etime: [[dd-]hh:]mm:ss
  local t=$1 d=0 h=0 m=0 s=0
  [[ $t == *-* ]] && { d=${t%%-*}; t=${t#*-}; }
  local -a p; p=(${(s.:.)t})
  if (( ${#p} == 3 )); then h=$p[1] m=$p[2] s=$p[3]; else m=$p[1] s=$p[2]; fi
  echo $(( d*86400 + h*3600 + m*60 + s ))
}
fmt_dur() {
  local s=$1
  if (( s < 3600 )); then echo "$(( s/60 ))m"
  elif (( s < 86400 )); then printf '%dh %dm\n' $(( s/3600 )) $(( s%3600/60 ))
  else printf '%dd %dh\n' $(( s/86400 )) $(( s%86400/3600 )); fi
}
kind_label() { case $1 in next) echo Next.js ;; storybook) echo Storybook ;; vite) echo Vite ;; portless) echo Portless ;; *) echo $1 ;; esac; }
fmt_mem() { local kb=$1; if (( kb >= 1048576 )); then printf '%.1f GB\n' $(( kb/1048576.0 )); else echo "$(( kb/1024 )) MB"; fi; }

# Listening TCP sockets -> ports per pid.
typeset -A ports_by_pid
pid=
for line in ${(f)"$(lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null)"}; do
  case $line in
    p*) pid=${line#p} ;;
    n*) port=${line##*:}; [[ " ${ports_by_pid[$pid]} " == *" $port "* ]] || ports_by_pid[$pid]="${ports_by_pid[$pid]:+${ports_by_pid[$pid]} }$port" ;;
  esac
done

# Keep node-based listeners, grouped by process group: one dev command = one group.
typeset -A g_ports g_pid g_kind
for pid in ${(k)ports_by_pid}; do
  comm=$(ps -o comm= -p $pid 2>/dev/null) || continue
  args=$(ps -o args= -p $pid 2>/dev/null)
  # Match the program itself, not its arguments: Electron apps (VS Code, Cursor) pass
  # "node.mojom.NodeService" in theirs, and stopping that group would quit the editor.
  exe=${comm:t}
  [[ $exe == (node|bun|deno) || $exe == next-server* ]] || continue
  [[ -n $IGNORE && "$args" =~ $IGNORE ]] && continue
  pg=$(ps -o pgid= -p $pid | tr -d ' ')
  for p in ${(s: :)ports_by_pid[$pid]}; do
    [[ " ${g_ports[$pg]} " == *" $p "* ]] || g_ports[$pg]="${g_ports[$pg]:+${g_ports[$pg]} }$p"
  done
  case "$comm $args" in
    *next-server*|*next/dist/bin/next*) kind=next ;;
    *storybook*) kind=storybook ;;
    *vite*) kind=vite ;;
    *portless*) kind=portless ;;
    *) # Name it after the script it runs: skip flags, the value of flags that take one, and `run`.
      kind=$exe; skip=0
      for w in ${${(z)args}[2,-1]}; do
        if (( skip )); then skip=0; continue; fi
        case $w in
          -r|--require|--import|--loader|--experimental-loader|-e|--eval|-p|--print|--conditions) skip=1 ;;
          -*|run|x|exec) ;;
          *) kind=${w:t}; break ;;
        esac
      done ;;
  esac
  # Prefer the named server process as the group's representative.
  if [[ -z ${g_pid[$pg]} || $kind == (next|storybook|vite) ]]; then g_pid[$pg]=$pid; g_kind[$pg]=$kind; fi
done

typeset -A blocks
total_kb=0; count=0

for pg in ${(k)g_pid}; do
  pid=${g_pid[$pg]}
  # Uptime of the whole dev command: its group leader, or the listener if the leader is gone.
  lp=$pg; ps -p $pg >/dev/null 2>&1 || lp=$pid
  secs=$(etime_secs $(ps -o etime= -p $lp | tr -d ' '))
  started=$(ps -o lstart= -p $lp | tr -s ' ' '_')
  kb=0; for r in ${(f)"$(ps -o rss= -g $pg 2>/dev/null)"}; do (( kb += r )); done
  cwd=$(lsof -a -p $pid -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); name=${${top:-$cwd}:t}
  ports=(${(n)${(s: :)g_ports[$pg]}})
  url="http://localhost:$ports[1]"
  leader=$(ps -o args= -p $pg 2>/dev/null); [[ -z $leader ]] && leader=$(ps -o args= -p $pid)
  leader=$(print -r -- $leader | sed 's|^[^ ]*/||' | cut -c1-40)
  nproc=$(ps -o pid= -g $pg 2>/dev/null | wc -l | tr -d ' ')

  (( count++ )); (( total_kb += kb ))

  b="$(kind_label ${g_kind[$pg]}) · $name    $(fmt_dur $secs) · $(fmt_mem $kb) | href=$url"
  b+=$'\n'"--${url#*://} · $(fmt_mem $kb) · up $(fmt_dur $secs) | size=12"
  b+=$'\n'"-----"
  b+=$'\n'"--Open in browser | href=$url"
  [[ -d $cwd ]] && b+=$'\n'"--Show in Finder | bash=/usr/bin/open param1=\"$cwd\" terminal=false"
  b+=$'\n'"-----"
  b+=$'\n'"--Stop $leader | bash=$SELF param1=stop-group param2=$pg terminal=false refresh=true tooltip=\"Stops $nproc processes\""
  blocks[$(printf '%010d-%s' $secs $pg)]=$b
done

# Menu bar: icon plus count.
if (( count == 0 )); then echo " | sfimage=$ICON"
else echo "$count | sfimage=$ICON.fill"; fi
echo "---"
echo "Dev servers | size=12"
for k in ${(O)${(k)blocks}}; do print -r -- ${blocks[$k]}; done   # longest-running first
(( count == 0 )) && echo "Nothing running"
echo "---"
if (( count > 0 )); then
  sys_kb=$(( $(sysctl -n hw.memsize) / 1024 ))
  echo "$(fmt_mem $total_kb) in use  ·  $(( total_kb * 100 / sys_kb ))% of $(fmt_mem $sys_kb) | bash=/usr/bin/open param1=-b param2=com.apple.ActivityMonitor terminal=false tooltip=\"Open Activity Monitor\""
fi
echo "Refresh | refresh=true"
