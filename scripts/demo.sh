#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [--user-config|--plugins]\n' "${0##*/}" >&2
}

MODE=clean
if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    --user-config)
      MODE=user-config
      ;;
    --plugins)
      MODE=plugins
      ;;
    *)
      usage
      exit 2
      ;;
  esac
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vigit-demo.XXXXXX")"
SECONDARY_DIR="${DEMO_DIR}-secondary"

cleanup() {
  rm -rf -- "$SECONDARY_DIR" "$DEMO_DIR"
}
trap cleanup EXIT

for dependency in git nvim; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Vigit demo requires $dependency" >&2
    exit 1
  fi
done

git -C "$DEMO_DIR" init -q
git -C "$DEMO_DIR" config user.email demo@vigit.local
git -C "$DEMO_DIR" config user.name "Vigit Demo"
mkdir -p "$DEMO_DIR/lua/demo"

FORMATTER_PATH="lua/demo/features/checkout/presentation/very_long_invoice_summary_formatter_for_responsive_layout.lua"
PIPELINE_PATH="lua/demo/features/orders/application/very_long_order_processing_pipeline_for_live_preview.lua"
FORMATTER_FILE="$DEMO_DIR/$FORMATTER_PATH"
PIPELINE_FILE="$DEMO_DIR/$PIPELINE_PATH"
mkdir -p "$(dirname -- "$FORMATTER_FILE")" "$(dirname -- "$PIPELINE_FILE")"

write_large_formatter() {
  local index
  {
    printf '%s\n' 'local M = {}' '' 'local rules = {'
    for ((index = 1; index <= 100; index++)); do
      printf '  { name = "invoice_rule_%03d", weight = %d },\n' "$index" "$index"
    done
    printf '%s\n' \
      '}' \
      '' \
      'function M.rules()' \
      '  return rules' \
      'end' \
      '' \
      'return M'
  } > "$FORMATTER_FILE"
}

write_large_pipeline() {
  local mode="$1"
  local index
  local expression
  {
    printf '%s\n' 'local M = {}' '' 'local handlers = {'
    for ((index = 1; index <= 120; index++)); do
      expression="value + $index"
      if [[ "$mode" != baseline ]]; then
        case "$index" in
          10|60|110)
            expression="value + $index + 1000"
            ;;
        esac
      fi
      if [[ "$mode" == working ]]; then
        case "$index" in
          25|75|115)
            expression="value - $index"
            ;;
        esac
      fi
      printf '  [%d] = function(value) return %s end,\n' "$index" "$expression"
    done
    printf '%s\n' \
      '}' \
      '' \
      'function M.process(value)' \
      '  local result = value' \
      '  for index = 1, #handlers do' \
      '    result = handlers[index](result)' \
      '  end' \
      '  return result' \
      'end' \
      '' \
      'return M'
  } > "$PIPELINE_FILE"
}

printf '%s\n' \
  'local M = {}' \
  '' \
  'function M.total(items)' \
  '  local result = 0' \
  '  for _, value in ipairs(items) do' \
  '    result = result + value' \
  '  end' \
  '  return result' \
  'end' \
  '' \
  'function M.average(items)' \
  '  return M.total(items) / #items' \
  'end' \
  '' \
  'return M' > "$DEMO_DIR/lua/demo/calculator.lua"

printf '%s\n' \
  'local M = {}' \
  '' \
  'function M.run()' \
  '  return "legacy"' \
  'end' \
  '' \
  'return M' > "$DEMO_DIR/lua/demo/legacy.lua"

printf '%s\n' \
  '# Demo application' \
  '' \
  'Small fixture used by Vigit.' > "$DEMO_DIR/README.md"

write_large_pipeline baseline

git -C "$DEMO_DIR" add README.md lua/demo/calculator.lua lua/demo/legacy.lua "$PIPELINE_PATH"
git -C "$DEMO_DIR" commit -q -m "demo baseline"
git -C "$DEMO_DIR" worktree add -q -b demo-secondary "$SECONDARY_DIR"

mkdir -p "$SECONDARY_DIR/lua/demo/tasks" "$SECONDARY_DIR/notes"

printf '%s\n' \
  '# Secondary worktree' \
  '' \
  'An independent AI-agent task running in a linked Git worktree.' \
  '' \
  'This branch has its own staged, unstaged, and untracked changes.' > "$SECONDARY_DIR/README.md"

printf '%s\n' \
  'local M = {}' \
  '' \
  'function M.total(items)' \
  '  local result = 0' \
  '  for _, value in ipairs(items) do' \
  '    result = result + value' \
  '  end' \
  '  return result' \
  'end' \
  '' \
  'function M.maximum(items)' \
  '  return math.max(unpack(items))' \
  'end' \
  '' \
  'return M' > "$SECONDARY_DIR/lua/demo/calculator.lua"

printf '%s\n' \
  'local M = {}' \
  '' \
  'function M.describe()' \
  '  return "secondary worktree task"' \
  'end' \
  '' \
  'return M' > "$SECONDARY_DIR/lua/demo/tasks/worktree_task.lua"

printf '%s\n' \
  '# Agent review notes' \
  '' \
  '- Check the new maximum calculation.' \
  '- Keep this file untracked for the demo.' > "$SECONDARY_DIR/notes/agent-review.md"

git -C "$SECONDARY_DIR" add lua/demo/tasks/worktree_task.lua

printf '%s\n' \
  'local M = {}' \
  '' \
  'function M.total(items)' \
  '  assert(type(items) == "table", "items must be a table")' \
  '  local result = 0' \
  '  for _, value in ipairs(items) do' \
  '    result = result + value' \
  '  end' \
  '  return result' \
  'end' \
  '' \
  'function M.average(items)' \
  '  if #items == 0 then' \
  '    return 0' \
  '  end' \
  '  return M.total(items) / #items' \
  'end' \
  '' \
  'return M' > "$DEMO_DIR/lua/demo/calculator.lua"

rm -- "$DEMO_DIR/lua/demo/legacy.lua"

printf '%s\n' \
  '# Demo application' \
  '' \
  'A small staged and unstaged fixture used by Vigit.' \
  '' \
  'Open the interface and stage changes interactively.' > "$DEMO_DIR/README.md"

printf '%s\n' \
  'local M = {}' \
  '' \
  'function M.label(value)' \
  '  return string.format("Total: %d", value)' \
  'end' \
  '' \
  'return M' > "$DEMO_DIR/lua/demo/format.lua"

write_large_pipeline staged
write_large_formatter

git -C "$DEMO_DIR" add README.md lua/demo/format.lua "$PIPELINE_PATH" "$FORMATTER_PATH"

write_large_pipeline working

printf 'Vigit demo repository: %s\n' "$DEMO_DIR"
printf 'Secondary worktree: %s\n' "$SECONDARY_DIR"
printf '%s\n' 'Try worktrees: press w, select WT demo-secondary, then press Enter.'
printf '%s\n' 'Close Neovim to remove it.'

cd "$DEMO_DIR"
case "$MODE" in
  user-config)
    NVIM_NOTTYFAST=1 VIGIT_ROOT="$ROOT_DIR" VIGIT_DEMO_DIR="$DEMO_DIR" nvim \
      --cmd 'lua vim.opt.runtimepath:prepend(vim.env.VIGIT_ROOT)' \
      -c 'lua dofile(vim.fs.joinpath(vim.env.VIGIT_ROOT, "scripts", "demo_user_init.lua"))'
    ;;
  plugins)
    NVIM_NOTTYFAST=1 NVIM_APPNAME=vigit-demo VIGIT_ROOT="$ROOT_DIR" VIGIT_DEMO_DIR="$DEMO_DIR" \
      nvim -u "$ROOT_DIR/scripts/demo_plugins_init.lua"
    ;;
  clean)
    NVIM_NOTTYFAST=1 nvim --clean -u "$ROOT_DIR/scripts/demo_init.lua"
    ;;
esac
