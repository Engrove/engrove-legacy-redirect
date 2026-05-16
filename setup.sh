#!/usr/bin/env bash
#
# setup.sh — bootstrap the engrove-legacy-redirect repository locally and
# publish it to GitHub. Intended to be run once on a fresh machine.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
set -euo pipefail

PROJECT_DIR="engrove-legacy-redirect"
REMOTE_URL="https://github.com/Engrove/engrove-legacy-redirect.git"
DEFAULT_BRANCH="main"
COMMIT_MESSAGE="chore: bootstrap Cloudflare Pages 301 redirect project for legacy Engrove domains"

if ! command -v git >/dev/null 2>&1; then
    echo "error: git is required but was not found in PATH" >&2
    exit 1
fi

if [ -e "${PROJECT_DIR}" ]; then
    echo "error: '${PROJECT_DIR}' already exists in $(pwd); refusing to overwrite" >&2
    exit 1
fi

mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

cat > _redirects <<'EOF'
https://engrove.pages.dev/*        https://engrove-toolbox.pages.dev/:splat    301
https://engrove-audio.pages.dev/*  https://engrove-toolbox.pages.dev/:splat    301
/*                                 https://engrove-toolbox.pages.dev/:splat    301
EOF

cat > .gitignore <<'EOF'
.DS_Store
Thumbs.db
desktop.ini
*.swp
*.swo
*~
.idea/
.vscode/
.env
.env.local
node_modules/
EOF

cat > README.md <<'EOF'
# engrove-legacy-redirect

Permanent edge-level HTTP 301 redirects from the legacy Engrove domains to the
consolidated Engrove Toolbox platform, served by Cloudflare Pages.

## Purpose

The Engrove web presence has been unified under a single deployment target.
This repository exists solely to host a Cloudflare Pages project whose only
responsibility is to issue `HTTP 301 Moved Permanently` responses for every
incoming request on the legacy hostnames, forwarding the visitor — and the
requested path — to the new canonical platform.

No HTML, CSS, JavaScript, or runtime logic is shipped. The entire behaviour is
expressed declaratively in a single `_redirects` rule file that Cloudflare
evaluates at the edge before any origin handling occurs.

## Architecture

```
                  ┌────────────────────────────────────────────────┐
                  │             Cloudflare Edge Network            │
                  │                                                │
   Client ──▶ engrove.pages.dev/<path>                             │
              engrove-audio.pages.dev/<path>                       │
                  │                                                │
                  │   _redirects evaluation (per-request, O(rules))│
                  │                                                │
                  │   301 Moved Permanently                        │
                  │   Location: https://engrove-toolbox.pages.dev/<path>
                  └────────────────────────────────────────────────┘
                                       │
                                       ▼
                       https://engrove-toolbox.pages.dev/
```

The Cloudflare Pages project that this repository is connected to must have
both legacy hostnames bound as custom domains so that traffic to those
hostnames is terminated by this project and the redirect rules apply.

## Target platform

| Field                  | Value                                       |
| ---------------------- | ------------------------------------------- |
| Hosting provider       | Cloudflare Pages                            |
| Canonical destination  | `https://engrove-toolbox.pages.dev/`        |
| Redirect status code   | `301 Moved Permanently`                     |
| Path preservation      | Yes, via `:splat` parameter                 |
| Query string handling  | Forwarded unchanged by Cloudflare           |
| Build command          | _(none — static rule file only)_            |
| Output directory       | repository root                             |

## Affected source domains

| Legacy hostname                  | Status     | Resulting target                            |
| -------------------------------- | ---------- | ------------------------------------------- |
| `engrove.pages.dev`              | Redirected | `https://engrove-toolbox.pages.dev/:splat`  |
| `engrove-audio.pages.dev`        | Redirected | `https://engrove-toolbox.pages.dev/:splat` |

A catch-all rule (`/*`) is also defined as a defensive fallback so that any
additional hostname later attached to the project inherits the same redirect
behaviour without requiring a configuration change.

## The `_redirects` file

Cloudflare Pages reads a plain-text file named `_redirects` from the root of
the deployment output. Each line is a single rule with the structure:

```
<source>    <destination>    <status>
```

Whitespace between fields is insignificant. The first rule that matches the
incoming request wins; subsequent rules are not evaluated. Rules are matched
top-to-bottom against the request URL.

### Wildcards and placeholders

- `*` at the end of a `<source>` path matches one or more path segments and
  captures the matched substring.
- `:splat` in the `<destination>` is substituted with the substring captured
  by the preceding `*`. This is how the original sub-path is forwarded to
  the new domain without loss.

### Status codes

- `301` — Permanent redirect. Cacheable by browsers and intermediaries; SEO
  signals (PageRank, backlink equity) are transferred to the destination URL.
  This is the only status used by this project.

### Rule set in this repository

```
https://engrove.pages.dev/*        https://engrove-toolbox.pages.dev/:splat    301
https://engrove-audio.pages.dev/*  https://engrove-toolbox.pages.dev/:splat    301
/*                                 https://engrove-toolbox.pages.dev/:splat    301
```

Examples of how Cloudflare resolves these rules at the edge:

| Incoming request                                  | Response                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------- |
| `GET https://engrove.pages.dev/`                  | `301 → https://engrove-toolbox.pages.dev/`                          |
| `GET https://engrove.pages.dev/projects/tonearm`  | `301 → https://engrove-toolbox.pages.dev/projects/tonearm`          |
| `GET https://engrove-audio.pages.dev/blog/post-1` | `301 → https://engrove-toolbox.pages.dev/blog/post-1`               |
| `GET https://engrove-audio.pages.dev/?ref=x`      | `301 → https://engrove-toolbox.pages.dev/?ref=x`                    |

## Deployment

1. Connect this repository to a Cloudflare Pages project.
2. Leave the build command empty and set the output directory to the
   repository root.
3. Bind `engrove.pages.dev` and `engrove-audio.pages.dev` as custom domains
   of the Pages project (or ensure they resolve to it).
4. Push to `main`. Cloudflare will pick up `_redirects` on the next
   deployment and the rules become active globally within seconds.

## Verification

After deployment, the redirect behaviour can be confirmed from any shell:

```
curl -sI https://engrove.pages.dev/some/path
curl -sI https://engrove-audio.pages.dev/some/path
```

The response should include `HTTP/2 301` and a `location:` header pointing at
the corresponding path under `https://engrove-toolbox.pages.dev/`.
EOF

git init -q
git checkout -q -B "${DEFAULT_BRANCH}"
git add _redirects .gitignore README.md

if git remote | grep -q '^origin$'; then
    git remote set-url origin "${REMOTE_URL}"
else
    git remote add origin "${REMOTE_URL}"
fi

git commit -q -m "${COMMIT_MESSAGE}"

attempt=1
delay=2
max_attempts=5
until git push -u origin "${DEFAULT_BRANCH}"; do
    if [ "${attempt}" -ge "${max_attempts}" ]; then
        echo "error: git push failed after ${max_attempts} attempts" >&2
        exit 1
    fi
    echo "push failed; retrying in ${delay}s (attempt ${attempt}/${max_attempts})..." >&2
    sleep "${delay}"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
done

echo "Repository bootstrapped and pushed to ${REMOTE_URL} (${DEFAULT_BRANCH})."
