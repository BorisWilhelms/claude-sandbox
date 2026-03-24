#!/bin/bash
# Prevent Claude from modifying sandbox hooks or settings

# Only enforce in sandbox
[ -f ~/.sandbox ] || exit 0

FILE_PATH=$(jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

case "$FILE_PATH" in
    */.claude/hooks/*|*/.claude/settings.json|*/.claude/settings.local.json)
        jq -n '{
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: "Modifying Claude hooks or settings is blocked by sandbox policy."
            }
        }'
        exit 0
        ;;
esac

exit 0
