#!/bin/bash
# ============================================
# 設定ファイル（ここだけ変更すればOK）
# ============================================

# 文字起こしファイルが入っているフォルダ（絶対パス）
INPUT_DIR="$HOME/transcripts"

# Obsidianの保存先フォルダ（絶対パス）
OUTPUT_DIR="$HOME/My-Knowledge/voicy"

# 使用するClaudeモデル（sonnet推奨。コスト安・速度速・仕訳には十分）
MODEL="sonnet"

# レート制限時の待機秒数
WAIT_SECONDS=30

# 1ファイル処理後の待機秒数（レート制限回避）
INTERVAL_SECONDS=5
