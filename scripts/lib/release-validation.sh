#!/usr/bin/env bash
# Helpers for release manifest validation.

octo_release_skill_files() {
    local root="$1"
    local skills_root="${root%/}/skills"

    [[ -d "$skills_root" ]] || return 0

    find "$skills_root" -mindepth 2 -type f -name 'SKILL.md' -print 2>/dev/null |
        while IFS= read -r skill_path; do
            skill_path="${skill_path#"$skills_root"/}"
            printf '%s\n' "${skill_path%/SKILL.md}"
        done |
        sort
}
