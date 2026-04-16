#!/bin/bash
# ============================================
# 文字起こし → Obsidian 自動仕訳スクリプト
# Claude Code（claude -p）を使用
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

# 色付き出力
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# パス末尾のスペースと/を除去する関数
clean_path() {
  local p="$1"
  # ドラッグ&ドロップ時の末尾スペース除去
  p="${p%"${p##*[! ]}"}"
  # 末尾の / を除去
  p="${p%/}"
  echo "$p"
}

# 初回セットアップ（config.shが未設定なら対話で設定）
setup_config() {
  echo ""
  echo "============================================"
  echo " 初回セットアップ"
  echo "============================================"
  echo ""
  echo "フォルダを指定してください。"
  echo "（Finderからフォルダをこの画面にドラッグ&ドロップできます）"
  echo ""

  # 入力フォルダ
  echo -e "${GREEN}[1/2] 文字起こしファイルが入っているフォルダ:${NC}"
  read -r -p "  → " raw_input
  INPUT_DIR=$(clean_path "$raw_input")

  if [ ! -d "$INPUT_DIR" ]; then
    echo -e "${RED}エラー: フォルダが見つかりません: $INPUT_DIR${NC}"
    exit 1
  fi

  echo ""

  # 出力フォルダ
  echo -e "${GREEN}[2/2] Obsidianの保存先フォルダ:${NC}"
  read -r -p "  → " raw_output
  OUTPUT_DIR=$(clean_path "$raw_output")

  mkdir -p "$OUTPUT_DIR"

  echo ""

  # config.shに保存
  cat > "$CONFIG_FILE" << CONF_EOF
#!/bin/bash
INPUT_DIR="$INPUT_DIR"
OUTPUT_DIR="$OUTPUT_DIR"
MODEL="sonnet"
WAIT_SECONDS=30
INTERVAL_SECONDS=5
CONF_EOF

  echo -e "${GREEN}設定を保存しました。次回からはそのまま実行できます。${NC}"
  echo ""
}

# config.sh読み込み or 初回セットアップ
if [ -f "$CONFIG_FILE" ] && grep -q 'INPUT_DIR=' "$CONFIG_FILE" && ! grep -q 'INPUT_DIR="\$HOME/transcripts"' "$CONFIG_FILE"; then
  source "$CONFIG_FILE"
else
  setup_config
  source "$CONFIG_FILE"
fi

PROMPT_TEMPLATE="$SCRIPT_DIR/prompt-template.md"
DONE_DIR="$INPUT_DIR/.done"
LOG_FILE="$SCRIPT_DIR/process.log"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo -e "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# 初期チェック
if ! command -v claude &> /dev/null; then
  echo -e "${RED}エラー: Claude Code がインストールされていません${NC}"
  exit 1
fi

if [ ! -d "$INPUT_DIR" ]; then
  echo -e "${RED}エラー: 入力フォルダが見つかりません: $INPUT_DIR${NC}"
  echo "config.sh を削除して再実行すると、フォルダを指定し直せます"
  exit 1
fi

# 出力先・処理済みフォルダ作成
mkdir -p "$OUTPUT_DIR"
mkdir -p "$DONE_DIR"

# プロンプトテンプレート読み込み
PROMPT_RULES=$(cat "$PROMPT_TEMPLATE")

# 処理日（スクリプト実行時に固定）
TODAY=$(date '+%Y-%m-%d')

# 対応する拡張子
EXTENSIONS=("txt" "srt" "vtt" "csv" "json" "md")

# ファイル一覧取得（NUL区切りで安全にソート）
FILES=()
while IFS= read -r -d '' file; do
  FILES+=("$file")
done < <(
  for ext in "${EXTENSIONS[@]}"; do
    find "$INPUT_DIR" -maxdepth 1 -name "*.$ext" -type f -print0 2>/dev/null
  done | sort -z
)

TOTAL=${#FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
  echo -e "${YELLOW}処理するファイルがありません${NC}"
  echo "対応形式: ${EXTENSIONS[*]}"
  echo "フォルダ: $INPUT_DIR"
  exit 0
fi

echo "============================================"
echo " 文字起こし → Obsidian 自動仕訳"
echo "============================================"
echo ""
echo "  入力フォルダ : $INPUT_DIR"
echo "  出力フォルダ : $OUTPUT_DIR"
echo "  モデル       : $MODEL"
echo "  ファイル数   : $TOTAL 件"
echo "  処理日       : $TODAY"
echo ""
echo "============================================"
echo ""

# Claudeにプロンプトを送る関数（一時ファイル経由で引数長制限を回避）
send_to_claude() {
  local filename="$1"
  local input_file="$2"
  local tmp_prompt="$TMP_DIR/prompt.txt"
  local tmp_stderr="$TMP_DIR/stderr.txt"

  cat > "$tmp_prompt" << PROMPT_EOF
以下の指示に従って、文字起こしテキストをObsidianノートに変換してください。

## 指示
${PROMPT_RULES}

## 元ファイル名
${filename}

## 処理日
${TODAY}

## 文字起こしテキスト
$(cat "$input_file")
PROMPT_EOF

  local result
  local status=0
  result=$(claude -p --model "$MODEL" < "$tmp_prompt" 2>"$tmp_stderr") || status=$?

  # stderr にエラーがあればログに記録（成功・失敗問わず）
  # ※ log()はstdoutに出力するため、関数内では>&2でstderrに流す
  if [ -s "$tmp_stderr" ]; then
    log "  stderr: $(cat "$tmp_stderr")" >&2
  fi

  # 失敗時はログ出力後に return
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi

  # 出力の先頭が --- であることを検査
  if [[ "$result" != ---* ]]; then
    log "  警告: 出力がfrontmatterで始まっていません。補正を試みます" >&2
    # コードフェンスで囲まれている場合は除去
    result=$(echo "$result" | sed '/^```/d')
    # 先頭の空行を除去
    result=$(echo "$result" | sed '/./,$!d')
  fi

  # 補正後も --- で始まらない場合は失敗扱い
  if [[ "$result" != ---* ]]; then
    log "  エラー: frontmatter補正後も不正な出力。保存せず失敗扱いにします" >&2
    return 1
  fi

  echo "$result"
}

# 処理カウンター
SUCCESS=0
FAIL=0

for i in "${!FILES[@]}"; do
  FILE="${FILES[$i]}"
  FILENAME=$(basename "$FILE")
  BASENAME="${FILENAME%.*}"
  NUM=$((i + 1))

  # 出力先に同名ファイルがあればスキップ（処理済み）
  if [ -f "$OUTPUT_DIR/${BASENAME}.md" ]; then
    log "${YELLOW}[${NUM}/${TOTAL}] スキップ（処理済み）: $FILENAME${NC}"
    continue
  fi

  log "${GREEN}[${NUM}/${TOTAL}] 処理中: $FILENAME${NC}"

  # Claude に送信（一時ファイル経由）
  RESULT=$(send_to_claude "$FILENAME" "$FILE") || {
    # レート制限等のエラー時
    log "${RED}[${NUM}/${TOTAL}] エラー: $FILENAME${NC}"
    log "  → ${WAIT_SECONDS}秒待機して再試行..."
    FAIL=$((FAIL + 1))

    sleep "$WAIT_SECONDS"

    # 再試行（1回だけ）
    RESULT=$(send_to_claude "$FILENAME" "$FILE") || {
      log "${RED}[${NUM}/${TOTAL}] 再試行も失敗: $FILENAME → スキップ${NC}"
      continue
    }
    FAIL=$((FAIL - 1))
  }

  # 結果をObsidianに保存
  echo "$RESULT" > "$OUTPUT_DIR/${BASENAME}.md"

  # 元ファイルを処理済みフォルダへ移動
  mv "$FILE" "$DONE_DIR/"

  SUCCESS=$((SUCCESS + 1))
  log "  → 保存完了: $OUTPUT_DIR/${BASENAME}.md"

  # レート制限回避のため少し待つ
  if [ "$NUM" -lt "$TOTAL" ]; then
    sleep "$INTERVAL_SECONDS"
  fi
done

echo ""
echo "============================================"
echo " 完了！"
echo "============================================"
echo ""
echo "  成功: $SUCCESS 件"
echo "  失敗: $FAIL 件"
echo "  スキップ: $((TOTAL - SUCCESS - FAIL)) 件"
echo ""
echo "  保存先: $OUTPUT_DIR"
echo "============================================"
