# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users
Developers who want to host their own small apps on one cheap VPS without running a PaaS by hand. They arrive at the docs page with a terminal and GitHub open, and follow it step by step during a one-time setup, then return to it for reference (adding an app, logs, rollback, databases). *(Inferred from README and site; not interviewed.)*

## Product Purpose
`vps-infra` is a GitHub template repo that turns a VPS into a small PaaS with Dokku, managed entirely from GitHub Actions. Success: a reader goes from an empty VPS to a deployed HTTPS app by following the page, without guessing.

## Positioning
Nothing runs on the user's machine except `init-github.sh`, once. Apps are declared in `apps.yml`; images build on GitHub runners, so a 1 vCPU / 1–4 GB box is enough.

## Capabilities and Constraints
- Ubuntu 22.04/24.04 VPS, wildcard DNS, `gh` CLI for setup.
- Zero-downtime deploys, automatic Let's Encrypt HTTPS, hardening (UFW, fail2ban, key-only SSH, unattended upgrades, swap).
- The docs site is one static file, `site/index.html`, deployed to GitHub Pages by `.github/workflows/pages.yml`. No build step.
- README.md is the source of truth for copy; the site mirrors it.

## Brand Commitments
Name: `vps-infra`. MIT licensed. Voice: plain, direct, imperative instructions.

## Evidence on Hand
No testimonials, users, or benchmarks. Don't invent any.

## Product Principles
- Instructions first: every step is something the reader can do, in order.
- Copy-pasteable commands, exact names of secrets, workflows, and menus.
- Warnings come before the step they protect.
