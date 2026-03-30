# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## COMMANDS

### Development & Build
- Start local development server: `npm run dev`
- Build production site: `npm run build`
- Validate and build (with TypeScript check): `npm run build:check`
- Preview build locally: `npm run preview`

### Linting & Formatting
- Run linter: `npm run lint`
- Fix lint issues: `npm run lint:fix`
- Format code: `npm run format`
- Check code: `npm run check`
- Fix formatting issues: `npm run check:fix`

### Git Workflow
- Commit message convention: Conventional Commits via `cz`
- Run linter before commit in git hook: `biome check --write src`

## PROJECT ARCHITECTURE

### Tech Stack
- **Astro 5.x** - Static site generator with island architecture (React components inside static HTML)
- **TailwindCSS 4.x** - Utility-first CSS framework via @tailwindcss/vite plugin
- **React 19.x** - Used for interactive components via @astrojs/react
- **MDX** - Markdown + JSX support for blog posts
- **TypeScript 5.x** - Full type safety with ESLint/Biome integration

### Project Structure (src/)

| Directory | Purpose |
|-----------|---------|
| `content/blog/` | Blog posts in markdown/mdx format (organized by year) |
| `pages/` | Astro routes/layouts: index, posts, individual post, archives, about |
| `components/` | Reusable UI components (.astro files), organized with ui subdirectory |
| `layouts/` | Page layouts and templates (BaseLayout, BlogPost, AboutLayout) |
| `styles/` | Global CSS styles using Tailwind |
| `utils/` | Shared utilities (remark plugins, post processing, image generation) |
| `consts.ts` | Site-wide configuration constants (website info, navigation, social links) |

### Key Configuration Files

- **astro.config.mjs** - Astro build configuration with integrations:
  - Sitemap with custom priority rules
  - MDX + remark plugins (Toc, collapse tables)
  - Lazy-load images
  - PWA support via @vite-pwa/astro
  - Google Fonts integration

- **src/content.config.ts** - Blog post schema with Zod validation:
  - Frontmatter fields: pubDate, modDate, title, tags, featured, draft, ogImage
  - Optional: author (defaults to SITE.author), unlisted, timezone

### Build Output & Generated Files

```
dist/           - Production build output (static assets + pages)
.astro/         - Astro type generation cache (ignore)
temp-*/         - Temporary directories during import (ignore)
src/content/temp/ - Temp post files during processing (ignore)
```

## COMMON TASKS

### Adding a New Blog Post

1. Create file in `/src/content/blog/YYYY-MM-DD/slug.md`
2. Include frontmatter with: `pubDate`, `title`, `description`, `tags` array
3. Content supports MDX (JSX syntax) via MDX integrations

Example:
```markdown
---
pubDate: 2026-03-08T10:00:00+00:00
title: "Post Title"
description: "Short description"
tags: ["data", "analytics"]
featured: true
---

# Content here
```

### Customizing Site Settings

- General site constants → `src/consts.ts` (SITE object)
- Navigation links → `NAV_LINKS` array in consts.ts
- Social media links → `SOCIAL_LINKS` and `ICON_MAP` arrays

### Styling Changes

- Global styles: Files in `/src/styles/` using Tailwind classes
- Component-specific: Use Tailwind utility classes directly in `.astro` components

### Layout Changes

- Main layout template: `src/layouts/Layout.astro`
- Blog post layout: `src/layouts/BlogPostLayout.astro`
- About page: `src/layouts/AboutLayout.astro`

## DEPENDENCIES

| Package | Version | Purpose |
|---------|---------|---------|
| astro | ^5.16.6 | Site framework |
| @astrojs/mdx | ^4.3.13 | MDX support |
| @astrojs/react | ^4.4.2 | React integration |
| @astrojs/rss | ^4.0.14 | RSS feed generation |
| @astrojs/sitemap | ^3.6.0 | Sitemap management |
| @tailwindcss/vite | ^4.1.18 | Tailwind CSS processing |
| react | ^19.2.3 | React 19 |
| pagefind | ^1.4.0 | Search engine |
| sharp | ^0.34.5 | Image processing |
| satori | ^0.18.3 | SVG/React rendering for OG images |

### Dev Dependencies
- **@biomejs/biome** - Linter/formatter with auto-fix capabilities
- **husky + lint-staged** - Git hooks for pre-commit quality checks
- **commitizen** - Conventional commit hooks via `cz` CLI

## DEVELOPMENT NOTES

- Posts are organized in `/src/content/blog/YYYY/` directories
- Images are stored in `/public/assets/img/YYYY/POSTNAME/` structure
- Build output goes to `/dist/` directory
- Theme toggle supports light/dark mode (CSS variables)
- Analytics: Vercel speed insights + analytics via @vercel/analytics
- SEO: Sitemap with priority rules based on page type
- PWA enabled with manifest and offline support