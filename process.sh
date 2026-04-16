#!/bin/bash
# ============================================
# 文字起こし → Obsidian 自動仕訳スクリプト
# Claude Code（claude -p）を使用
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PROMPT_TEMPLATE="$SCRIPT_DIR/prompt-template.md"
DONE_DIR="$INPUT_DIR/.done"
LOG_FILE="$SCRIPT_DIR/process.log"

# 色付き出力
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo -e "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# 初期チェック
if ! command -v claude &> /dev/null; then
  echo -e "${RED}エラー: Claude Code がインストールされていません${NC}"
  echo "インストール方法: npm install -g @anthropic-ai/claude-code"
  exit 1
fi

if [ ! -d "$INPUT_DIR" ]; then
  echo -e "${RED}エラー: 入力フォルダが見つかりません: $INPUT_DIR${NC}"
  echo "config.sh の INPUT_DIR を確認してください"
  exit 1
fi

# 出力先・処理済みフォルダ作成
mkdir -p "$OUTPUT_DIR"
mkdir -p "$DONE_DIR"

# プロンプトテンプレート読み込み
PROMPT_RULES=$(cat "$PROMPT_TEMPLATE")

# 対応する拡張子
EXTENSIONS=("txt" "srt" "vtt" "csv" "json" "md")

# ファイル一覧取得
FILES=()
for ext in "${EXTENSIONS[@]}"; do
  while IFS= read -r -d '' file; do
    FILES+=("$file")
  done < <(find "$INPUT_DIR" -maxdepth 1 -name "*.$ext" -type f -print0 2>/dev/null)
done

# ソート（ファイル名順）
IFS=$'\n' FILES=($(sort <<< "${FILES[*]}")); unset IFS

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
echo ""
echo "============================================"
echo ""

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

  # ファイル内容読み込み
  CONTENT=$(cat "$FILE")

  # Claude に送信
  RESULT=$(claude -p --model "$MODEL" \
    "以下の指示に従って、文字起こしテキストをObsidianノートに変換してください。

## 指示
${PROMPT_RULES}

## 元ファイル名
${FILENAME}

## 文字起こしテキスト
${CONTENT}" 2>&1) || {
    # レート制限等のエラー時
    log "${RED}[${NUM}/${TOTAL}] エラー: $FILENAME${NC}"
    log "  → ${WAIT_SECONDS}秒待機して再試行..."
    FAIL=$((FAIL + 1))

    sleep "$WAIT_SECONDS"

    # 再試行（1回だけ）
    RESULT=$(claude -p --model "$MODEL" \
      "以下の指示に従って、文字起こしテキストをObsidianノートに変換してください。

## 指示
${PROMPT_RULES}

## 元ファイル名
${FILENAME}

## 文字起こしテキスト
${CONTENT}" 2>&1) || {
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
