#!/data/data/com.termux/files/usr/bin/bash
# inventory.sh —— 只读盘点：为了在 Termux 上跑起 dsh，到底装了什么、改了什么
export PREFIX="/data/data/com.termux/files/usr"
export HOME="/data/data/com.termux/files/home"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
export TMPDIR="$PREFIX/tmp"

sec() { printf '\n########## %s ##########\n' "$1"; }

sec "A. 环境"
printf 'node       : %s (%s)\n' "$(node -v 2>&1)" "$(command -v node)"
printf 'npm        : %s\n' "$(npm -v 2>&1)"
printf 'python     : %s\n' "$(python -V 2>&1)"
printf 'arch       : %s\n' "$(uname -m)"
printf 'android    : %s\n' "$(getprop ro.build.version.release 2>/dev/null)"
printf 'prefix     : %s\n' "$PREFIX"

sec "B. 全局 npm 包（只看 @deepseek-ai）"
ls -d "$PREFIX/lib/node_modules/@deepseek-ai"/* 2>/dev/null | sed 's|.*/||'
printf 'dsh 版本   : %s\n' "$(dsh --version 2>&1 | head -1)"

sec "C. 自己装的执行文件（\$PREFIX/bin 下 dsh-* / 相关）"
for f in dsh dsh-web-url dsh-lan-ip dsh-lan-gateway dsh-ctl-gateway dsh-set-key dsh-set-provider dsh-patch-lan-settings; do
  p="$PREFIX/bin/$f"
  if [ -e "$p" ]; then
    printf '  %-24s %7s B  %s\n' "$f" "$(wc -c <"$p")" "$(head -1 "$p" | cut -c1-46)"
  else
    printf '  %-24s (不存在)\n' "$f"
  fi
done
printf '  --- \$PREFIX/share/dsh-ctl/ ---\n'
ls -la "$PREFIX/share/dsh-ctl" 2>/dev/null | tail -n +2 | sed 's/^/    /'

sec "D. runit 服务（termux-services）"
for n in dsh-web dsh-lan dsh-ctl; do
  d="$PREFIX/var/service/$n"
  if [ -d "$d" ]; then
    printf '  [%s] %s\n' "$n" "$(sv status "$n" 2>&1 | head -1)"
    printf '       down 文件: %s\n' "$([ -e "$d/down" ] && echo 有 || echo 无)"
    printf '       run     : %s\n' "$(sed -n '2,40p' "$d/run" 2>/dev/null | grep -E 'exec|export|source|dsh' | tr '\n' ' ' | cut -c1-260)"
    printf '       log/run : %s\n' "$([ -e "$d/log/run" ] && echo 有 || echo 无)"
  else
    printf '  [%s] 未安装\n' "$n"
  fi
done

sec "E. dsh-web 实际启动命令行"
for f in /proc/[0-9]*/cmdline; do
  c=$(tr '\0' ' ' <"$f" 2>/dev/null)
  case "$c" in *"/bin/dsh web"*) printf '  pid=%s\n    %s\n' "$(printf '%s' "$f" | cut -d/ -f3)" "$c" ;; esac
done

sec "F. 补丁器状态（~/dsh-termux/patches.py --list）"
if [ -f "$HOME/dsh-termux/patches.py" ]; then
  python "$HOME/dsh-termux/patches.py" --list 2>&1 | sed 's/^/  /'
else
  echo "  (patches.py 不在)"
fi

sec "G. 逐一复查每处补丁的落地痕迹"
D="$PREFIX/lib/node_modules/@deepseek-ai/dsh"
N="$D/node_modules/@deepseek-ai"
chk() { # $1=文件  $2=关键字  $3=说明
  if [ -f "$1" ]; then
    n=$(grep -c "$2" "$1" 2>/dev/null || echo 0)
    printf '  %-6s %-46s %s\n' "$([ "$n" -gt 0 ] && echo '[已打]' || echo '[未打]')" "$3" "($(basename "$(dirname "$2")")…$(basename "$1") hit=$n)"
  fi
}
printf '  --- ① 启动 shebang --expose-internals ---\n'
for f in "$PREFIX/bin/dsh" "$N/dsh-app-boot/lib/index.js"; do
  [ -f "$f" ] && printf '    %-52s %s\n' "$(basename "$f")" "$(head -1 "$f" | cut -c1-70)"
done
grep -rn "expose-internals" "$PREFIX/bin/dsh" 2>/dev/null | head -2 | sed 's/^/    /'
printf '  --- ② internalModules() 绕过 node-addon-require-builtin ---\n'
grep -rn "dsh-termux" "$N/dsh-app-boot/lib/"*.js 2>/dev/null | head -3 | sed 's/^/    /'
printf '  --- ③ flock 门 ---\n'
grep -rn "dsh-termux" "$N/dsh-bash-local/lib/"*.js "$N"/dsh-*/lib/*.js 2>/dev/null | grep -i flock | head -3 | sed 's/^/    /'
ls -la "$D/node_modules/@deepseek-ai/node-addon-system/prebuilds/" 2>/dev/null | tail -n +2 | sed 's/^/    /'
printf '  --- ④ link(2) -> rename(2) ---\n'
grep -rln "dsh-termux" "$N"/dsh-session-persistence/lib/*.js "$N"/dsh-fs-local/lib/*.js "$N"/dsh-attachment-local/lib/*.js 2>/dev/null | sed 's/^/    /'
printf '  --- ⑤ 客户端 isLoopback ---\n'
grep -n "dsh-termux-lan" "$N/dsh-client-connection/lib/client.js" 2>/dev/null | head -2 | sed 's/^/    /'

sec "H. 配置与凭据落点"
printf '  \$DSH_HOME = %s\n' "${DSH_HOME:-$HOME/.dsh}"
find "$HOME/.dsh" -maxdepth 3 -type f 2>/dev/null | sed "s|$HOME|~|" | sed 's/^/    /'
printf '  --- 服务环境文件 ---\n'
ls -la "$PREFIX/var/service/dsh-web/environment" 2>/dev/null | sed 's/^/    /'
printf '    %s\n' "$(sed 's/=.\{6\}.*/=<掩码>/' "$PREFIX/var/service/dsh-web/environment" 2>/dev/null | tr '\n' ' ')"
printf '  --- profiles 下的 provider 覆盖块 ---\n'
for p in web headless; do
  f="$HOME/.dsh/profiles/$p/cordis.patch.yml"
  [ -f "$f" ] || { printf '    %s: (无)\n' "$p"; continue; }
  printf '    %s: %s 字节，插件=%s\n' "$p" "$(wc -c <"$f")" "$(grep -oE '\- id: llm-(deepseek|pi-ai)' "$f" | tr '\n' ',' )"
done

sec "I. 备份与工作目录"
ls -la "$HOME/dsh-termux" 2>/dev/null | sed 's/^/  /'
printf '  --- backups ---\n'
ls -la "$HOME/dsh-termux/backups" 2>/dev/null | tail -n +2 | sed 's/^/    /'

sec "J. Termux 侧为此装的系统包（编译原生插件相关）"
for p in nodejs-lts clang make python git libandroid-wordexp binutils; do
  v=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)
  [ -n "$v" ] && printf '  %-22s %s\n' "$p" "$v"
done
printf '  --- 编译产物（.node）---\n'
find "$PREFIX/lib/node_modules/@deepseek-ai" -name "*.node" 2>/dev/null | sed "s|$PREFIX|\\\$PREFIX|" | sed 's/^/    /'

echo
echo "########## 盘点结束 ##########"
