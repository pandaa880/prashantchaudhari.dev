/** @type {import("prettier").Config} */
export default {
  arrowParens: "avoid",
  semi: true,
  tabWidth: 2,
  printWidth: 80,
  singleQuote: false,
  jsxSingleQuote: false,
  trailingComma: "es5",
  bracketSpacing: true,
  endOfLine: "lf",
  plugins: ["prettier-plugin-astro", "prettier-plugin-tailwindcss"],
  tailwindStylesheet: "./src/styles/global.css",
  overrides: [
    {
      files: "*.astro",
      options: {
        parser: "astro",
      },
    },
    {
      // Code samples in posts follow Prettier's defaults, which readers know.
      files: "src/data/blog/**/*.md",
      options: {
        arrowParens: "always",
        trailingComma: "all",
      },
    },
  ],
};
