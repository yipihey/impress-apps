# Universal Links Setup

This directory contains the `apple-app-site-association` file required for iOS and macOS Universal Links.

## Setup Instructions

### 1. Replace TEAMID

Edit `apple-app-site-association` and replace all occurrences of `TEAMID` with your actual Apple Developer Team ID.

To find your Team ID:
1. Go to [Apple Developer Portal](https://developer.apple.com/account)
2. Click on "Membership" in the sidebar
3. Copy your Team ID

Example:
- Before: `TEAMID.com.imbib.app`
- After: `ABC123DEF4.com.imbib.app`

### 2. Verify Content-Type

GitHub Pages serves files in `.well-known/` correctly by default. After deploying, verify:

```bash
curl -I https://yipihey.github.io/imbib/.well-known/apple-app-site-association
```

Expected headers:
- `Content-Type: application/json` (or no Content-Type, which iOS accepts)
- `200 OK` status

### 3. Test Universal Links

After deploying:

1. Install imbib on your device
2. Wait a few minutes for iOS to fetch the AASA file
3. Tap a link like: `https://yipihey.github.io/imbib/doi/10.1038/nature12373`
4. The app should open directly

### 4. Debugging

If links don't work:

1. **Check AASA validator**: Use [Apple's App Search API Validation Tool](https://search.developer.apple.com/appsearch-validation-tool/)

2. **Check console logs**: On iOS, open Console.app and filter for `swcd` to see Universal Links debugging

3. **Force refresh**: Delete and reinstall the app, or go to Settings → Developer → Associated Domains Development

### Supported URL Patterns

| Pattern | Action |
|---------|--------|
| `/imbib/doi/{doi}` | Search/add paper by DOI |
| `/imbib/arxiv/{id}` | Search/add paper by arXiv ID |
| `/imbib/paper/{uuid}` | Open paper by ID |
| `/imbib/search?q={query}` | Search for papers |
| `/imbib/inbox` | Open inbox |
| `/imbib/library` | Open library |

### Custom Domain (Future)

If you set up a custom domain like `imbib.app`:

1. Update `_config.yml` with new URL
2. Update paths in `apple-app-site-association` (remove `/imbib` prefix)
3. Update entitlements to include `applinks:imbib.app`
4. Host AASA at `https://imbib.app/.well-known/apple-app-site-association`
