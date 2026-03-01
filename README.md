# Prashant Chaudhari's Personal Website

This is the source code for my personal website, built with [Astro](https://astro.build) and deployed on [Vercel](https://vercel.com).

## About

I'm Prashant Chaudhari. This website hosts my personal blog and information about my work.

## Project Structure

```text
├── public/               # Static assets (images, fonts, favicon)
│   └── pagefind/         # Auto-generated search index (when built)
├── src/
│   ├── assets/           # Icons and images used in components
│   ├── components/       # Reusable UI components
│   ├── data/
│   │   └── blog/         # Blog posts in Markdown format
│   ├── layouts/          # Page layouts and templates
│   ├── pages/            # Routes and pages
│   ├── scripts/          # Client-side scripts
│   ├── styles/           # Global styles and CSS
│   └── utils/            # Utility functions
├── astro.config.ts       # Astro configuration
├── package.json          # Project dependencies and scripts
└── LICENSE.md            # Dual license (CC BY 4.0 + MIT)
```

## Commands

| Command                | Action                                      |
| :--------------------- | :------------------------------------------ |
| `npm install`          | Installs dependencies                       |
| `npm run dev`          | Starts local dev server at `localhost:4321` |
| `npm run build`        | Build the production site to `./dist/`      |
| `npm run preview`      | Preview the build locally, before deploying |

## Deployment

This site is set up for easy deployment on Vercel. Just connect your GitHub repository to Vercel, and it will automatically build and deploy the site when changes are pushed.

## License

This repository uses dual licensing:

- **Documentation & Blog Posts**: Licensed under [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/)
- **Code & Code Snippets**: Licensed under the [MIT License](LICENSE.md)

See the [LICENSE.md](LICENSE.md) file for full details.

## Special Thanks

Special thanks to [Sat Naing](https://github.com/satnaing) for creating the excellent [AstroPaper theme](https://astro-paper.pages.dev/) that served as the foundation for this website. Their thoughtful design and clean architecture made it a joy to build upon.
