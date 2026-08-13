#!/usr/bin/env bash
# Helpers for release changelog promotion.

octo_release_update_changelog() {
    local changelog_file="$1"
    local version="$2"
    local release_date="$3"
    local summary="$4"

    if [[ -f "$changelog_file" ]] && grep -q "\\[${version}\\]" "$changelog_file" 2>/dev/null; then
        echo "   CHANGELOG.md (entry already exists)"
        return 0
    fi

    local temp_file
    temp_file="$(mktemp)"

    if [[ -f "$changelog_file" ]] && [[ "$(head -n 1 "$changelog_file")" == "# Changelog" ]]; then
        awk -v version="$version" -v release_date="$release_date" -v summary="$summary" '
            BEGIN {
                in_unreleased = 0
                saw_unreleased = 0
                body = ""
                rest = ""
            }
            NR == 1 {
                next
            }
            /^## \[Unreleased\]/ {
                saw_unreleased = 1
                in_unreleased = 1
                next
            }
            /^## \[/ && in_unreleased {
                in_unreleased = 0
                rest = rest $0 "\n"
                next
            }
            {
                if (in_unreleased) {
                    body = body $0 "\n"
                    next
                }
                rest = rest $0 "\n"
            }
            END {
                printf "# Changelog\n\n"
                printf "## [Unreleased]\n\n"
                printf "## [%s] - %s\n\n", version, release_date

                content = body
                while (substr(content, 1, 1) == "\n") {
                    content = substr(content, 2)
                }
                while (length(content) > 1 && substr(content, length(content) - 1, 2) == "\n\n") {
                    content = substr(content, 1, length(content) - 1)
                }
                if (saw_unreleased && content != "") {
                    printf "%s", content
                    if (content !~ /\n$/) {
                        printf "\n"
                    }
                    printf "\n"
                } else {
                    printf "### Changed\n\n"
                    printf "- %s\n\n", summary
                }

                sub(/^\n+/, "", rest)
                printf "%s", rest
            }
        ' "$changelog_file" > "$temp_file"
    else
        {
            echo "# Changelog"
            echo ""
            echo "## [Unreleased]"
            echo ""
            echo "## [${version}] - ${release_date}"
            echo ""
            echo "### Changed"
            echo ""
            echo "- ${summary}"
            echo ""
            [[ -f "$changelog_file" ]] && cat "$changelog_file"
        } > "$temp_file"
    fi

    mv "$temp_file" "$changelog_file"
    echo "   CHANGELOG.md (promoted Unreleased)"
}
