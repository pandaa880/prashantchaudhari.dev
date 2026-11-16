# AGENTS.md

Notes for AI coding agents working in this repo. Humans: start with [README.md](README.md).

If `../AGENTS.md` exists (one level above this repo), read it first: it is the maintainer's private brief.
Never copy anything from it into this repo, a PR, a commit message or a post.

## What this is

Personal site and blog for [prashantchaudhari.dev](https://prashantchaudhari.dev). Astro 5 on the AstroPaper
theme, Tailwind CSS 4, pnpm 10 (pinned in `packageManager`), Node 20. Netlify builds `main` and publishes a
deploy preview for every pull request.

| Path | What it holds |
|---|---|
| `src/config.ts` | `SITE`: title, tagline (`desc`), timezone, scheduled-post margin |
| `src/constants.ts` | Social and share links |
| `src/pages/index.astro` | Homepage: hero, projects, featured and recent posts |
| `src/pages/about.md` | About page |
| `src/data/blog/*.md` | Posts (schema in `src/content.config.ts`) |
| `.github/workflows/` | CI (lint, format check, build) and scheduled publishing |

## Before you open a PR

Run all three; CI runs the same:

```sh
pnpm lint
pnpm format:check
pnpm build
```

For visual changes, also check the Netlify deploy preview at phone width.

## Workflow

- Branch from an up-to-date `origin/main` and open a PR into `main`. There is no develop branch. PRs are
  squash-merged.
- PR titles follow Conventional Commits: `feat(home): …`, `fix(blog): …`, `docs(copy): …`.
- One change per PR. Don't merge: the maintainer reviews and merges.
- Ask before adding a dependency. Don't add analytics, trackers, or third-party widgets.
- Never commit `dist/`, `.astro/`, `.claude/` or private notes.

## Posts

- `draft: true` hides a post everywhere, including `pnpm dev`.
- To schedule a post: set a real `pubDatetime` with its UTC offset, set `draft: false`, label the PR
  `scheduled`, and keep it a draft PR. `.github/workflows/scheduled-publish.yml` merges it once it is due.
- Never merge a future-dated post early: its page is built as soon as it isn't a draft, so the URL would be
  live before the date.
- Internal links use the trailing-slash URL (`/posts/slug/`), so crawlers skip a redirect.
- Code samples in posts follow Prettier's default style.

## Content rules

- First person, plain words, the author's own phrasing. Don't lift phrases or structure from other articles.
- Claim only what shipped or was tested. A status line or "live" link must be true on the day it is read.
- Never invent employers, job titles, dates or numbers. Leave a placeholder for the author to fill instead.
- No wallet addresses, transaction hashes, balances, amounts or infrastructure job ids, in posts,
  screenshots, PRs or commit messages.
- Keep the tagline and About wording unless the maintainer asks for a change.

## Quality bar

The site is also a frontend work sample. Keep it fast and accessible: text contrast at least 4.5:1 in both
themes, labelled links and buttons, visible focus, no layout shift, little client-side JavaScript, and no
horizontal scroll at phone width.
