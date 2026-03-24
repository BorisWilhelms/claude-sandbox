#!/bin/bash
# Block destructive git commands inside the sandbox

# Only enforce in sandbox
[ -f ~/.sandbox ] || exit 0

COMMAND=$(jq -r '.tool_input.command' 2>/dev/null)

if echo "$COMMAND" | grep -qE 'git\s+push\s+.*(-f|--force|--force-with-lease)'; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "Force-push blocked by sandbox policy."
        }
    }'
    exit 0
fi

if echo "$COMMAND" | grep -qE 'git\s+reset\s+.*--hard'; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "git reset --hard blocked by sandbox policy."
        }
    }'
    exit 0
fi

if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "git clean -f blocked by sandbox policy."
        }
    }'
    exit 0
fi

if echo "$COMMAND" | grep -qE 'git\s+branch\s+.*-D'; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "git branch -D blocked by sandbox policy. Use -d instead."
        }
    }'
    exit 0
fi

exit 0
