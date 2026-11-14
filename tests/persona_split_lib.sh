# N1-589: prompt files split by mode. Each PS_<GROUP> array lists the entry file, then its
# parts, in original reading order. Text-location tests concatenate a group with split_cat
# so an assertion holds wherever its text now lives; tests/test_persona_split.sh checks the
# parts, the pointers in PS_POINTERS and the plugin-root line in PS_ROOTLINE.
PS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PS_GROUPS=(DA CTW)
PS_DA=(references/deployment-actions.md references/deployment-actions-rows.md)
PS_CTW=(skills/n1-pr/procedures/codex-triage-worker.md skills/n1-pr/procedures/codex-triage-worker-core.md skills/n1-pr/procedures/codex-triage-worker-fix.md skills/n1-pr/procedures/codex-triage-worker-validate.md skills/n1-pr/procedures/codex-triage-worker-report.md)
# <file holding the pointer>|<part basename>|<condition text on the same line>
PS_POINTERS=(
    'references/deployment-actions.md|deployment-actions-rows.md|unticked:'
    'skills/n1-finish/references/after-deploy-actions.md|deployment-actions-rows.md|unticked:'
    'skills/n1-finish/steps/02-merge.md|deployment-actions-rows.md|unticked:'
    'agents/tail-worker.md|codex-triage-worker.md|`phase: validate`'
    'skills/n1-pr/procedures/codex-triage-worker.md|codex-triage-worker-core.md|`fix`'
    'skills/n1-pr/procedures/codex-triage-worker.md|codex-triage-worker-fix.md|`fix`'
    'skills/n1-pr/procedures/codex-triage-worker.md|codex-triage-worker-core.md|`validate`'
    'skills/n1-pr/procedures/codex-triage-worker.md|codex-triage-worker-validate.md|`validate`'
    'skills/n1-pr/procedures/codex-triage-worker.md|codex-triage-worker-report.md|`report`'
)
# personas that resolve the plugin root themselves before following a pointer
PS_ROOTLINE=()
# split_cat <dest> <GROUP>: concatenate the group's files into <dest> and print <dest>
split_cat() {
    local -n _ps_g="PS_$2"; local f
    for f in "${_ps_g[@]}"; do cat "$PS_ROOT/$f"; done > "$1"
    printf '%s\n' "$1"
}
