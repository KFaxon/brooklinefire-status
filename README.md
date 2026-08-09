# Brookline Fire — Status Page

Public availability status for <https://brooklinefire.org>.

- **Live:** <https://status.brooklinefire.org>
- **Hosting:** GitHub Pages
- **Monitoring:** `.github/workflows/status.yml`, every 30 minutes

## Why this is a separate repository

The website runs on AWS (S3 behind CloudFront). This runs entirely on GitHub.

That separation is the entire point. A status page hosted on the same
infrastructure as the site it reports on goes down at exactly the moment it
becomes useful. Because this lives elsewhere, an AWS outage still leaves the
job running, the outage recorded, the page reachable, and the alert sent.

Nothing here touches AWS, so the workflow needs no credentials at all.

This repository is public because GitHub Pages requires it on a free plan, and
because uptime data is not sensitive. **Do not add anything to it that is** —
no bucket names, no account identifiers, no keys. The website's own repository
stays private.

## How it works

1. The scheduled workflow runs `build-status.ps1`.
2. That probes four endpoints on brooklinefire.org and appends the result to
   `history.json`.
3. It regenerates `index.html` with the results baked in as static HTML.
4. The workflow commits both. GitHub Pages serves `main`, so committing
   publishes.
5. If any check failed, the job exits non-zero — and GitHub emails the
   repository owner. That notification is the genuinely useful part.

The page is deliberately static rather than fetching JSON in the browser. A
status page that needs JavaScript to tell you something is broken is the wrong
tool, and it must stay readable with scripting disabled.

## Checks

| Check | Expects |
|---|---|
| Public website | `https://brooklinefire.org/` returns 200 |
| www redirect | `https://www.brooklinefire.org/` returns 200 |
| Stylesheet | `https://brooklinefire.org/styles.css` returns 200 |
| Error handling | an unknown path returns 404, not 403 |

The last one is deliberate: a misconfigured CloudFront distribution serves raw
403s from S3 instead of the site's own 404 page, which is a real fault worth
catching.

## Running it locally

```bash
powershell -ExecutionPolicy Bypass -File build-status.ps1
```

Writes `history.json` and `index.html` in place. Add `-SkipProbe` to rebuild
the page from existing history without hitting the network.

## Custom domain

`CNAME` pins the domain. DNS lives in the district's Route 53 zone:

```
status.brooklinefire.org   CNAME   kfaxon.github.io
status.brooklinefire.org   CAA     0 issue "letsencrypt.org"
```

The CAA record is required. The parent domain restricts certificate issuance
to Amazon's CAs, which would otherwise stop GitHub Pages from obtaining its
Let's Encrypt certificate — HTTPS would just silently never provision.
