#!/usr/bin/env bash
#
# README 用のスクリーンショットを撮り直すスクリプト
#
#   ./tools/screenshot.sh          スクリーンショットを撮って assets/ に保存
#   ./tools/screenshot.sh --check  横方向のはみ出しがないかを検査（画像は撮らない）
#
# 必要なもの: Google Chrome（または Chromium 系）と sips（macOS 標準）
#
# ── なぜ iframe を経由するのか ────────────────────────────────
# headless Chrome は --window-size に 500px 未満を指定しても、
# レイアウト幅が 500px に切り上げられます。390px を指定したつもりで
# 500px 幅の描画結果が 390px に切り取られ、右側が欠けた画像になります。
# そこで 390px の iframe を持つラッパーページを描画し、その領域だけを
# 切り出すことで、本物の 390px 幅の表示を得ています。
# ──────────────────────────────────────────────────────────

set -euo pipefail

DESKTOP_W="${DESKTOP_W:-1440}"   # デスクトップの論理幅
DESKTOP_H="${DESKTOP_H:-900}"
MOBILE_W="${MOBILE_W:-390}"      # スマートフォンの論理幅（iPhone 14 相当）
MOBILE_H="${MOBILE_H:-844}"
SCALE="${SCALE:-2}"              # Retina 相当。1 にすると等倍
MIN_W=500                        # headless Chrome が下回れないレイアウト幅

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGE="file://$REPO/index.html"
OUT="$REPO/assets"

# ---- Chrome を探す --------------------------------------------------
find_chrome() {
  local c
  for c in \
    "${CHROME:-}" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
  do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  echo "Chrome が見つかりません。CHROME=/path/to/chrome を指定してください。" >&2
  return 1
}

CHROME_BIN="$(find_chrome)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

shot() {  # shot <出力先> <幅> <高さ> <URL>
  "$CHROME_BIN" --headless=new --disable-gpu --hide-scrollbars \
    --allow-file-access-from-files \
    --force-device-scale-factor="$SCALE" \
    --window-size="$2,$3" \
    --virtual-time-budget=4000 \
    --screenshot="$1" "$4" >/dev/null 2>&1
}

# ---- はみ出し検査 ---------------------------------------------------
# scrollWidth と clientWidth が一致していれば、ページは横スクロールしない。
# .table-scroll と .code pre は内側だけがスクロールする設計なので、
# それらの中身がビューポートより広いのは正常。
if [ "${1:-}" = "--check" ]; then
  cp "$REPO/index.html" "$TMP/diag.html"
  cat >> "$TMP/diag.html" <<'EOF'
<script>
window.addEventListener('load', function(){
  var d = document.documentElement, out = [];
  [].forEach.call(document.querySelectorAll('body *'), function(el){
    var r = el.getBoundingClientRect();
    if (r.right > d.clientWidth + 1 && r.width > 0 &&
        !el.closest('.table-scroll') && !el.closest('.code')){
      out.push(el.tagName + '.' + String(el.className || '-').split(' ')[0]);
    }
  });
  document.title = 'width=' + d.clientWidth +
    ' scrollWidth=' + d.scrollWidth +
    ' | ' + (d.scrollWidth > d.clientWidth ? 'NG: 横スクロールあり' : 'OK: 横スクロールなし') +
    ' | 想定外のはみ出し: ' + (out.length ? out.slice(0,10).join(', ') : 'なし');
});
</script>
EOF
  echo "── 横方向のはみ出し ──"
  for w in 500 768 1024 1440; do
    printf '%5spx  ' "$w"
    "$CHROME_BIN" --headless=new --disable-gpu --window-size="$w,900" \
      --virtual-time-budget=3000 --dump-dom "file://$TMP/diag.html" 2>/dev/null \
      | grep -o '<title>[^<]*</title>' | sed 's/<[^>]*>//g'
  done
  echo
  echo "注: headless Chrome の下限が 500px のため、それ未満の幅は検査できません。"

  # ── ヘッダーと安全領域 ──
  # ノッチのある端末や LINE のアプリ内ブラウザは env(safe-area-inset-top) に
  # 値を返す。--safe-top を固定値で差し替えて、その環境を模擬する。
  # ヘッダーの高さに安全領域を「含めて」しまうと文字がはみ出して切れる。
  echo
  echo "── ヘッダーと安全領域 ──"
  for inset in 0px 24px 44px; do
    cp "$REPO/index.html" "$TMP/nav.html"
    cat >> "$TMP/nav.html" <<EOF
<style>:root{--safe-top:$inset}</style>
<script>
window.addEventListener('load', function(){
  var n = document.querySelector('.global-nav').getBoundingClientRect();
  var b = document.querySelector('.global-nav__brand').getBoundingClientRect();
  var t = document.getElementById('navToggle').getBoundingClientRect();
  var ok = b.bottom <= n.bottom + 0.5 && t.right <= n.right + 0.5;
  document.title = 'バー高さ=' + Math.round(n.height) + 'px' +
    ' 文字の下端=' + Math.round(b.bottom) + 'px' +
    ' | ' + (ok ? 'OK 収まっている' : 'NG ヘッダーからはみ出している');
});
</script>
EOF
    printf '  安全領域 %-5s  ' "$inset"
    "$CHROME_BIN" --headless=new --disable-gpu --window-size=500,844 \
      --virtual-time-budget=3000 --dump-dom "file://$TMP/nav.html" 2>/dev/null \
      | grep -o '<title>[^<]*</title>' | sed 's/<[^>]*>//g'
  done
  exit 0
fi

# ---- デスクトップ ---------------------------------------------------
mkdir -p "$OUT"
echo "デスクトップ ${DESKTOP_W}×${DESKTOP_H} を撮影中..."
shot "$OUT/screenshot-desktop.png" "$DESKTOP_W" "$DESKTOP_H" "$PAGE"

# ---- スマートフォン -------------------------------------------------
echo "スマートフォン ${MOBILE_W}×${MOBILE_H} を撮影中..."
if [ "$MOBILE_W" -ge "$MIN_W" ]; then
  # 下限以上なら、そのまま撮れる
  shot "$OUT/screenshot-mobile.png" "$MOBILE_W" "$MOBILE_H" "$PAGE"
else
  # 下限未満は iframe に閉じ込めて撮り、中央を切り出す
  cat > "$TMP/wrapper.html" <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:#fff;height:${MOBILE_H}px;overflow:hidden}
body{display:flex;justify-content:center}
iframe{width:${MOBILE_W}px;height:${MOBILE_H}px;border:0;display:block}
</style></head><body><iframe src="$PAGE"></iframe></body></html>
EOF
  shot "$TMP/raw.png" "$MIN_W" "$MOBILE_H" "file://$TMP/wrapper.html"
  sips -c "$((MOBILE_H * SCALE))" "$((MOBILE_W * SCALE))" \
       "$TMP/raw.png" --out "$OUT/screenshot-mobile.png" >/dev/null
fi

# ---- 結果 -----------------------------------------------------------
echo
for f in "$OUT/screenshot-desktop.png" "$OUT/screenshot-mobile.png"; do
  printf '%-28s %s  %s\n' \
    "$(basename "$f")" \
    "$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{printf "%s×%s", w, h}')" \
    "$(du -h "$f" | cut -f1)"
done
