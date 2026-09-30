export PREFIX="/data/data/com.termux/files/usr"; export HOME="/data/data/com.termux/files/home"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$PATH"
S="$PREFIX/var/service/dsh-ctl/run"
cp -a "$S" "$HOME/dsh-termux/backups/dsh-ctl.run.$(date +%Y%m%d%H%M%S)"
printf '%s' 'IyEvZGF0YS9kYXRhL2NvbS50ZXJtdXgvZmlsZXMvdXNyL2Jpbi9zaAojIGRzaC1jdGwg4oCU4oCUIOWxgOWfn+e9keS4iueahCBkc2jjgIzmjqfliLblj7AgKyDlhaXlj6PjgI3nvZHlhbPvvIznm5HlkKwgPGxhbi1pcD46ODAzMOOAggojCiMgICBodHRwOi8vPGxhbi1pcD46ODAzMC8gICAgICAgICAg5o6n5Yi25Y+w77yI5pyq55m75b2V5pe257uZ6JC95Zyw6aG177yM5bim546w5Y+W55qE5Luk54mM5YWl5Y+j77yJCiMgICBodHRwOi8vPGxhbi1pcD46ODAzMC9hcHAgICAgICAgIOe7j+e9keWFs+i/m+WFpSBkc2gg5Li755WM6Z2i77yIP3Rva2VuPeKApiDlj6/nm7TmjqXnmbvlvZXvvIkKIyAgIGh0dHA6Ly88bGFuLWlwPjo4MDMwL2N0bCAgICAgICAg5o6n5Yi25Y+w5Yir5ZCN77ya5pyN5Yqh54q25oCBIC8g5qih5Z6L5ZCO56uvIC8g5Yet5o2uIC8g6YeN5ZCvIC8g6Ieq5qOACiMKIyDlroPlkIzml7bmmK/lj43lkJHku6PnkIbvvIhIVFRQICsgV2ViU29ja2V0IOmAj+S8oOWIsCAxMjcuMC4wLjE6MzA4MO+8ieWSjOaOp+WItumdouOAggojIC9jdGwg5aSN55SoIGRzaCDoh6rlt7HnmoTnmbvlvZUgY29va2ll77yM5LiN6aKd5aSW6K6+5Y+j5Luk44CCCiMKIyAgIHN2IGRvd24gZHNoLWN0bCAgICAgIyDlhbPmjonov5nkuKrlhaXlj6PvvIjkuI3lvbHlk40gZHNoLXdlYiDmnKzkvZPjgIHkuI3lvbHlk40gU1NIIOmap+mBk++8iQojICAgc3YgdXAgZHNoLWN0bCAgICAgICAjIOWGjeaJk+W8gAoKZXhwb3J0IFBSRUZJWD0iL2RhdGEvZGF0YS9jb20udGVybXV4L2ZpbGVzL3VzciIKZXhwb3J0IEhPTUU9Ii9kYXRhL2RhdGEvY29tLnRlcm11eC9maWxlcy9ob21lIgpleHBvcnQgUEFUSD0iL2RhdGEvZGF0YS9jb20udGVybXV4L2ZpbGVzL3Vzci9iaW46L2RhdGEvZGF0YS9jb20udGVybXV4L2ZpbGVzL3Vzci9iaW4vYXBwbGV0cyIKZXhwb3J0IFRNUERJUj0iL2RhdGEvZGF0YS9jb20udGVybXV4L2ZpbGVzL3Vzci90bXAiCmV4cG9ydCBMQU5HPSJlbl9VUy5VVEYtOCIKCmV4ZWMgIiRQUkVGSVgvYmluL2RzaC1jdGwtZ2F0ZXdheSIgYXV0byA4MDMwIDEyNy4wLjAuMSAzMDgwCg==' | base64 -d > "$S"
chmod 755 "$S"
sh -n "$S" && echo "run 语法 OK"
sv restart dsh-ctl >/dev/null 2>&1
sleep 4
sv status dsh-ctl
echo "--- cordis.patch.yml 顶层哨兵 ---"
for p in web headless; do
  printf '  %-9s 含 [] : %s\n' "$p" "$(grep -cx '\[\]' "$HOME/.dsh/profiles/$p/cordis.patch.yml" 2>/dev/null)"
done
echo "--- 8030 复检 ---"
for u in "http://192.168.3.190:8030/" "http://192.168.3.190:8030/app" "http://192.168.3.190:8030/ctl"; do
  printf '  %-38s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$u")"
done
