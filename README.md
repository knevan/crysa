# Crysa

Crysa is a web-based manga reader application built with Phoenix, Elixir, and LiveVue.

## What It Does

Crysa lets users discover, browse, and read manga series sourced from configurable scraping targets. Core features include:

- **Series discovery** — browse by category/tag, search with fuzzy matching, view most-viewed, newest, and recently updated series.
- **Chapter reader** — read chapter pages with a responsive viewer, zoom/swipe, and preloading.
- **User accounts** — registration, login, session-cookie authentication, roles (superadmin, admin, moderator, user).
- **Library** — bookmarks, ratings, and view tracking.
- **Comments** — threaded comments on series and chapters, with replies, voting, attachments, and markdown content.
- **Moderation** — reports for broken images, wrong chapters, toxic content, and more; admin resolution workflow.
- **Notifications** — reply and upvote notifications for users.
- **Admin dashboard** — series management, chapter/repair/delete operations, user management, scraping site configuration with draft/publish workflow, and category/author tag management.
- **Scraping pipeline** — configurable site scrapers with published-version snapshots, chapter download workers, WebP image encoding, and object storage.