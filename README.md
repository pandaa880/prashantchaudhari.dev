# prashantchaudhari.dev

Source for [prashantchaudhari.dev](https://prashantchaudhari.dev), my personal site and blog. I write about frontends that verify instead of trusting, fintech engineering, and frontend craft.

Built with [Astro](https://astro.build) on the [AstroPaper](https://github.com/satnaing/astro-paper) theme, deployed on [Netlify](https://www.netlify.com).

## Commands

Requires Node 20.

| Command                | Action                                                                     |
| :--------------------- | :------------------------------------------------------------------------- |
| `npm install`          | Install dependencies                                                       |
| `npm run dev`          | Start the dev server at `localhost:4321`                                   |
| `npm run build`        | Type-check (`astro check`), build to `./dist/` and index search (Pagefind) |
| `npm run preview`      | Preview the production build locally                                       |
| `npm run lint`         | Lint with ESLint                                                           |
| `npm run format:check` | Check formatting with Prettier (`npm run format` to fix)                   |

## Writing a post

Posts are Markdown files in `src/data/blog/`. The frontmatter schema is in `src/content.config.ts`.

- `draft: true` hides a post everywhere, including `npm run dev`.
- A post with a future `pubDatetime` is left out of production builds until 15 minutes before that time (`scheduledPostMargin` in `src/config.ts`). The site is static, so the post goes live on the first build after that.

## Deployment

Netlify builds `main` using `netlify.toml` and publishes a deploy preview for every pull request. GitHub Actions runs lint, the format check and the build on every pull request.

## License

This repository uses dual licensing:

- **Documentation & Blog Posts**: Licensed under [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/)
- **Code & Code Snippets**: Licensed under the [MIT License](LICENSE.md)

See the [LICENSE.md](LICENSE.md) file for full details.

## Special Thanks

Special thanks to [Sat Naing](https://github.com/satnaing) for creating the excellent [AstroPaper theme](https://astro-paper.pages.dev/) that served as the foundation for this website. Their thoughtful design and clean architecture made it a joy to build upon.
