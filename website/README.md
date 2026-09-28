# zay website

Small React + Vite landing page for zay. It has no server-side runtime.

The install instructions link to the published [`zay-git` AUR package](https://aur.archlinux.org/packages/zay-git).

## Local development

```sh
npm ci
npm run dev

# Verify production output
npm run build
npm run preview
```

## Deploy to Vercel

Import the GitHub repository and set **Root Directory** to `website`. Vercel
will detect Vite. Use:

- Build command: `npm run build`
- Output directory: `dist`
- Install command: `npm ci`

The custom domain can be set to `get-zay.vercel.app` in the Vercel project
settings. No environment variables are required.
