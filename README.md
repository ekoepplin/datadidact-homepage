# datadidact-homepage

Personal site and blog for Eugene Köpplin, built with Jekyll and the Chirpy theme. It’s my public homepage where I write about the data engineering topics and adjacent tools I find interesting. Deployed via GitHub Pages (custom domain set in `CNAME`).

## Quick start (local)

1) Install Ruby + Bundler  
2) Install deps: `bundle install`  
3) Run locally: `bundle exec jekyll serve`  
4) Open http://localhost:4000

## Editing content

- Posts live in `_posts/` (use `YYYY-MM-DD-title.md`).  
- Sidebar tabs are in `_tabs/` (e.g., `about.md`).  
- Global settings (site title, socials, analytics) are in `_config.yml`.  
- Images go under `assets/img/` (avatar already set to `/assets/img/avatar.jpg`).

## Deployment

Pushing to the default branch publishes via GitHub Pages. The `CNAME` file keeps the custom domain.

## Housekeeping

- `_site/` is build output; keep it out of commits (already in `.gitignore`).  
- Use `bundle exec jekyll build` for a production build.  
- If you update dependencies, commit `Gemfile` and `Gemfile.lock`.

## Troubleshooting

**Network issues with `bundle install`:**
- If you get "Could not reach host index.rubygems.org", check your network connection
- In workspace environments, this may be a temporary DNS/network issue
- Try: `bundle install --verbose` for more details
- Alternative: Use a different RubyGems source or check proxy settings
